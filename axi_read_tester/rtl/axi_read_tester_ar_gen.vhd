-----------------------------------------------------------------------
--Filename         : axi_read_tester_ar_gen.vhd
--Description      : AXI4 Read Address Generator.
--                 : Issues AR bursts at a configurable pace rate,
--                 : decoupled from R completion.  Linear sweep and
--                 : pseudo-random (XOR-shift) addressing within a
--                 : configurable window.  Pushes one scoreboard
--                 : entry per burst -- {addr, id, timestamp, beats}.
--                 : Includes 4KB boundary guard and config-error
--                 : detection.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_tester_ar_gen is
  generic (
    GC_DATA_BYTES  : positive := 64;
    GC_ADDR_WIDTH  : positive := 49;
    GC_ID_WIDTH    : positive := 6;
    GC_TIME_WIDTH  : positive := 48;
    GC_MAX_BURST   : positive := 256  -- max beats per burst: 256 (AXI4) / 16 (AXI3)
  );
  port (
    aclk        : in  std_logic;
    aresetn     : in  std_logic;
    global_time : in  std_logic_vector(GC_TIME_WIDTH-1 downto 0);

    enable_local  : in  std_logic;
    aperture      : in  std_logic;

    stat_rst     : in  std_logic;
    arid         : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    burst_length : in  std_logic_vector(31 downto 0);
    pace         : in  std_logic_vector(31 downto 0);
    pace_init    : in  std_logic_vector(31 downto 0);
    base_addr    : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    addr_range   : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    addr_mode    : in  std_logic;

    ar_valid   : out std_logic;
    ar_ready   : in  std_logic;
    ar_id_out  : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr    : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len     : out std_logic_vector(7 downto 0);
    ar_size    : out std_logic_vector(2 downto 0);
    ar_burst   : out std_logic_vector(1 downto 0);

    sb_tdata  : out std_logic_vector(GC_ADDR_WIDTH + GC_ID_WIDTH + GC_TIME_WIDTH + 8 - 1 downto 0);
    sb_tvalid : out std_logic;
    sb_tready : in  std_logic;

    stat_ar_backpressure : out std_logic_vector(31 downto 0);
    stat_sb_backpressure : out std_logic_vector(31 downto 0);
    stat_ar_issued       : out std_logic_vector(31 downto 0);
    stat_cfg_errors      : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of axi_read_tester_ar_gen is

  constant C_SB_WIDTH : positive := GC_ADDR_WIDTH + GC_ID_WIDTH + GC_TIME_WIDTH + 8;
  constant C_4KB      : positive := 4096;

  ---------------------------------------------------------------------
  -- 4-state FSM:
  --   S_IDLE      -> wait for enable + aperture; init address & pace
  --   S_PACE_WAIT -> count down inter-burst pacing delay
  --   S_AR_ISSUE  -> drive AR valid; wait for ar_ready handshake
  --   S_SB_PUSH   -> push scoreboard descriptor; advance to next addr
  --
  -- Flow:  IDLE -> PACE_WAIT -> AR_ISSUE -> SB_PUSH -> PACE_WAIT -> ...
  -- Returns to IDLE if enable or aperture drops.
  ---------------------------------------------------------------------
  type state_t is (S_IDLE, S_PACE_WAIT, S_AR_ISSUE, S_SB_PUSH);

  type reg_t is record
    state      : state_t;
    cur_addr   : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- current read address
    blen       : unsigned(7 downto 0);                 -- AXI arlen (beats-1)
    pace_cnt   : unsigned(31 downto 0);                -- inter-burst pacing counter
    first_run  : std_logic;                            -- '1' = use pace_init
    ar_bp_cnt  : unsigned(31 downto 0);                -- AR backpressure events
    sb_bp_cnt  : unsigned(31 downto 0);                -- scoreboard backpressure events
    ar_cnt     : unsigned(31 downto 0);                -- ARs successfully issued
    cfg_err    : unsigned(31 downto 0);                -- config error count
  end record;

  constant C_REG_DEFAULT : reg_t := (
    state    => S_IDLE,
    cur_addr => (others => '0'),
    blen     => (others => '0'),
    pace_cnt => (others => '0'),
    first_run => '1',
    ar_bp_cnt => (others => '0'),
    sb_bp_cnt => (others => '0'),
    ar_cnt   => (others => '0'),
    cfg_err  => (others => '0')
  );

  signal r    : reg_t := C_REG_DEFAULT;  -- current state (registered)
  signal r_in : reg_t;                   -- next state (combinational output)

  -- Scoreboard field positions: MSB-first {araddr, arid, timestamp, beats}
  constant C_BEATS_LOW   : natural := 0;
  constant C_BEATS_HIGH  : natural := 7;
  constant C_TS_LOW      : natural := C_BEATS_HIGH + 1;
  constant C_TS_HIGH     : natural := C_TS_LOW + GC_TIME_WIDTH - 1;
  constant C_ID_LOW      : natural := C_TS_HIGH + 1;
  constant C_ID_HIGH     : natural := C_ID_LOW + GC_ID_WIDTH - 1;
  constant C_ADDR_LOW    : natural := C_ID_HIGH + 1;
  constant C_ADDR_HIGH   : natural := C_ADDR_LOW + GC_ADDR_WIDTH - 1;

  -- xoroshiro128+ PRNG -- provides 64-bit pseudo-random values for
  -- random addressing mode.  Stepped once per burst when addr_mode='1'.
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
  p_comb : process(r, arid, burst_length, pace, pace_init, base_addr,
                   addr_range, addr_mode, enable_local,
                   aperture, global_time, ar_ready, sb_tready, stat_rst)
    variable v         : reg_t;
    variable v_enable  : std_logic;
    variable v_bsize   : unsigned(31 downto 0);
    variable v_blen_i  : unsigned(31 downto 0);   -- burst_length after clamping
    variable v_max_blk : unsigned(63 downto 0);   -- max block index (random mode)
    variable v_rand_blk: unsigned(31 downto 0);   -- random block offset
  begin
    v := r;  -- recover current state as default for all fields

    -- Default outputs -- all de-asserted, overridden in specific states

    ar_valid   <= '0';
    ar_id_out  <= arid;
    ar_addr    <= (others => '0');
    ar_len     <= (others => '0');
    ar_size    <= (others => '0');
    ar_burst   <= "00";
    sb_tdata   <= (others => '0');
    sb_tvalid  <= '0';
    prng_step  <= '0';

    -- Statistics are direct register reads -- no pipeline latency
    stat_ar_backpressure <= std_logic_vector(r.ar_bp_cnt);
    stat_sb_backpressure <= std_logic_vector(r.sb_bp_cnt);
    stat_ar_issued       <= std_logic_vector(r.ar_cnt);
    stat_cfg_errors      <= std_logic_vector(r.cfg_err);

    -- Enable:  local enable only (global enable removed -- top-level
    --           wrapper or control logic ORs instances externally).
    v_enable := enable_local;

    -- Stat reset -- clears counters without disrupting state machine
    if stat_rst = '1' then
      v.ar_bp_cnt := (others => '0');
      v.sb_bp_cnt := (others => '0');
      v.ar_cnt    := (others => '0');
      v.cfg_err   := (others => '0');
    end if;

    ------------------------------------------------------------------
    -- Configuration clamping -- evaluated every cycle.
    -- Errors logged only when idle so they don't repeat mid-burst.
    ------------------------------------------------------------------

    -- Clamp burst_length:  0->1, >GC_MAX_BURST->GC_MAX_BURST
    -- GC_MAX_BURST defaults to 256 (AXI4 max).  Set to 16 for AXI3
    -- (the ARLEN field is only 4 bits in AXI3; 256-beat bursts would
    --  alias and corrupt the downstream address decode).
    v_blen_i := unsigned(burst_length);
    if v_blen_i = 0 then
      v_blen_i := to_unsigned(1, 32);
    elsif v_blen_i > GC_MAX_BURST then
      v_blen_i := to_unsigned(GC_MAX_BURST, 32);
      if r.state = S_IDLE then
        v.cfg_err := r.cfg_err + 1;
      end if;
    end if;

    -- 4 KB boundary guard:  AXI4 forbids bursts crossing a 4 KB boundary.
    -- If burst_size > 4 KB, clamp blen and log a config error.
    v_bsize := resize(v_blen_i * GC_DATA_BYTES, 32);
    if v_bsize > to_unsigned(C_4KB, 32) and r.state = S_IDLE then
      v_blen_i := to_unsigned(C_4KB / GC_DATA_BYTES, 32);
      v.cfg_err := r.cfg_err + 1;
    end if;

    ------------------------------------------------------------------
    -- State machine
    ------------------------------------------------------------------
    case r.state is

      -- IDLE:  Wait for enable + aperture.
      --        On entry, reset addr to base_addr, load pace_init.
      when S_IDLE =>
        if v_enable = '1' and aperture = '1' then
          v.pace_cnt := resize(unsigned(pace_init), 32);
          v.first_run := '1';
          v.cur_addr := unsigned(base_addr);
          v.state := S_PACE_WAIT;
        end if;

      -- PACE_WAIT:  Count down pacing delay.  When zero, compute blen
      --             and proceed.  Return to IDLE if enable/aperture drops.
      --
      --             Burst is also clamped to the address window so the
      --             last beat never exceeds base_addr + addr_range - 1.
      when S_PACE_WAIT =>
        if v_enable = '0' or aperture = '0' then
          v.state := S_IDLE;
        elsif r.pace_cnt = 0 then
          -- Clamp burst to the remaining address window
          -- If cur_addr is at or past the end, wrap to base_addr first.
          if r.cur_addr >= unsigned(base_addr) + unsigned(addr_range) then
            v.cur_addr := unsigned(base_addr);
          end if;
          -- Re-evaluate remaining window after potential wrap
          if v_blen_i * GC_DATA_BYTES > unsigned(base_addr) + unsigned(addr_range) - r.cur_addr then
            v_blen_i := resize(
              (unsigned(base_addr) + unsigned(addr_range) - r.cur_addr) / GC_DATA_BYTES, 32);
            if v_blen_i = 0 then
              v_blen_i := to_unsigned(1, 32);
            end if;
          end if;
          v.blen := resize(v_blen_i - 1, 8);
          v.state := S_AR_ISSUE;
        else
          v.pace_cnt := r.pace_cnt - 1;
        end if;

      -- AR_ISSUE:  Drive AR channel.  All bursts use INCR type.
      --            Wait for ar_ready; count backpressure if stalled.
      when S_AR_ISSUE =>
        ar_valid  <= '1';
        ar_addr   <= std_logic_vector(r.cur_addr);
        ar_len    <= std_logic_vector(r.blen);
        ar_id_out <= arid;
        ar_size   <= std_logic_vector(to_unsigned(log2ceil(GC_DATA_BYTES), 3));
        ar_burst  <= "01";  -- INCR

        if ar_ready = '1' then
          v.ar_cnt := r.ar_cnt + 1;
          v.state := S_SB_PUSH;
        else
          v.ar_bp_cnt := r.ar_bp_cnt + 1;
        end if;

      -- SB_PUSH:  Push scoreboard descriptor:  {addr, id, timestamp, blen}.
      --           Advance to next address (linear wrap or random block).
      when S_SB_PUSH =>
        sb_tdata(C_ADDR_HIGH downto C_ADDR_LOW) <=
          std_logic_vector(r.cur_addr);
        sb_tdata(C_ID_HIGH downto C_ID_LOW) <= arid;
        sb_tdata(C_TS_HIGH downto C_TS_LOW) <= global_time;
        sb_tdata(C_BEATS_HIGH downto C_BEATS_LOW) <=
          std_logic_vector(r.blen);
        sb_tvalid <= '1';

        if sb_tready = '1' then
          -- Advance to next address
          if addr_mode = '1' then
            -- Random addressing within window
            prng_step <= '1';
            v_max_blk := resize(unsigned(addr_range) / v_bsize, 64);
            if v_max_blk = 0 then
              v_max_blk := to_unsigned(1, 64);
            end if;
            v_rand_blk := resize(unsigned(prng_data) mod v_max_blk, 32);
            v.cur_addr := unsigned(base_addr)
              + resize(v_rand_blk * v_bsize, GC_ADDR_WIDTH);
          else
            -- Linear sweep with wrap
            if r.cur_addr + resize(v_bsize, GC_ADDR_WIDTH) >=
               unsigned(base_addr) + unsigned(addr_range) then
              v.cur_addr := unsigned(base_addr);
            else
              v.cur_addr := r.cur_addr + resize(v_bsize, GC_ADDR_WIDTH);
            end if;
          end if;

          v.pace_cnt := resize(unsigned(pace), 32);
          v.first_run := '0';
          v.state := S_PACE_WAIT;
        else
          v.sb_bp_cnt := r.sb_bp_cnt + 1;
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
