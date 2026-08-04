-----------------------------------------------------------------------
--Filename         : axi_ar_gen.vhd
--Description      : Lightweight AXI4 Read-Address Generator.
--                 : Issues AR bursts at a configurable pace, decoupled
--                 : from R completion.  With pace=0 a new AR can be
--                 : issued on every clock cycle (back-to-back); pace=1
--                 : issues every second cycle, pace=2 every third, ...
--                 :
--                 : ar_length is the AXI ARLEN value (beats-1), the
--                 : same encoding as the ar_len output port:  0 means
--                 : a 1-beat burst, 15 a 16-beat burst, etc.
--                 :
--                 : Linear sweep and pseudo-random (XOR-shift)
--                 : addressing within a configurable window.  Includes
--                 : 4KB boundary guard and config-error detection.
--                 :
--                 : Simplified from axi_read_tester_ar_gen: the
--                 : scoreboard push is removed (the axi_monitor builds
--                 : its own scoreboard from the tapped AR bus), which
--                 : eliminates the S_SB_PUSH bubble so pace=0 achieves
--                 : one AR per cycle.
--                 :
--                 : Timing note: no dividers or multipliers anywhere;
--                 : random addressing uses a bit-mask, so addr_range
--                 : must be a power of two when addr_mode='1'.
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
    stat_rst : in std_logic;   -- clears stat counters (not the FSM)

    arid         : in std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_length    : in std_logic_vector(31 downto 0);  -- AXI arlen (beats-1); 0 = 1 beat
    pace         : in std_logic_vector(31 downto 0);  -- idle cycles between ARs (0 = every cycle)
    pace_init    : in std_logic_vector(31 downto 0);  -- delay before first burst
    base_addr    : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    addr_range   : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    -- NOTE: random mode (addr_mode='1') requires addr_range to be a
    -- power of two (offset is a bit-mask).  Linear mode accepts any
    -- range.
    addr_mode    : in std_logic;  -- '0' = linear sweep, '1' = pseudo-random

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

  constant C_4KB : positive := 4096;

  ---------------------------------------------------------------------
  -- 3-state FSM:
  --   S_IDLE      -> wait for enable + aperture; init address & pace
  --   S_PACE_WAIT -> count down inter-burst pacing delay
  --   S_AR_ISSUE  -> drive AR valid; wait for ar_ready handshake
  --
  -- Flow:  IDLE -> PACE_WAIT -> AR_ISSUE -> PACE_WAIT -> ...
  --
  -- pace=0 special case:  after a handshake the FSM stays in
  -- S_AR_ISSUE (no PACE_WAIT round-trip), so ar_valid is re-driven on
  -- the very next cycle -- one AR per clock cycle.
  ---------------------------------------------------------------------
  type state_t is (S_IDLE, S_PACE_WAIT, S_AR_ISSUE);

  type reg_t is record
    state     : state_t;
    cur_addr  : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- current read address
    blen      : unsigned(7 downto 0);                -- AXI arlen (beats-1)
    pace_cnt  : unsigned(31 downto 0);               -- inter-burst pacing counter
    ar_stall_cnt : unsigned(31 downto 0);              -- AR stall events (valid, not ready)
    ar_cnt    : unsigned(31 downto 0);               -- ARs successfully issued
    cfg_err   : unsigned(31 downto 0);               -- config error count
  end record;

  constant C_REG_DEFAULT : reg_t := (
    state     => S_IDLE,
    cur_addr  => (others => '0'),
    blen      => (others => '0'),
    pace_cnt  => (others => '0'),
    ar_stall_cnt => (others => '0'),
    ar_cnt    => (others => '0'),
    cfg_err   => (others => '0')
  );

  signal r    : reg_t := C_REG_DEFAULT;  -- current state (registered)
  signal r_in : reg_t;                   -- next state (combinational output)

  -- xoroshiro128+ PRNG -- 64-bit pseudo-random values for random mode.
  -- Stepped once per burst when addr_mode='1'.
  signal prng_data : std_logic_vector(63 downto 0);
  signal prng_step : std_logic;

