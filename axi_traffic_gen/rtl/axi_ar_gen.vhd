-----------------------------------------------------------------------
--Filename         : axi_ar_gen.vhd
--Description      : Lightweight AXI4 read-address generator.
--                 : enable and aperture form the generation gate.
--                 : cfg_pace_init delays the first burst by
--                 : cfg_pace_init+1 cycles (matching the cfg_pace+1 gap
--                 : convention; the +1 comes from presenting at pace_cnt<=1);
--                 : cfg_pace is reloaded after each accepted address.
--                 :
--                 : cfg_arlen is the AXI ARLEN value (beats-1), the
--                 : same encoding as the ar_len output port:  0 means
--                 : a 1-beat burst, 15 a 16-beat burst, etc.
--                 :
--                 : Linear and pseudo-random addressing stay within the
--                 : configured window and align starts to C_DATA_BYTES.
--                 : cfg_arlen is sized by GC_MAX_BURST.
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

entity axi_ar_gen is
  generic (
    GC_DATA_BYTES : positive := 16;
    GC_ADDR_WIDTH : positive := 49;
    GC_ID_WIDTH   : positive := 6;
    GC_MAX_BURST  : positive := 256  -- max beats per burst: 256 (AXI4) / 16 (AXI3)
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Control
    enable   : in std_logic;   -- per-instance enable
    aperture : in std_logic;   -- measurement window
    stat_rst : in std_logic;   -- clears statistic counters

    cfg_id         : in std_logic_vector(GC_ID_WIDTH-1 downto 0);
    cfg_arlen      : in std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);  -- AXI arlen (beats-1); 0 = 1 beat
    cfg_pace       : in std_logic_vector(31 downto 0);  -- idle cycles between ARs (0 = every cycle)
    cfg_pace_init  : in std_logic_vector(31 downto 0);  -- delay before first burst
    cfg_base_addr  : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    cfg_addr_range : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    -- NOTE: random mode (cfg_addr_mode='1') requires cfg_addr_range to be a
    -- power of two (offset is a bit-mask).  Linear mode accepts any
    -- range.
    cfg_addr_mode  : in std_logic;  -- '0' = linear sweep, '1' = pseudo-random

    -- AXI Read-Address Channel (master -> DUT)
    ar_valid   : out std_logic;
    ar_ready   : in  std_logic;
    ar_id      : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr    : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len     : out std_logic_vector(7 downto 0);  -- beats-1
    ar_size    : out std_logic_vector(2 downto 0);  -- bytes per beat (log2 of data width)
    ar_burst   : out std_logic_vector(1 downto 0);  -- always INCR

    -- Statistics (plain register reads, no pipeline latency)
    stat_ar_stall    : out std_logic_vector(31 downto 0);
    stat_ar_issued   : out std_logic_vector(31 downto 0);
    stat_cfg_errors  : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of axi_ar_gen is

  -- Low-bit alignment mask:  forces the low log2(C_DATA_BYTES) address
  -- bits to 0 so every access starts on a C_DATA_BYTES multiple.
  constant C_ALIGN    : unsigned(GC_ADDR_WIDTH-1 downto 0) :=
                          not to_unsigned(GC_DATA_BYTES - 1, GC_ADDR_WIDTH);
  constant C_AR_SIZE  : std_logic_vector(2 downto 0) :=
                          std_logic_vector(to_unsigned(log2ceil(GC_DATA_BYTES), 3));
  constant C_AR_BURST : std_logic_vector(1 downto 0) := "01";  -- INCR

  type reg_t is record
    cur_addr     : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- next address to present
    ar_addr      : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- registered address output
    ar_id        : std_logic_vector(GC_ID_WIDTH-1 downto 0); -- registered ID output
    ar_len       : std_logic_vector(7 downto 0);             -- registered ARLEN output
    ar_valid     : std_logic;                           -- registered valid output
    pace_cnt     : unsigned(31 downto 0);               -- cfg_pace downcounter
    ar_stall_cnt : unsigned(31 downto 0);               -- AR stall events (valid, not ready)
    ar_cnt       : unsigned(31 downto 0);               -- ARs successfully issued
    cfg_err      : unsigned(31 downto 0);               -- config error count
  end record;

  constant C_REG_DEFAULT : reg_t := (
    cur_addr     => (others => '0'),
    ar_addr      => (others => '0'),
    ar_id        => (others => '0'),
    ar_len       => (others => '0'),
    ar_valid     => '0',
    pace_cnt     => (others => '0'),
    ar_stall_cnt => (others => '0'),
    ar_cnt       => (others => '0'),
    cfg_err      => (others => '0')
  );

  signal r    : reg_t := C_REG_DEFAULT;  -- current state (registered)
  signal r_in : reg_t;                   -- next state (combinational output)

  -- Internal enable/aperture gate
  signal gate : std_logic;

  -- xoroshiro128+ PRNG from the shared xorshift128 entity -- 64-bit
  -- pseudo-random values for random mode.
  -- Stepped once per issue when cfg_addr_mode='1'.
  signal prng_data : std_logic_vector(63 downto 0);
  signal prng_step : std_logic;

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

  ar_size  <= C_AR_SIZE;
  ar_burst <= C_AR_BURST;
  gate <= enable and aperture;

  -- Instantiate xoroshiro128+ PRNG for random address generation
  u_prng : entity work.xorshift128
    port map (
      clk  => aclk,
      rstn => aresetn,
      step => prng_step,
      data => prng_data
    );

  ---------------------------------------------------------------------
  -- Next-state logic.  Outputs are registered through r; ar_valid and
  -- ar_addr remain unchanged until the AXI handshake is accepted.
  ---------------------------------------------------------------------
  p_comb : process(all)
    variable v            : reg_t;
    variable v_arlen_i    : unsigned(31 downto 0);  -- cfg_arlen after clamping
    variable v_bsize      : unsigned(31 downto 0);
    variable v_off        : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- random offset
    variable v_max_start  : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- base+range-bsize
    variable v_next       : unsigned(GC_ADDR_WIDTH-1 downto 0);
    variable v_cfg_clamp  : boolean;
  begin
    v := r;  -- recover current state as default for all fields

    ar_valid  <= r.ar_valid;
    ar_addr   <= std_logic_vector(r.ar_addr);
    ar_id     <= r.ar_id;
    ar_len    <= r.ar_len;
    prng_step <= '0';

    stat_ar_stall    <= std_logic_vector(r.ar_stall_cnt);
    stat_ar_issued   <= std_logic_vector(r.ar_cnt);
    stat_cfg_errors  <= std_logic_vector(r.cfg_err);

    if stat_rst = '1' then
      v.ar_stall_cnt := (others => '0');
      v.ar_cnt       := (others => '0');
      v.cfg_err      := (others => '0');
    end if;

    ------------------------------------------------------------------
    -- Calculate burst size and the highest legal start address.
    ------------------------------------------------------------------
    v_arlen_i := resize(unsigned(cfg_arlen), 32);
    v_cfg_clamp := false;
    if v_arlen_i > GC_MAX_BURST - 1 then
      v_arlen_i := to_unsigned(GC_MAX_BURST - 1, 32);
      v_cfg_clamp := true;
    end if;
    v_bsize := resize((v_arlen_i + 1) * GC_DATA_BYTES, 32);
    v_max_start := unsigned(cfg_base_addr) + unsigned(cfg_addr_range) -
                   resize(v_bsize, GC_ADDR_WIDTH);

    ------------------------------------------------------------------
    -- A presented address is held until accepted.  The next address is
    -- selected only on the ar_valid & ar_ready handshake.
    ------------------------------------------------------------------
    if r.ar_valid = '1' then
      -- A value is presented; wait for the handshake.
      if ar_ready = '1' then
        v.ar_cnt := r.ar_cnt + 1;
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
          -- Linear:  advance by one burst; wrap to base past the end.
          v_next := r.ar_addr + resize(v_bsize, GC_ADDR_WIDTH);
          if v_bsize <= unsigned(cfg_addr_range) and v_next > v_max_start then
            v_next := unsigned(cfg_base_addr);
          end if;
          v.cur_addr := v_next and C_ALIGN;
        end if;

        v.pace_cnt := resize(unsigned(cfg_pace), 32);
        if gate = '1' and unsigned(cfg_pace) = 0 then
          v.ar_valid := '1';
          v.ar_addr  := fit_addr(v.cur_addr, unsigned(cfg_base_addr), v_max_start);
          v.ar_id    := cfg_id;
          v.ar_len   := std_logic_vector(resize(v_arlen_i, 8));
        else
          v.ar_valid := '0';
        end if;
      else
        v.ar_stall_cnt := r.ar_stall_cnt + 1;
      end if;
    elsif gate = '1' and r.pace_cnt <= 1 then
      -- Present now: pace_cnt is 0 (reset / first burst) or 1 (last idle
      -- cycle of a paced gap).  Asserting here keeps the AR-to-AR gap at
      -- cfg_pace+1 cycles (cfg_pace=1 -> every 2nd cycle).
      v.ar_valid := '1';
      v.ar_addr  := fit_addr(r.cur_addr, unsigned(cfg_base_addr), v_max_start);
      v.ar_id    := cfg_id;
      v.ar_len   := std_logic_vector(resize(v_arlen_i, 8));
      v.pace_cnt := resize(unsigned(cfg_pace), 32);
    elsif gate = '1' then
      v.ar_valid := '0';
      v.pace_cnt := r.pace_cnt - 1;
    else
      v.ar_valid := '0';
    end if;

    r_in <= v;  -- latch next state
  end process p_comb;

  ---------------------------------------------------------------------
  -- Synchronous reset.  The first address is cfg_base_addr and the initial
  -- cfg_pace delay is loaded from cfg_pace_init.
  ---------------------------------------------------------------------
  p_reg : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        r <= C_REG_DEFAULT;
        r.cur_addr <= unsigned(cfg_base_addr);
        -- Load one extra cycle: the first present fires when pace_cnt <= 1,
        -- so an initial value of cfg_pace_init delays the first AR by
        -- cfg_pace_init+1 cycles (cfg_pace_init=0 -> cycle 1, =1 -> cycle 2),
        -- matching the cfg_pace+1 inter-burst gap convention.
        r.pace_cnt <= resize(unsigned(cfg_pace_init) + 1, 32);
      else
        r <= r_in;
      end if;
    end if;
  end process p_reg;

end architecture;
