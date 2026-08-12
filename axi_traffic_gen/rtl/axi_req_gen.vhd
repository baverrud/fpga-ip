-----------------------------------------------------------------------
--Filename         : axi_req_gen.vhd
--Description      : Lightweight client read-request (req) generator.
--                 : The client interface has no ID field.  enable and
--                 : aperture form the generation gate.  cfg_pace_init
--                 : delays the first burst by cfg_pace_init+1 cycles
--                 : (matching the cfg_pace+1 gap convention; the +1
--                 : comes from presenting at pace_cnt<=1); cfg_pace is
--                 : reloaded after each accepted request.
--                 :
--                 : cfg_req_len is the request length (beats-1), the
--                 : same encoding as the req_len output port:  0 means
--                 : a 1-beat request, 31 a 32-beat request, etc.
--                 : With cfg_len_mode='1' every presented burst draws
--                 : its length from an independent xorshift32 PRNG,
--                 : clamped to cfg_max_len (beats-1), so burst lengths
--                 : vary between 1 and cfg_max_len+1 beats.
--                 :
--                 : Linear and pseudo-random addressing stay within the
--                 : configured window and align starts to C_DATA_BYTES;
--                 : in random-length mode each burst is fitted to its
--                 : own drawn length.
--                 :
--                 : Timing note: no dividers or multipliers anywhere;
--                 : random addressing uses a bit-mask, so cfg_addr_range
--                 : must be a power of two when cfg_addr_mode='1'.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_req_gen is
  generic (
    GC_DATA_BYTES : positive := 64;
    GC_ADDR_WIDTH : positive := 32;
    GC_MAX_BURST  : positive := 32   -- max beats per burst (credit-limited)
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Control
    enable   : in std_logic;  -- per-instance enable
    aperture : in std_logic;  -- measurement window
    stat_rst : in std_logic;  -- clears statistic counters

    cfg_req_len    : in std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);  -- beats-1; 0 = 1 beat
    cfg_len_mode   : in std_logic;                                            -- '0' = fixed cfg_req_len, '1' = random length
    cfg_max_len    : in std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);  -- random length upper bound (beats-1)
    cfg_pace       : in std_logic_vector(31 downto 0);                        -- idle cycles between reqs (0 = every cycle)
    cfg_pace_init  : in std_logic_vector(31 downto 0);                        -- delay before first burst
    cfg_base_addr  : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    cfg_addr_range : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    -- NOTE: random mode (cfg_addr_mode='1') requires cfg_addr_range to be a
    -- power of two (offset is a bit-mask).  Linear mode accepts any range.
    cfg_addr_mode : in std_logic;  -- '0' = linear sweep, '1' = pseudo-random

    -- Client request channel (master -> consumer)
    req_valid : out std_logic;
    req_ready : in  std_logic;
    req_addr  : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    req_len   : out std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);  -- beats-1

    -- Statistics (plain register reads, no pipeline latency)
    stat_req_stall  : out std_logic_vector(31 downto 0);
    stat_req_issued : out std_logic_vector(31 downto 0);
    stat_cfg_errors : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of axi_req_gen is

  constant C_LEN_WIDTH : positive := log2ceil(GC_MAX_BURST);

  -- Low-bit alignment mask:  forces the low log2(C_DATA_BYTES) address
  -- bits to 0 so every access starts on a C_DATA_BYTES multiple.
  constant C_ALIGN : unsigned(GC_ADDR_WIDTH-1 downto 0) :=
                       not to_unsigned(GC_DATA_BYTES - 1, GC_ADDR_WIDTH);

  type reg_t is record
    cur_addr      : unsigned(GC_ADDR_WIDTH-1 downto 0);        -- next address to present
    req_addr      : unsigned(GC_ADDR_WIDTH-1 downto 0);        -- registered address output
    req_len       : std_logic_vector(C_LEN_WIDTH-1 downto 0);  -- registered length output
    req_valid     : std_logic;                                 -- registered valid output
    pace_cnt      : unsigned(31 downto 0);                     -- cfg_pace downcounter
    req_stall_cnt : unsigned(31 downto 0);                     -- req stall events (valid, not ready)
    req_cnt       : unsigned(31 downto 0);                     -- reqs successfully issued
    cfg_err       : unsigned(31 downto 0);                     -- config error count
  end record;

  constant C_REG_DEFAULT : reg_t := (
    cur_addr      => (others => '0'),
    req_addr      => (others => '0'),
    req_len       => (others => '0'),
    req_valid     => '0',
    pace_cnt      => (others => '0'),
    req_stall_cnt => (others => '0'),
    req_cnt       => (others => '0'),
    cfg_err       => (others => '0')
  );

  signal r : reg_t := C_REG_DEFAULT;  -- current state (registered)
  signal r_in : reg_t;  -- next state (combinational output)

  -- xoroshiro128+ PRNG for random address mode.
  signal prng_data : std_logic_vector(63 downto 0);
  signal prng_step : std_logic;

  -- xorshift32 PRNG for random request-length mode (independent seed,
  -- stepped once per presented burst).
  signal prng_len      : std_logic_vector(31 downto 0);
  signal prng_len_step : std_logic;

  ---------------------------------------------------------------------
  -- Clamp a candidate start address into [base, top] and force the low
  -- bits to 0 (C_DATA_BYTES alignment).  top is the highest legal start
  -- address = base + range - bsize.  Used as a safety net at
  -- presentation; the advance logic already keeps addresses inside the
  -- window.
  ---------------------------------------------------------------------
  function fit_addr(
    constant addr : in unsigned(GC_ADDR_WIDTH-1 downto 0);
    constant base : in unsigned(GC_ADDR_WIDTH-1 downto 0);
    constant top  : in unsigned(GC_ADDR_WIDTH-1 downto 0)
  ) return unsigned is
    variable v_a : unsigned(GC_ADDR_WIDTH-1 downto 0);
  begin
    if addr < base then
      v_a := base;
    elsif addr > top then
      v_a := top;
    else
      v_a := addr;
    end if;
    return v_a and C_ALIGN;
  end function;

