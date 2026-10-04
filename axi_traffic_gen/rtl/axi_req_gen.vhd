-----------------------------------------------------------------------
--Filename         : axi_req_gen.vhd
--Description      : Rate-limited client read-request (req) generator.
--                 : The client interface has no ID field.  enable and
--                 : aperture form the generation gate.
--                 :
--                 : Rate control is a credit bucket:
--                 :   * pace_cnt is a divider.  While the gate is open
--                 :     it counts down; every time it reaches 0 it
--                 :     reloads cfg_pace and mints one credit, so a
--                 :     credit appears every cfg_pace+1 cycles.
--                 :   * credit is an 8-bit saturating counter (max
--                 :     255).  It is decremented on every accepted
--                 :     request (req_valid and req_ready).
--                 :   * a request is presented whenever the gate is
--                 :     open and credit is non-zero.  A presented
--                 :     request is held until accepted (AXI requires
--                 :     valid to stay high), so a burst is never cut
--                 :     short.
--                 :
--                 : The divider does not stop for backpressure, so a
--                 : downstream stall does not lose bandwidth: credits
--                 : accumulate (up to 255) and are then spent
--                 : back-to-back once req_ready returns.  cfg_pace is
--                 : therefore a bandwidth requirement, not a minimum
--                 : gap.
--                 :
--                 : While the gate is closed the divider is re-armed
--                 : with cfg_pace_init and the credit bucket is
--                 : cleared, so every aperture starts from the same
--                 : state and no debt crosses a window boundary.
--                 : cfg_pace_init is the phase offset of the first
--                 : credit: the first request is presented
--                 : cfg_pace_init+1 cycles after the gate opens
--                 : (cfg_pace_init=0 -> first gated cycle).  With
--                 : several instances sharing one aperture, it staggers
--                 : the instances.
--                 :
--                 : cfg_req_len is the request length (beats-1), the
--                 : same encoding as the req_len output port:  0 means
--                 : a 1-beat request, 31 a 32-beat request, etc.
--                 : With cfg_len_mode='1' every presented burst draws
--                 : its length from an independent xorshift32 PRNG.  The
--                 : draw is uniform over 0..cfg_max_len, so burst lengths
--                 : are uniform between 1 and cfg_max_len+1 beats (see
--                 : the random-length note below).
--                 :
--                 : Linear and pseudo-random addressing stay within the
--                 : configured window and align starts to C_DATA_BYTES;
--                 : in random-length mode each burst is fitted to its
--                 : own drawn length, and the linear sweep advances by
--                 : the burst size that was actually accepted.
--                 :
--                 : Timing note: no dividers or multipliers anywhere.
--                 : Random addressing uses a bit-mask, so cfg_addr_range
--                 : must be a power of two when cfg_addr_mode='1'.  The
--                 : random-length draw also uses a bit-mask and adds
--                 : rejection of out-of-range draws, so it stays uniform
--                 : without a modulo (see below).
--                 :
--                 : This block keeps no statistics.  Rate and stall
--                 : measurement belongs to axi_monitor, which taps the
--                 : same req channel and is the single source of truth.
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

    cfg_req_len    : in std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);  -- beats-1; 0 = 1 beat
    cfg_len_mode   : in std_logic;                                            -- '0' = fixed cfg_req_len, '1' = random length
    cfg_max_len    : in std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);  -- random length upper bound (beats-1)
    cfg_pace       : in std_logic_vector(31 downto 0);                        -- one request credit per cfg_pace+1 cycles
    cfg_pace_init  : in std_logic_vector(31 downto 0);                        -- phase offset of the first credit
    cfg_base_addr  : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    cfg_addr_range : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    -- NOTE: random mode (cfg_addr_mode='1') requires cfg_addr_range to be a
    -- power of two (offset is a bit-mask).  Linear mode accepts any range.
    cfg_addr_mode : in std_logic;  -- '0' = linear sweep, '1' = pseudo-random

    -- Client request channel (master -> consumer)
    req_valid : out std_logic;
    req_ready : in  std_logic;
    req_addr  : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    req_len   : out std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0)  -- beats-1
  );
