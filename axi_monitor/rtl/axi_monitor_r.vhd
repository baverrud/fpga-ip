-----------------------------------------------------------------------
--Filename         : axi_monitor_r.vhd
--Description      : Passive AXI4 Read-Data (R) channel monitor with
--                   statistics.  Taps the R channel (r_valid and
--                   r_ready are both inputs -- this block never drives
--                   the bus, so it cannot stall or alter real traffic).
--
--                   Every accepted beat (r_valid & r_ready) is counted
--                   on the cycle it occurs -- there is no backpressure
--                   and no state machine that could drop an event.
--                   The scoreboard only gates *validation* (ID / data /
--                   RLAST / RRESP checks), never *counting*.
--
--                   Data verification is optional (data_check_en): when
--                   disabled, beats are still counted and all protocol
--                   checks still run, but r_data is not compared.
--
--                   Statistics accumulate while the instance is
--                   enabled; every event while enabled is captured.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_monitor_r is
  generic (
    GC_DATA_BYTES : positive := 64;
    GC_ADDR_WIDTH : positive := 49;
    GC_ID_WIDTH   : positive := 6;
    GC_TIME_WIDTH : positive := 48;
    GC_STAT_WIDTH : positive := 48   -- width of accumulated stat ports (min/max/sum)
  );
  port (
    aclk        : in  std_logic;
    aresetn     : in  std_logic;
    global_time : in  unsigned(GC_TIME_WIDTH-1 downto 0);

    -- Control
    enable       : in  std_logic;   -- per-instance enable (0 = monitor inert)
    stat_rst     : in  std_logic;   -- clears stat counters (not burst tracking)
    err_rst      : in  std_logic;   -- clears error counters
    data_check_en: in  std_logic;   -- '1' = verify r_data vs expected pattern
    pipeline_busy: out std_logic;   -- scoreboard has entries or burst in-flight

    -- R channel taps (all inputs -- passive monitor)
    r_valid : in  std_logic;
    r_ready : in  std_logic;
    r_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : in  std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : in  std_logic_vector(1 downto 0);
    r_last  : in  std_logic;

    -- Scoreboard read (from internal axis_fifo)
    sb_tdata  : in  std_logic_vector(GC_ADDR_WIDTH + GC_ID_WIDTH + GC_TIME_WIDTH + 8 - 1 downto 0);
    sb_tvalid : in  std_logic;
    sb_tready : out std_logic;

    -- Statistics
    stat_xactions            : out std_logic_vector(31 downto 0);
    stat_beats               : out std_logic_vector(31 downto 0);
    stat_latency_sum         : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_latency_min         : out std_logic_vector(31 downto 0);
    stat_latency_max         : out std_logic_vector(31 downto 0);
    stat_first_latency_sum   : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_first_latency_min   : out std_logic_vector(31 downto 0);
    stat_first_latency_max   : out std_logic_vector(31 downto 0);
    stat_interbeat_gap_sum   : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_interbeat_gap_min   : out std_logic_vector(31 downto 0);
    stat_interbeat_gap_max   : out std_logic_vector(31 downto 0);
    stat_burst_len_sum       : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_burst_len_min       : out std_logic_vector(31 downto 0);
    stat_burst_len_max       : out std_logic_vector(31 downto 0);
    stat_elapsed_cycles      : out std_logic_vector(31 downto 0);
    stat_r_stall             : out std_logic_vector(31 downto 0);
    stat_data_errors         : out std_logic_vector(31 downto 0);
    stat_id_errors           : out std_logic_vector(31 downto 0);
    stat_rlast_errors        : out std_logic_vector(31 downto 0);
    stat_resp_errors         : out std_logic_vector(31 downto 0);
    stat_sb_underflow_errors : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of axi_monitor_r is

  constant C_SB_WIDTH  : positive := GC_ADDR_WIDTH + GC_ID_WIDTH + GC_TIME_WIDTH + 8;
  constant C_RESP_OKAY : std_logic_vector(1 downto 0) := "00";

  -- Scoreboard field positions -- must match axi_monitor_ar packing order.
  -- Entry format (MSB to LSB):  {araddr, arid, timestamp, arlen}
  constant C_BEATS_LOW  : natural := 0;
  constant C_BEATS_HIGH : natural := 7;
  constant C_TS_LOW     : natural := C_BEATS_HIGH + 1;
  constant C_TS_HIGH    : natural := C_TS_LOW + GC_TIME_WIDTH - 1;
  constant C_ID_LOW     : natural := C_TS_HIGH + 1;
  constant C_ID_HIGH    : natural := C_ID_LOW + GC_ID_WIDTH - 1;
  constant C_ADDR_LOW   : natural := C_ID_HIGH + 1;
  constant C_ADDR_HIGH  : natural := C_ADDR_LOW + GC_ADDR_WIDTH - 1;

  type rec_t is record
    -- Burst tracking -- per-burst state loaded from scoreboard
    burst_beats  : unsigned(7 downto 0);              -- remaining beats (arlen)
    burst_addr   : unsigned(GC_ADDR_WIDTH-1 downto 0);-- start address for data check
    burst_id     : std_logic_vector(GC_ID_WIDTH-1 downto 0);
    beat_idx     : unsigned(8 downto 0);              -- 1-based beat index in burst
    ts_ar        : unsigned(GC_TIME_WIDTH-1 downto 0);-- timestamp at AR issue
    ts_prev_beat : unsigned(GC_TIME_WIDTH-1 downto 0);-- timestamp of previous R beat
    latency_started : std_logic;                      -- '1' = first-beat latency pending

    -- Statistics -- accumulated over the measurement window
    xactions       : unsigned(31 downto 0);  -- completed transactions (bursts)
    beats          : unsigned(31 downto 0);  -- total R beats accepted
    latency_sum    : unsigned(GC_STAT_WIDTH-1 downto 0);
    latency_min    : unsigned(31 downto 0);
    latency_max    : unsigned(31 downto 0);
    first_lat_sum  : unsigned(GC_STAT_WIDTH-1 downto 0);
    first_lat_min  : unsigned(31 downto 0);
    first_lat_max  : unsigned(31 downto 0);
    interbeat_gap_sum : unsigned(GC_STAT_WIDTH-1 downto 0);
    interbeat_gap_min : unsigned(31 downto 0);
    interbeat_gap_max : unsigned(31 downto 0);
    blen_sum       : unsigned(GC_STAT_WIDTH-1 downto 0);  -- observed burst lengths
    blen_min       : unsigned(31 downto 0);
    blen_max       : unsigned(31 downto 0);
    elapsed        : unsigned(31 downto 0);
    r_stall        : unsigned(31 downto 0);   -- r_valid=1 & r_ready=0 cycles
    busy           : std_logic;

    -- Error counters
    data_errs      : unsigned(31 downto 0);
    id_errs        : unsigned(31 downto 0);
    rlast_errs     : unsigned(31 downto 0);
    resp_errs      : unsigned(31 downto 0);
    sb_uf_errs     : unsigned(31 downto 0);
  end record;

  constant C_DEFAULT : rec_t := (
    burst_beats      => (others => '0'),
    burst_addr       => (others => '0'),
    burst_id         => (others => '0'),
    beat_idx         => (others => '0'),
    ts_ar            => (others => '0'),
    ts_prev_beat     => (others => '0'),
    latency_started  => '0',
    xactions         => (others => '0'),
    beats            => (others => '0'),
    latency_sum      => (others => '0'),
    latency_min      => (others => '1'),
    latency_max      => (others => '0'),
    first_lat_sum    => (others => '0'),
    first_lat_min    => (others => '1'),
    first_lat_max    => (others => '0'),
    interbeat_gap_sum => (others => '0'),
    interbeat_gap_min => (others => '1'),
    interbeat_gap_max => (others => '0'),
    blen_sum         => (others => '0'),
    blen_min         => (others => '1'),
    blen_max         => (others => '0'),
    elapsed          => (others => '0'),
    r_stall          => (others => '0'),
    busy             => '0',
    data_errs        => (others => '0'),
    id_errs          => (others => '0'),
    rlast_errs       => (others => '0'),
    resp_errs        => (others => '0'),
    sb_uf_errs       => (others => '0')
  );

  signal r    : rec_t := C_DEFAULT;  -- current state (registered)
  signal r_in : rec_t;               -- next state (combinational output)

begin

  ---------------------------------------------------------------------
  -- R-channel acceptance (passive).
  --
  -- r_ready is an INPUT (tapped from the real consumer); the monitor
  -- never drives it.  An accepted beat is r_valid & r_ready.  Because
  -- the monitor cannot stall, every accepted beat is counted; if no
  -- scoreboard entry is available the beat is still counted and an
  -- underflow error is reported (validation is skipped for it).
  ---------------------------------------------------------------------

  ---------------------------------------------------------------------
  -- Combinational process -- computes all next-state values and outputs.
  ---------------------------------------------------------------------
  p_comb : process(r, r_valid, r_ready, r_id, r_data, r_resp, r_last,
                   sb_tdata, sb_tvalid, global_time, enable,
                   stat_rst, err_rst, data_check_en)
    variable v         : rec_t;
    variable v_r_fire  : std_logic;   -- accepted R-channel beat
    variable v_gap     : unsigned(GC_TIME_WIDTH-1 downto 0);
    variable v_latency : unsigned(GC_TIME_WIDTH-1 downto 0);
    variable v_beat_addr : unsigned(GC_ADDR_WIDTH-1 downto 0);
    variable v_ok      : boolean;
    variable word_idx  : natural;
  begin
    v := r;  -- recover current state as default for all fields

    -- Pipeline busy:  active if scoreboard has entries or a burst is in
    -- progress.  Used to indicate the measurement window is still draining.
    v.busy := '0';
    if enable = '1' and (sb_tvalid = '1' or r.burst_beats > 0) then
      v.busy := '1';
    end if;

    -- Elapsed cycle counter (free-running while enabled).
    if enable = '1' then
      v.elapsed := r.elapsed + 1;
    end if;

    -- R-stall counter:  consumer backpressure on the R channel.
    if enable = '1' and r_valid = '1' and r_ready = '0' then
      v.r_stall := r.r_stall + 1;
    end if;

    -- Accepted beat:  r_valid & r_ready (both inputs), gated by enable.
    v_r_fire := r_valid and r_ready and enable;

    sb_tready <= '0';

    if v_r_fire = '1' then
      -- EVERY accepted beat is counted, unconditionally.
      v.beats := r.beats + 1;

      ------------------------------------------------------------------
      -- RLAST early guard:  r_last with no active burst and no scoreboard
      -- entry ready -> spurious r_last (protocol error).
      ------------------------------------------------------------------
      if r_last = '1' and r.burst_beats = 0 and sb_tvalid = '0' then
        v.rlast_errs := r.rlast_errs + 1;
      end if;

      -- Pop scoreboard entry when starting a new burst (r.burst_beats=0).
      -- If no entry is available, this is a scoreboard underflow:  the
      -- beat is already counted above, but it cannot be validated.
      if r.burst_beats = 0 then
        sb_tready <= '1';
        if sb_tvalid = '0' then
          v.sb_uf_errs := r.sb_uf_errs + 1;
        else
          v.burst_beats := unsigned(sb_tdata(C_BEATS_HIGH downto C_BEATS_LOW));
          v.burst_addr  := unsigned(sb_tdata(C_ADDR_HIGH downto C_ADDR_LOW));
          v.burst_id    := sb_tdata(C_ID_HIGH downto C_ID_LOW);
          v.ts_ar       := unsigned(sb_tdata(C_TS_HIGH downto C_TS_LOW));
          v.beat_idx    := (others => '0');
          v.latency_started := '1';
        end if;
      end if;

      -- Beat processing -- only when a burst is active (either in progress
      -- or just popped this cycle).  Validation is skipped for beats that
      -- arrived with no scoreboard entry (underflow).
      if r.burst_beats > 0 or (r.burst_beats = 0 and sb_tvalid = '1') then
        v.beat_idx := v.beat_idx + 1;

        if r.burst_beats > 0 then
          v.burst_beats := v.burst_beats - 1;
        end if;

        -- Data check (optional):  expected data = burst_start_addr +
        -- (beat_idx-1) x data_bytes.  Only performed when data_check_en.
        if data_check_en = '1' then
          v_beat_addr := v.burst_addr + (v.beat_idx - 1) * GC_DATA_BYTES;
          v_ok := true;
          if GC_DATA_BYTES >= 4 then
            for word_idx in 0 to GC_DATA_BYTES / 4 - 1 loop
              if r_data(32*word_idx+31 downto 32*word_idx) /=
                 std_logic_vector(resize(v_beat_addr + word_idx*4, 32)) then
                v_ok := false;
              end if;
            end loop;
          elsif GC_DATA_BYTES = 2 then
            v_ok := r_data(15 downto 0) = std_logic_vector(
              resize(v_beat_addr, 16));
          else
            v_ok := r_data(7 downto 0) = std_logic_vector(
              resize(v_beat_addr, 8));
          end if;
          if not v_ok then
            v.data_errs := r.data_errs + 1;
          end if;
        end if;

        -- ID check:  RID must match the AR ID from the scoreboard entry
        if r_id /= v.burst_id then
          v.id_errs := r.id_errs + 1;
        end if;

        -- RLAST checks (per-beat, using v.burst_beats = after-decrement).
        if r_last = '1' and v.burst_beats > 0 then
          v.rlast_errs := r.rlast_errs + 1;
        end if;
        if r_last = '0' and v.burst_beats = 0 then
          v.rlast_errs := r.rlast_errs + 1;
        end if;

        -- RRESP check:  all responses should be OKAY (0b00)
        if r_resp /= C_RESP_OKAY then
          v.resp_errs := r.resp_errs + 1;
        end if;

        ------------------------------------------------------------------
        -- Statistics accumulation -- enabled while the monitor is on.
        ------------------------------------------------------------------
        if v.burst_beats = 0 then
          v_latency := global_time - v.ts_ar;
          v.latency_sum := r.latency_sum + v_latency;
          if v_latency < r.latency_min then
            v.latency_min := v_latency(31 downto 0);
          end if;
          if v_latency > r.latency_max then
            v.latency_max := v_latency(31 downto 0);
          end if;
        end if;

        v_gap := global_time - r.ts_prev_beat;
        if v.beat_idx > 1 then
          v.interbeat_gap_sum := r.interbeat_gap_sum + v_gap;
          if v_gap < r.interbeat_gap_min then
            v.interbeat_gap_min := v_gap(31 downto 0);
          end if;
          if v_gap > r.interbeat_gap_max then
            v.interbeat_gap_max := v_gap(31 downto 0);
          end if;
        end if;

        if v.beat_idx = 1 and v.latency_started = '1' then
          v_latency := global_time - v.ts_ar;
          v.first_lat_sum := r.first_lat_sum + v_latency;
          if v_latency < r.first_lat_min then
            v.first_lat_min := v_latency(31 downto 0);
          end if;
          if v_latency > r.first_lat_max then
            v.first_lat_max := v_latency(31 downto 0);
          end if;
        end if;

        v.ts_prev_beat := global_time;

        -- Transaction completed -- clear burst state and record length.
        if v.burst_beats = 0 then
          v.latency_started := '0';
          v.xactions := r.xactions + 1;
          v.blen_sum := r.blen_sum + resize(v.beat_idx, GC_STAT_WIDTH);
          if v.beat_idx < r.blen_min then
            v.blen_min := resize(v.beat_idx, 32);
          end if;
          if v.beat_idx > r.blen_max then
            v.blen_max := resize(v.beat_idx, 32);
          end if;
        end if;
      end if;
    end if;

    ------------------------------------------------------------------
    -- Soft-reset overrides -- take priority over the next-state logic.
    -- stat_rst clears the stat fields; err_rst clears the error
    -- counters.  Burst-tracking fields are intentionally untouched.
    -- Reset values are single-sourced from C_DEFAULT.
    ------------------------------------------------------------------
    if stat_rst = '1' then
      v.xactions       := C_DEFAULT.xactions;
      v.beats          := C_DEFAULT.beats;
      v.latency_sum    := C_DEFAULT.latency_sum;
      v.latency_min    := C_DEFAULT.latency_min;
      v.latency_max    := C_DEFAULT.latency_max;
      v.first_lat_sum  := C_DEFAULT.first_lat_sum;
      v.first_lat_min  := C_DEFAULT.first_lat_min;
      v.first_lat_max  := C_DEFAULT.first_lat_max;
      v.interbeat_gap_sum := C_DEFAULT.interbeat_gap_sum;
      v.interbeat_gap_min := C_DEFAULT.interbeat_gap_min;
      v.interbeat_gap_max := C_DEFAULT.interbeat_gap_max;
      v.blen_sum       := C_DEFAULT.blen_sum;
      v.blen_min       := C_DEFAULT.blen_min;
      v.blen_max       := C_DEFAULT.blen_max;
      v.elapsed        := C_DEFAULT.elapsed;
      v.r_stall        := C_DEFAULT.r_stall;
    end if;
    if err_rst = '1' then
      v.data_errs      := C_DEFAULT.data_errs;
      v.id_errs        := C_DEFAULT.id_errs;
      v.rlast_errs     := C_DEFAULT.rlast_errs;
      v.resp_errs      := C_DEFAULT.resp_errs;
      v.sb_uf_errs     := C_DEFAULT.sb_uf_errs;
    end if;

    r_in <= v;  -- latch next state
  end process p_comb;

  ---------------------------------------------------------------------
  -- Register process -- updates state on rising clock edge.
  ---------------------------------------------------------------------
  p_reg : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        r <= C_DEFAULT;
      else
        r <= r_in;
      end if;
    end if;
  end process p_reg;

  -- Stat output assignments -- direct reads from registered state.
  stat_xactions           <= std_logic_vector(r.xactions);
  stat_beats              <= std_logic_vector(r.beats);
  stat_latency_sum        <= std_logic_vector(r.latency_sum);
  stat_latency_min        <= std_logic_vector(r.latency_min);
  stat_latency_max        <= std_logic_vector(r.latency_max);
  stat_first_latency_sum  <= std_logic_vector(r.first_lat_sum);
  stat_first_latency_min  <= std_logic_vector(r.first_lat_min);
  stat_first_latency_max  <= std_logic_vector(r.first_lat_max);
  stat_interbeat_gap_sum  <= std_logic_vector(r.interbeat_gap_sum);
  stat_interbeat_gap_min  <= std_logic_vector(r.interbeat_gap_min);
  stat_interbeat_gap_max  <= std_logic_vector(r.interbeat_gap_max);
  stat_burst_len_sum      <= std_logic_vector(r.blen_sum);
  stat_burst_len_min      <= std_logic_vector(r.blen_min);
  stat_burst_len_max      <= std_logic_vector(r.blen_max);
  stat_elapsed_cycles     <= std_logic_vector(r.elapsed);
  stat_r_stall            <= std_logic_vector(r.r_stall);
  pipeline_busy           <= r.busy;
  stat_data_errors        <= std_logic_vector(r.data_errs);
  stat_id_errors          <= std_logic_vector(r.id_errs);
  stat_rlast_errors       <= std_logic_vector(r.rlast_errs);
  stat_resp_errors        <= std_logic_vector(r.resp_errs);
  stat_sb_underflow_errors <= std_logic_vector(r.sb_uf_errs);

end architecture;