begin

  -- Address PRNG (random addressing, stepped once per issued burst).
  u_prng : entity work.xorshift128
    port map (
      clk  => aclk,
      rstn => aresetn,
      step => prng_step,
      data => prng_data
    );

  -- Length PRNG (random request length, stepped once per presented burst).
  u_prng_len : entity work.xorshift32
    generic map (GC_SEED => x"C0FFEE01")
    port map (
      clk  => aclk,
      rstn => aresetn,
      step => prng_len_step,
      data => prng_len
    );

  ---------------------------------------------------------------------
  -- Next-state logic.  Outputs are registered through r; req_valid and
  -- req_addr/req_len remain unchanged until the request handshake is
  -- accepted.
  ---------------------------------------------------------------------
  p_comb : process(all)
    variable v           : reg_t;
    variable v_len_i     : unsigned(C_LEN_WIDTH-1 downto 0);  -- selected len for next burst
    variable v_bsize     : unsigned(31 downto 0);             -- bytes per burst for v_len_i
    variable v_max_start : unsigned(GC_ADDR_WIDTH-1 downto 0);-- base+range-bsize
    variable v_off       : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- random offset
    variable v_next      : unsigned(GC_ADDR_WIDTH-1 downto 0);
    variable v_cfg_clamp : boolean;
    variable v_gate      : std_logic;  -- enable and aperture (combinational, local)
  begin
    v := r;  -- recover current state as default for all fields
    v_gate := enable and aperture;

    req_valid <= r.req_valid;
    req_addr  <= std_logic_vector(r.req_addr);
    req_len   <= r.req_len;
    prng_step <= '0';
    prng_len_step <= '0';

    stat_req_stall   <= std_logic_vector(r.req_stall_cnt);
    stat_req_issued  <= std_logic_vector(r.req_cnt);
    stat_cfg_errors  <= std_logic_vector(r.cfg_err);

    ------------------------------------------------------------------
    -- Select the length of the next burst to present.  Random mode
    -- draws from the length PRNG and clamps to cfg_max_len (masked to
    -- the length width, so values above cfg_max_len clump at the max -
    -- acceptable for traffic generation and keeps the logic divider-free).
    -- Fixed mode uses cfg_req_len (clamped to GC_MAX_BURST-1 as a
    -- safety net; an out-of-range config is counted as a cfg error).
    ------------------------------------------------------------------
    v_cfg_clamp := false;
    if cfg_len_mode = '1' then
      v_len_i := unsigned(prng_len(C_LEN_WIDTH-1 downto 0));
      if v_len_i > unsigned(cfg_max_len) then
        v_len_i := unsigned(cfg_max_len);
      end if;
    else
      v_len_i := unsigned(cfg_req_len);
      if v_len_i > GC_MAX_BURST - 1 then
        v_len_i := to_unsigned(GC_MAX_BURST - 1, C_LEN_WIDTH);
        v_cfg_clamp := true;
      end if;
    end if;

    -- Burst geometry for the selected length.  Widen to 32 bits before
    -- the +1 and *GC_DATA_BYTES: v_len_i alone cannot hold len+1 at the
    -- top of its range, and a narrow multiply would truncate
    -- GC_DATA_BYTES (e.g. 64 in 5 bits).
    v_bsize := resize(v_len_i, 32);
    v_bsize := resize((v_bsize + 1) * GC_DATA_BYTES, 32);
    v_max_start := unsigned(cfg_base_addr) + unsigned(cfg_addr_range) -
                   resize(v_bsize, GC_ADDR_WIDTH);

    ------------------------------------------------------------------
    -- A presented request is held until accepted.  The next address and
    -- length are selected only on the req_valid & req_ready handshake.
    ------------------------------------------------------------------
    if r.req_valid = '1' then
      -- A request is presented; wait for the handshake.
      if req_ready = '1' then
        v.req_cnt := r.req_cnt + 1;
        if v_cfg_clamp then
          v.cfg_err := r.cfg_err + 1;
        end if;

        if cfg_addr_mode = '1' then
          -- Random:  offset uniform in [0, range-bsize], aligned.
          prng_step <= '1';
          v_off := unsigned(prng_data(GC_ADDR_WIDTH-1 downto 0))
                   and (unsigned(cfg_addr_range) - 1);
          v_off := v_off and C_ALIGN;
          if v_bsize <= unsigned(cfg_addr_range) and
             v_off > v_max_start - unsigned(cfg_base_addr) then
            v_off := (v_max_start - unsigned(cfg_base_addr)) and C_ALIGN;
          end if;
          v.cur_addr := unsigned(cfg_base_addr) + v_off;
        else
          -- Linear:  advance by the selected burst size; wrap to base.
          v_next := r.req_addr + resize(v_bsize, GC_ADDR_WIDTH);
          if v_bsize <= unsigned(cfg_addr_range) and v_next > v_max_start then
            v_next := unsigned(cfg_base_addr);
          end if;
          v.cur_addr := v_next and C_ALIGN;
        end if;

        v.pace_cnt := resize(unsigned(cfg_pace), 32);
        if v_gate = '1' and unsigned(cfg_pace) = 0 then
          -- Present the next burst immediately (line rate).
          prng_len_step <= '1';
          v.req_valid := '1';
          v.req_addr  := fit_addr(v.cur_addr, unsigned(cfg_base_addr), v_max_start);
          v.req_len   := std_logic_vector(v_len_i);
        else
          v.req_valid := '0';
        end if;
      else
        v.req_stall_cnt := r.req_stall_cnt + 1;
      end if;
    elsif v_gate = '1' and r.pace_cnt <= 1 then
      -- Present now: pace_cnt is 0 (reset / first burst) or 1 (last idle
      -- cycle of a paced gap).  This keeps the req-to-req gap at
      -- cfg_pace+1 cycles (cfg_pace=1 -> every 2nd cycle).
      prng_len_step <= '1';
      v.req_valid := '1';
      v.req_addr  := fit_addr(r.cur_addr, unsigned(cfg_base_addr), v_max_start);
      v.req_len   := std_logic_vector(v_len_i);
      v.pace_cnt  := resize(unsigned(cfg_pace), 32);
    elsif v_gate = '1' then
      v.req_valid := '0';
      v.pace_cnt  := r.pace_cnt - 1;
    else
      v.req_valid := '0';
    end if;

    -- stat_rst takes priority:  override the counters at the end so a
    -- coincident handshake cannot resurrect them (the generator keeps
    -- presenting requests regardless).  Reset values are single-sourced
    -- from C_REG_DEFAULT.
    if stat_rst = '1' then
      v.req_stall_cnt := C_REG_DEFAULT.req_stall_cnt;
      v.req_cnt       := C_REG_DEFAULT.req_cnt;
      v.cfg_err       := C_REG_DEFAULT.cfg_err;
    end if;

    r_in <= v;  -- latch next state
  end process p_comb;

  ---------------------------------------------------------------------
  -- Synchronous reset.  The first request is cfg_base_addr and the
  -- initial cfg_pace delay is loaded from cfg_pace_init.
  ---------------------------------------------------------------------
  p_reg : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        r <= C_REG_DEFAULT;
        r.cur_addr <= unsigned(cfg_base_addr);
        -- Load one extra cycle: the first present fires when pace_cnt <= 1,
        -- so an initial value of cfg_pace_init delays the first req by
        -- cfg_pace_init+1 cycles (cfg_pace_init=0 -> cycle 1, =1 -> cycle 2),
        -- matching the cfg_pace+1 inter-burst gap convention.
        r.pace_cnt <= resize(unsigned(cfg_pace_init) + 1, 32);
      else
        r <= r_in;
      end if;
    end if;
  end process p_reg;

end architecture;