end entity;

architecture rtl of axi_req_gen is

  constant C_LEN_WIDTH : positive := log2ceil(GC_MAX_BURST);
  constant C_AXI_PAGE_BYTES : positive := 4096;

  -- Credit bucket ceiling.  The bucket saturates here and never wraps, so
  -- a long downstream stall can never build an unbounded debt.
  constant C_CREDIT_MAX : unsigned(7 downto 0) := (others => '1');

  -- Low-bit alignment mask:  forces the low log2(C_DATA_BYTES) address
  -- bits to 0 so every access starts on a C_DATA_BYTES multiple.
  constant C_ALIGN : unsigned(GC_ADDR_WIDTH-1 downto 0) :=
                       not to_unsigned(GC_DATA_BYTES - 1, GC_ADDR_WIDTH);

  type reg_t is record
    cur_addr  : unsigned(GC_ADDR_WIDTH-1 downto 0);        -- next address to present
    req_addr  : unsigned(GC_ADDR_WIDTH-1 downto 0);        -- registered address output
    req_len   : std_logic_vector(C_LEN_WIDTH-1 downto 0);  -- registered length output
    req_valid : std_logic;                                 -- registered valid output
    pace_cnt  : unsigned(31 downto 0);                     -- rate divider (reload = cfg_pace)
    credit    : unsigned(7 downto 0);                      -- saturating request credit
  end record;

  constant C_REG_DEFAULT : reg_t := (
    cur_addr  => (others => '0'),
    req_addr  => (others => '0'),
    req_len   => (others => '0'),
    req_valid => '0',
    pace_cnt  => (others => '0'),
    credit    => (others => '0')
  );

  signal r : reg_t := C_REG_DEFAULT;  -- current state (registered)
  signal r_in : reg_t;  -- next state (combinational output)

  -- xoroshiro128+ PRNG for random address mode.
  signal prng_data : std_logic_vector(63 downto 0);
  signal prng_step : std_logic;

  -- xorshift32 PRNG for random request-length mode (independent seed).
  -- It free-runs while cfg_len_mode='1', so a draw rejected as
  -- out-of-range is always replaced by a fresh one on the next cycle.
  signal prng_len      : std_logic_vector(31 downto 0);
  signal prng_len_step : std_logic;

  ---------------------------------------------------------------------
  -- Clamp a candidate start address into [base, top], force the low bits to
  -- 0 (C_DATA_BYTES alignment), and keep the complete AXI burst inside one
  -- 4 KiB page. AXI bursts must not cross a 4 KiB boundary.
  ---------------------------------------------------------------------
  function fit_addr(
    constant addr : in unsigned(GC_ADDR_WIDTH-1 downto 0);
    constant base : in unsigned(GC_ADDR_WIDTH-1 downto 0);
    constant top  : in unsigned(GC_ADDR_WIDTH-1 downto 0);
    constant burst_bytes : in unsigned(31 downto 0)
  ) return unsigned is
    variable v_a          : unsigned(GC_ADDR_WIDTH-1 downto 0);
    variable v_page_base  : unsigned(GC_ADDR_WIDTH-1 downto 0);
    variable v_page_offset : unsigned(GC_ADDR_WIDTH-1 downto 0);
    variable v_page_limit : unsigned(GC_ADDR_WIDTH-1 downto 0);
  begin
    if addr < base then
      v_a := base;
    elsif addr > top then
      v_a := top;
    else
      v_a := addr;
    end if;
    v_a := v_a and C_ALIGN;
    if burst_bytes <= C_AXI_PAGE_BYTES then
      v_page_base := v_a and not to_unsigned(
        C_AXI_PAGE_BYTES - 1, GC_ADDR_WIDTH);
      v_page_offset := v_a - v_page_base;
      v_page_limit := to_unsigned(C_AXI_PAGE_BYTES, GC_ADDR_WIDTH) -
                      resize(burst_bytes, GC_ADDR_WIDTH);
      if v_page_offset > v_page_limit then
        v_a := v_page_base + v_page_limit;
        if v_a < base then
          v_a := base;
        elsif v_a > top then
          v_a := top;
        end if;
        v_a := v_a and C_ALIGN;
      end if;
    end if;
    return v_a;
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

  -- Length PRNG (random request length, free-running while cfg_len_mode is
  -- set; the draw is consumed or rejected at each presentation point).
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
    variable v_accepted_bsize : unsigned(31 downto 0);        -- bytes in the accepted request
    variable v_max_start : unsigned(GC_ADDR_WIDTH-1 downto 0);-- base+range-bsize
    variable v_off       : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- random offset
    variable v_next      : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- linear next address
    variable v_present_addr : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- address to present (post-wrap)
    variable v_gate      : std_logic;  -- enable and aperture (combinational, local)
    variable v_credit    : unsigned(7 downto 0);  -- bucket after this cycle's mint/consume
    variable v_advance   : boolean;    -- a request was accepted this cycle
    variable v_max_len   : unsigned(C_LEN_WIDTH-1 downto 0);  -- clipped random bound
    variable v_mask      : unsigned(C_LEN_WIDTH-1 downto 0);  -- draw-range mask
    variable v_cand      : unsigned(C_LEN_WIDTH-1 downto 0);  -- length draw
    variable v_len_ok    : boolean;    -- draw within 0..v_max_len
  begin
    v := r;  -- recover current state as default for all fields
    v_gate := enable and aperture;

    req_valid <= r.req_valid;
    req_addr  <= std_logic_vector(r.req_addr);
    req_len   <= r.req_len;
    prng_step <= '0';
    -- The length PRNG free-runs while random lengths are enabled, so a
    -- rejected draw is always replaced by a fresh one on the next cycle.
    prng_len_step <= cfg_len_mode;

    ------------------------------------------------------------------
    -- Select the length of the next burst to present.
    --
    -- Fixed mode uses cfg_req_len (clamped to GC_MAX_BURST-1 as a safety
    -- net; an out-of-range config cannot be reported here -- the clamp is
    -- uncounted by design, this block keeps no statistics).
    --
    -- Random mode draws uniformly from 0..cfg_max_len without a divider:
    --
    --   1. v_mask trims the draw range to the power of two that covers
    --      0..v_max_len, i.e. to 0..2**k-1, so the draw stays uniform.
    --   2. a draw above v_max_len is rejected and simply not presented;
    --      the free-running PRNG offers a fresh draw one cycle later.
    --
    -- Rejection is what makes the surviving distribution exactly uniform
    -- over 0..v_max_len (a plain mask-and-clamp would clump at the top).
    -- The acceptance rate is N/2**k with N = v_max_len+1 > 2**(k-1), so a
    -- draw is accepted at least every second cycle.  When v_max_len+1 is
    -- itself a power of two nothing is ever rejected, and random-length
    -- mode then runs at exactly the configured cfg_pace.
    ------------------------------------------------------------------
    if cfg_len_mode = '1' then
      v_max_len := unsigned(cfg_max_len);
      if v_max_len > GC_MAX_BURST - 1 then
        -- Safety net: keep every generated burst inside the credit limit.
        v_max_len := to_unsigned(GC_MAX_BURST - 1, C_LEN_WIDTH);
      end if;
      -- Mask covering all bits below and including the highest set bit of
      -- v_max_len:  bit i is set when v_max_len >= 2**i.
      v_mask(C_LEN_WIDTH-1) := v_max_len(C_LEN_WIDTH-1);
      for i in C_LEN_WIDTH-2 downto 0 loop
        v_mask(i) := v_mask(i+1) or v_max_len(i);
      end loop;
      -- Take the top C_LEN_WIDTH bits of the PRNG (the best-mixed bits of
      -- xorshift32) and trim them to the draw range.
      v_cand   := resize(unsigned(prng_len(31 downto 32 - C_LEN_WIDTH)),
                         C_LEN_WIDTH) and v_mask;
      v_len_i  := v_cand;
      v_len_ok := v_cand <= v_max_len;
    else
      v_len_i  := unsigned(cfg_req_len);
      v_len_ok := true;
      if v_len_i > GC_MAX_BURST - 1 then
        -- Safety net: keep every generated burst inside the credit limit.
        v_len_i := to_unsigned(GC_MAX_BURST - 1, C_LEN_WIDTH);
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
    -- Credit bucket and rate divider.
    --
    -- The divider free-runs while the gate is open and never stops for
    -- backpressure, so credits keep accumulating during a stall and the
    -- request rate over an aperture is preserved.  Minting and spending
    -- can happen in the same cycle, which keeps catch-up requests
    -- back-to-back instead of one request per two cycles.
    ------------------------------------------------------------------
    v_credit  := r.credit;
    v_advance := false;

    -- Spend one credit on every accepted request.
    if r.req_valid = '1' and req_ready = '1' then
      v_advance := true;
      if v_credit /= 0 then
        v_credit := v_credit - 1;
      end if;
    end if;

    if v_gate = '0' then
      -- Gate closed: re-arm the phase and discard any debt, so every
      -- aperture starts from the same state.
      v.pace_cnt := resize(unsigned(cfg_pace_init), 32);
      v_credit   := (others => '0');
    elsif r.pace_cnt = 0 then
      -- Mint one credit and reload the divider (period = cfg_pace+1).
      if v_credit /= C_CREDIT_MAX then
        v_credit := v_credit + 1;
      end if;
      v.pace_cnt := resize(unsigned(cfg_pace), 32);
    else
      v.pace_cnt := r.pace_cnt - 1;
    end if;

    v.credit := v_credit;

    ------------------------------------------------------------------
    -- Address for the following request.  Stepped once per accepted
    -- request, so v.cur_addr always holds the address to present next.
    ------------------------------------------------------------------
    if v_advance then
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
        -- Linear: advance by the size of the request actually accepted.
        -- The next candidate length may be rejected, so defer deciding
        -- whether this address wraps until a valid next length is selected.
        v_accepted_bsize := resize(unsigned(r.req_len), 32);
        v_accepted_bsize := resize((v_accepted_bsize + 1) * GC_DATA_BYTES, 32);
        v_next := r.req_addr + resize(v_accepted_bsize, GC_ADDR_WIDTH);
        v.cur_addr := v_next and C_ALIGN;
      end if;
    end if;

    ------------------------------------------------------------------
    -- Request presentation.  A presented request is held (valid, address
    -- and length unchanged) until it is accepted: AXI requires valid to
    -- stay high, so a burst is never cut short, even if the gate closes
    -- before the handshake.
    ------------------------------------------------------------------
    if r.req_valid = '1' and req_ready = '0' then
      v.req_valid := '1';                   -- stalled: hold it
    elsif v_gate = '1' and v_credit /= 0 then
      if v_len_ok then
        v.req_valid := '1';
        v_present_addr := v.cur_addr;
        if cfg_addr_mode = '0' and v_bsize <= unsigned(cfg_addr_range) and
           v_present_addr > v_max_start then
          v_present_addr := unsigned(cfg_base_addr);
        end if;
        v.req_addr  := fit_addr(v_present_addr, unsigned(cfg_base_addr),
                                v_max_start, v_bsize);
        v.req_len   := std_logic_vector(v_len_i);
      else
        -- Rejected random-length draw: no request this cycle.  The
        -- credit is kept, so the retry does not cost bandwidth.
        v.req_valid := '0';
      end if;
    else
      v.req_valid := '0';
    end if;

    r_in <= v;  -- latch next state
  end process p_comb;

  ---------------------------------------------------------------------
  -- Synchronous reset.  The first request is cfg_base_addr and the
  -- divider is re-armed from cfg_pace_init.
  ---------------------------------------------------------------------
  p_reg : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        r <= C_REG_DEFAULT;
        r.cur_addr <= unsigned(cfg_base_addr);
        -- Re-arm the divider: the first credit is minted cfg_pace_init+1
        -- cycles after the gate opens (cfg_pace_init=0 -> first gated
        -- cycle), matching the cfg_pace+1 credit period.
        r.pace_cnt <= resize(unsigned(cfg_pace_init), 32);
      else
        r <= r_in;
      end if;
    end if;
  end process p_reg;

end architecture;