begin

  -- Instantiate xoroshiro128+ PRNG for random address generation
  u_prng : entity work.xorshift128
    port map (
      clk  => aclk,
      rstn => aresetn,
      step => prng_step,
      data => prng_data
    );

  ---------------------------------------------------------------------
  -- Combinational process -- two-process register-transfer pattern.
  --   r    = current state (from p_reg)
  --   v    = next-state variable (computed here)
  --   r_in = latched next state (to p_reg)
  ---------------------------------------------------------------------
  p_comb : process(r, arid, ar_length, pace, pace_init, base_addr,
                   addr_range, addr_mode, enable, aperture,
                   ar_ready, stat_rst)
    variable v         : reg_t;
    variable v_bsize   : unsigned(31 downto 0);
    variable v_arlen_i : unsigned(31 downto 0);  -- ar_length after clamping (AXI arlen)
    variable v_end     : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- window end (base+range)
    variable v_off     : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- random offset in window
    variable v_4kb_end : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- next 4 KiB boundary
    variable v_issue_addr : unsigned(GC_ADDR_WIDTH-1 downto 0);
  begin
    v := r;  -- recover current state as default for all fields

    -- Default outputs -- all de-asserted, overridden in specific states
    ar_valid  <= '0';
    ar_id     <= arid;
    ar_addr   <= (others => '0');
    ar_len    <= (others => '0');
    ar_size   <= (others => '0');
    ar_burst  <= "00";
    prng_step <= '0';

    -- Statistics are direct register reads -- no pipeline latency
    stat_ar_stall    <= std_logic_vector(r.ar_stall_cnt);
    stat_ar_issued   <= std_logic_vector(r.ar_cnt);
    stat_cfg_errors  <= std_logic_vector(r.cfg_err);

    -- Stat reset -- clears counters without disrupting the state machine
    if stat_rst = '1' then
      v.ar_stall_cnt := (others => '0');
      v.ar_cnt    := (others => '0');
      v.cfg_err   := (others => '0');
    end if;

    ------------------------------------------------------------------
    -- Configuration clamping -- evaluated every cycle.
    -- Errors logged only when idle so they don't repeat mid-burst.
    ------------------------------------------------------------------

    -- Clamp ar_length:  AXI ARLEN (beats-1), 0 = 1 beat, max GC_MAX_BURST-1.
    v_arlen_i := unsigned(ar_length);
    if v_arlen_i > GC_MAX_BURST - 1 then
      v_arlen_i := to_unsigned(GC_MAX_BURST - 1, 32);
      if r.state = S_IDLE then
        v.cfg_err := r.cfg_err + 1;
      end if;
    end if;

    -- 4 KB boundary guard:  AXI4 forbids bursts crossing a 4 KB boundary.
    -- If burst_size > 4 KB, clamp arlen and log a config error.
    v_bsize := resize((v_arlen_i + 1) * GC_DATA_BYTES, 32);
    if v_bsize > to_unsigned(C_4KB, 32) and r.state = S_IDLE then
      v_arlen_i := to_unsigned(C_4KB / GC_DATA_BYTES - 1, 32);
      v.cfg_err := r.cfg_err + 1;
    end if;

    ------------------------------------------------------------------
    -- State machine
    ------------------------------------------------------------------
    case r.state is

      -- IDLE:  Wait for enable + aperture.
      --        On entry, reset addr to base_addr, load pace_init.
      when S_IDLE =>
        if enable = '1' and aperture = '1' then
          v.pace_cnt := resize(unsigned(pace_init), 32);
          v.cur_addr := unsigned(base_addr);
          v.state    := S_PACE_WAIT;
        end if;

      -- PACE_WAIT:  Count down pacing delay.  When zero, compute blen
      --             and proceed.  Return to IDLE if enable/aperture drops.
      --
      --             Boundary guard (both addressing modes):  the burst
      --             must never read outside [base_addr, base_addr+range).
      --             Clamp the start address:  wrap to base_addr if past
      --             the end, otherwise push the start back so the full
      --             burst fits.  (Address clamp only -- no division.)
      when S_PACE_WAIT =>
        if enable = '0' or aperture = '0' then
          v.state := S_IDLE;
        elsif r.pace_cnt = 0 then
          v_end := unsigned(base_addr) + unsigned(addr_range);
          if r.cur_addr >= v_end then
            v.cur_addr := unsigned(base_addr);
          elsif v_bsize <= unsigned(addr_range) and
                r.cur_addr + resize(v_bsize, GC_ADDR_WIDTH) > v_end then
            v.cur_addr := v_end - resize(v_bsize, GC_ADDR_WIDTH);
          end if;

          -- AXI4 also forbids a burst from crossing a 4 KiB boundary.
          -- If the current start would cross it, prefer the next boundary
          -- when the configured window can contain the burst there.  If
          -- not, place the burst at the end of the current 4 KiB page.
          -- The configured range must be large enough for the burst; that
          -- condition is already checked above before this adjustment.
          if v_bsize <= C_4KB then
            v_4kb_end := (v.cur_addr and
                          not to_unsigned(C_4KB - 1, GC_ADDR_WIDTH)) +
                         to_unsigned(C_4KB, GC_ADDR_WIDTH);
            if v.cur_addr + resize(v_bsize, GC_ADDR_WIDTH) > v_4kb_end then
              if v_4kb_end + resize(v_bsize, GC_ADDR_WIDTH) <= v_end then
                v.cur_addr := v_4kb_end;
              elsif v_4kb_end - resize(v_bsize, GC_ADDR_WIDTH) >=
                    unsigned(base_addr) then
                v.cur_addr := v_4kb_end - resize(v_bsize, GC_ADDR_WIDTH);
              end if;
            end if;
          end if;
          v.blen  := resize(v_arlen_i, 8);
          v.state := S_AR_ISSUE;
        else
          v.pace_cnt := r.pace_cnt - 1;
        end if;

      -- AR_ISSUE:  Drive AR channel.  All bursts use INCR type.
      --            Wait for ar_ready; count stall if not accepted.
      --            On handshake, advance to the next address.
      --              pace=0 -> stay in AR_ISSUE (re-drive next cycle,
      --                        one AR per clock cycle)
      --              pace>0 -> load pacing counter, go to PACE_WAIT
      --
      --            Enable/aperture are checked here too (not only in
      --            PACE_WAIT) because with pace=0 the FSM never passes
      --            through PACE_WAIT again -- otherwise it would keep
      --            issuing forever after enable drops.
      when S_AR_ISSUE =>
        if enable = '0' or aperture = '0' then
          v.state := S_IDLE;
        else
          -- Reapply the address guard here as well as in S_PACE_WAIT.
          -- pace=0 remains in S_AR_ISSUE, so every back-to-back issue
          -- must independently satisfy the window and 4 KiB constraints.
          v_issue_addr := r.cur_addr;
          v_end := unsigned(base_addr) + unsigned(addr_range);
          if v_issue_addr >= v_end then
            v_issue_addr := unsigned(base_addr);
          elsif v_bsize <= unsigned(addr_range) and
                v_issue_addr + resize(v_bsize, GC_ADDR_WIDTH) > v_end then
            v_issue_addr := v_end - resize(v_bsize, GC_ADDR_WIDTH);
          end if;

          if v_bsize <= C_4KB then
            v_4kb_end := (v_issue_addr and
                          not to_unsigned(C_4KB - 1, GC_ADDR_WIDTH)) +
                         to_unsigned(C_4KB, GC_ADDR_WIDTH);
            if v_issue_addr + resize(v_bsize, GC_ADDR_WIDTH) > v_4kb_end then
              if v_4kb_end + resize(v_bsize, GC_ADDR_WIDTH) <= v_end then
                v_issue_addr := v_4kb_end;
              elsif v_4kb_end - resize(v_bsize, GC_ADDR_WIDTH) >=
                    unsigned(base_addr) then
                v_issue_addr := v_4kb_end - resize(v_bsize, GC_ADDR_WIDTH);
              end if;
            end if;
          end if;

          ar_valid  <= '1';
          ar_addr   <= std_logic_vector(v_issue_addr);
          ar_len    <= std_logic_vector(r.blen);
          ar_id     <= arid;
          ar_size   <= std_logic_vector(to_unsigned(log2ceil(GC_DATA_BYTES), 3));
          ar_burst  <= "01";  -- INCR

          if ar_ready = '1' then
            v.ar_cnt := r.ar_cnt + 1;

            -- Advance to next address
            if addr_mode = '1' then
              -- Random addressing within window.  Random mode requires
              -- addr_range to be a power of two, so AND-masking the PRNG
              -- bits with (addr_range-1) gives a uniform offset in
              -- [0, addr_range) -- no multiplier or divider.  The offset
              -- is transfer-aligned, then clamped so the full burst fits.
              prng_step <= '1';
              v_off := unsigned(prng_data(GC_ADDR_WIDTH-1 downto 0))
                       and (unsigned(addr_range) - 1);
              v_off := v_off and
                       (not to_unsigned(GC_DATA_BYTES-1, GC_ADDR_WIDTH));
              if v_bsize <= unsigned(addr_range) and
                 v_off > unsigned(addr_range) - resize(v_bsize, GC_ADDR_WIDTH) then
                v_off := (resize(unsigned(addr_range), GC_ADDR_WIDTH)
                         - resize(v_bsize, GC_ADDR_WIDTH))
                         and (not to_unsigned(GC_DATA_BYTES-1, GC_ADDR_WIDTH));
              end if;
              v.cur_addr := unsigned(base_addr) + v_off;
            else
              -- Linear sweep with wrap
              if v_issue_addr + resize(v_bsize, GC_ADDR_WIDTH) >=
                 unsigned(base_addr) + unsigned(addr_range) then
                v.cur_addr := unsigned(base_addr);
              else
                v.cur_addr := v_issue_addr + resize(v_bsize, GC_ADDR_WIDTH);
              end if;
            end if;

            -- Pacing:  pace=0 -> one AR per cycle;  pace>0 -> paced.
            -- pace is the number of idle cycles between ARs:  pace=1 ->
            -- every 2nd cycle, pace=2 -> every 3rd, etc.  Because
            -- S_PACE_WAIT consumes one cycle before re-entering
            -- S_AR_ISSUE, the counter is loaded with (pace-1).
            if unsigned(pace) = 0 then
              v.state := S_AR_ISSUE;
            else
              v.pace_cnt := resize(unsigned(pace) - 1, 32);
              v.state    := S_PACE_WAIT;
            end if;
          else
            v.ar_stall_cnt := r.ar_stall_cnt + 1;
          end if;
        end if;

    end case;

    r_in <= v;  -- latch next state
  end process p_comb;

  ---------------------------------------------------------------------
  -- Register process -- updates state on rising clock edge.
  -- Synchronous reset (active-low) restores defaults.
  ---------------------------------------------------------------------
  p_reg : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        r <= C_REG_DEFAULT;
      else
        r <= r_in;
      end if;
    end if;
  end process p_reg;

end architecture;
