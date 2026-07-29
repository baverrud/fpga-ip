-----------------------------------------------------------------------
--Filename         : axi_read_tester_r_mon.vhd
--Description      : AXI4 Read Data Monitor with statistics.
--                 : Captures R beats, pops per-burst scoreboard
--                 : entries, verifies data/ID/RLAST/RRESP, and
--                 : accumulates latency / throughput statistics.
--                 : Statistics are gated on aperture but in-flight
--                 : beats are counted via the scoreboard valid flag.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_tester_r_mon is
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
    global_time : in  std_logic_vector(GC_TIME_WIDTH-1 downto 0);
    aperture    : in  std_logic;

    stat_rst : in  std_logic;
    err_rst  : in  std_logic;

    r_valid : in  std_logic;
    r_ready : out std_logic;
    r_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : in  std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : in  std_logic_vector(1 downto 0);
    r_last  : in  std_logic;

    sb_tdata  : in  std_logic_vector(GC_ADDR_WIDTH + GC_ID_WIDTH + GC_TIME_WIDTH + 8 - 1 downto 0);
    sb_tvalid : in  std_logic;
    sb_tready : out std_logic;

    stat_xactions           : out std_logic_vector(31 downto 0);
    stat_beats              : out std_logic_vector(31 downto 0);
    stat_latency_sum        : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_latency_min        : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_latency_max        : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_first_latency_sum  : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_first_latency_min  : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_first_latency_max  : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_interbeat_gap_sum  : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_elapsed_cycles     : out std_logic_vector(31 downto 0);
    stat_pipeline_busy      : out std_logic;
    stat_data_errors        : out std_logic_vector(31 downto 0);
    stat_id_errors          : out std_logic_vector(31 downto 0);
    stat_rlast_errors       : out std_logic_vector(31 downto 0);
    stat_resp_errors        : out std_logic_vector(31 downto 0);
    stat_sb_underflow_errors : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of axi_read_tester_r_mon is

  constant C_SB_WIDTH   : positive := GC_ADDR_WIDTH + GC_ID_WIDTH + GC_TIME_WIDTH + 8;
  constant C_RESP_OKAY  : std_logic_vector(1 downto 0) := "00";

  -- Scoreboard field positions — must match AR gen packing order.
  -- Entry format (MSB to LSB):  {araddr, arid, timestamp, blen}
  constant C_BEATS_LOW  : natural := 0;
  constant C_BEATS_HIGH : natural := 7;
  constant C_TS_LOW     : natural := C_BEATS_HIGH + 1;
  constant C_TS_HIGH    : natural := C_TS_LOW + GC_TIME_WIDTH - 1;
  constant C_ID_LOW     : natural := C_TS_HIGH + 1;
  constant C_ID_HIGH    : natural := C_ID_LOW + GC_ID_WIDTH - 1;
  constant C_ADDR_LOW   : natural := C_ID_HIGH + 1;
  constant C_ADDR_HIGH  : natural := C_ADDR_LOW + GC_ADDR_WIDTH - 1;

  type rec_t is record
    -- Burst tracking — per-burst state loaded from scoreboard
    burst_beats  : unsigned(7 downto 0);              -- remaining beats (arlen)
    burst_addr   : unsigned(GC_ADDR_WIDTH-1 downto 0);-- start address for data check
    burst_id     : std_logic_vector(GC_ID_WIDTH-1 downto 0);
    beat_idx     : unsigned(7 downto 0);              -- 1-based beat index in burst
    ts_ar        : unsigned(GC_TIME_WIDTH-1 downto 0);-- timestamp at AR issue
    ts_prev_beat : unsigned(GC_TIME_WIDTH-1 downto 0);-- timestamp of previous R beat
    latency_started : std_logic;                      -- '1' = first-beat latency pending

    -- Statistics — accumulated over the measurement window
    xactions       : unsigned(31 downto 0);  -- completed transactions (bursts)
    beats          : unsigned(31 downto 0);  -- total R beats processed
    latency_sum    : unsigned(GC_STAT_WIDTH-1 downto 0);  -- sum of all latencies
    latency_min    : unsigned(GC_STAT_WIDTH-1 downto 0);  -- minimum latency observed
    latency_max    : unsigned(GC_STAT_WIDTH-1 downto 0);  -- maximum latency observed
    first_lat_sum  : unsigned(GC_STAT_WIDTH-1 downto 0);  -- sum of first-beat latencies
    first_lat_min  : unsigned(GC_STAT_WIDTH-1 downto 0);
    first_lat_max  : unsigned(GC_STAT_WIDTH-1 downto 0);
    ib_gap_sum     : unsigned(GC_STAT_WIDTH-1 downto 0);  -- sum of inter-beat gaps
    elapsed        : unsigned(31 downto 0);  -- elapsed clock cycles
    busy           : std_logic;              -- '1' = pipeline has in-flight work

    -- Error counters
    data_errs      : unsigned(31 downto 0);  -- data mismatch errors
    id_errs        : unsigned(31 downto 0);  -- RID mismatch errors
    rlast_errs     : unsigned(31 downto 0);  -- RLAST protocol errors
    resp_errs      : unsigned(31 downto 0);  -- RRESP ≠ OKAY errors
    sb_uf_errs     : unsigned(31 downto 0);  -- scoreboard underflow (beat without entry)
  end record;

  constant C_DEFAULT : rec_t := (
    -- Burst tracking
    burst_beats      => (others => '0'),
    burst_addr       => (others => '0'),
    burst_id         => (others => '0'),
    beat_idx         => (others => '0'),
    ts_ar            => (others => '0'),
    ts_prev_beat     => (others => '0'),
    latency_started  => '0',
    -- Statistics
    xactions         => (others => '0'),
    beats            => (others => '0'),
    latency_sum      => (others => '0'),
    latency_min      => (others => '1'),
    latency_max      => (others => '0'),
    first_lat_sum    => (others => '0'),
    first_lat_min    => (others => '1'),
    first_lat_max    => (others => '0'),
    ib_gap_sum       => (others => '0'),
    elapsed          => (others => '0'),
    busy             => '0',
    -- Error counters
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
  -- R-channel backpressure.
  --
  -- When a new R beat arrives but we have no active burst and no
  -- scoreboard entry ready, we MUST stall the upstream producer.
  -- r_ready is de-asserted until the scoreboard entry arrives.
  --
  -- This is the correct AXI-Stream pattern:  use combinational
  -- backpressure, not cycle counting.  It is timing-robust and
  -- works regardless of FIFO latency or clock frequency.
  ---------------------------------------------------------------------
  r_ready <= '0' when (r.burst_beats = 0 and sb_tvalid = '0' and r_valid = '1') else '1';

  ---------------------------------------------------------------------
  -- Combinational process — computes all next-state values and outputs.
  ---------------------------------------------------------------------
  p_comb : process(r, r_valid, r_id, r_data, r_resp, r_last,
                   sb_tdata, sb_tvalid, aperture, global_time,
                   stat_rst, err_rst)
    variable v         : rec_t;
    variable v_gate    : std_logic;           -- stats gating flag
    variable v_r_fire  : std_logic;           -- accepted R-channel beat
    variable v_gap     : unsigned(GC_TIME_WIDTH-1 downto 0);
    variable v_latency : unsigned(GC_TIME_WIDTH-1 downto 0);
    variable v_beat_addr : unsigned(GC_ADDR_WIDTH-1 downto 0);  -- expected addr
    variable v_ok      : boolean;
  begin
    v := r;  -- recover current state as default for all fields

    -- Stat/error reset — clears counters without disrupting burst progress
    if stat_rst = '1' then
      v.xactions      := (others => '0');
      v.beats         := (others => '0');
      v.latency_sum   := (others => '0');
      v.latency_min   := (others => '1');
      v.latency_max   := (others => '0');
      v.first_lat_sum := (others => '0');
      v.first_lat_min := (others => '1');
      v.first_lat_max := (others => '0');
      v.ib_gap_sum    := (others => '0');
      v.elapsed       := (others => '0');
    end if;
    if err_rst = '1' then
      v.data_errs     := (others => '0');
      v.id_errs       := (others => '0');
      v.rlast_errs    := (others => '0');
      v.resp_errs     := (others => '0');
      v.sb_uf_errs    := (others => '0');
    end if;

    -- Pipeline busy flag:  active if scoreboard has entries or a burst
    -- is in progress.  Used to extend the gating window past aperture de-assert.
    v.elapsed := r.elapsed + 1;
    v.busy := '0';
    if sb_tvalid = '1' or r.burst_beats > 0 then
      v.busy := '1';
    end if;

    -- Gating:  count stats when aperture is high OR when pipeline has
    -- in-flight work (so we don't clip stats for bursts that started
    -- before aperture dropped).
    v_gate := aperture or r.busy;
    v_r_fire := '0';
    if r_valid = '1' and not (r.burst_beats = 0 and sb_tvalid = '0') then
      v_r_fire := '1';
    end if;

    sb_tready <= '0';

    ------------------------------------------------------------------
    -- R beat processing — only on accepted AXI handshakes.
    --
    -- A transfer is accepted when r_valid and r_ready are both '1'.
    -- Here, r_ready de-asserts only for "need scoreboard entry first",
    -- so v_r_fire encodes "accepted beat" directly.
    ------------------------------------------------------------------
    if v_r_fire = '1' then

      ------------------------------------------------------------------
      -- RLAST check (early guard).
      --
      -- Two RLAST checks exist in this module:
      --   1.  HERE (line ~198):  r_last='1' with no active burst AND
      --       no scoreboard entry ready → spurious r_last (error).
      --       Must check sb_tvalid to avoid false positives for
      --       single-beat bursts where r.burst_beats=0 is correct.
      --   2.  Inside processing block (line ~240):  per-beat RLAST
      --       validation against the current burst's remaining count.
      ------------------------------------------------------------------
      if r_last = '1' and r.burst_beats = 0 and sb_tvalid = '0' then
        v.rlast_errs := r.rlast_errs + 1;
      end if;

      -- Pop scoreboard entry when starting a new burst (r.burst_beats=0).
      -- sb_tready asserts to consume the FIFO entry.
      -- If no entry is available (sb_tvalid='0'), it's a scoreboard underflow.
      if r.burst_beats = 0 then
        sb_tready <= '1';
        if sb_tvalid = '0' then
          v.sb_uf_errs := r.sb_uf_errs + 1;
        else
          -- Load burst descriptor from scoreboard
          v.burst_beats := unsigned(sb_tdata(C_BEATS_HIGH downto C_BEATS_LOW));
          v.burst_addr  := unsigned(sb_tdata(C_ADDR_HIGH downto C_ADDR_LOW));
          v.burst_id    := sb_tdata(C_ID_HIGH downto C_ID_LOW);
          v.ts_ar       := unsigned(sb_tdata(C_TS_HIGH downto C_TS_LOW));
          v.beat_idx    := (others => '0');
          v.latency_started := '1';
        end if;
      end if;

      ------------------------------------------------------------------
      -- Beat processing — active if we have a burst in progress
      -- (r.burst_beats>0) or just popped a new entry (r.burst_beats=0
      -- and sb_tvalid='1' from this same cycle).
      --
      -- NOTE:  r.burst_beats uses the REGISTERED value (before pop),
      --        v.burst_beats uses the NEXT-STATE value (after pop).
      ------------------------------------------------------------------
      if r.burst_beats > 0 or (r.burst_beats = 0 and sb_tvalid = '1') then
        v.beats := v.beats + 1;
        v.beat_idx := v.beat_idx + 1;

        -- Decrement remaining beats — but NOT on the pop cycle
        -- (the pop cycle loaded the entry, we haven't consumed a beat yet).
        -- Only decrement when we had an active burst coming into this cycle.
        if r.burst_beats > 0 then
          v.burst_beats := v.burst_beats - 1;
        end if;

        -- Data check:  the memory model returns address-derived patterns.
        -- Expected data = burst_start_addr + (beat_idx-1) × data_bytes.
        v_beat_addr := v.burst_addr + (v.beat_idx - 1) * GC_DATA_BYTES;
        if GC_DATA_BYTES >= 4 then
          v_ok := r_data(31 downto 0) = std_logic_vector(
            resize(v_beat_addr, 32));
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

        -- ID check:  RID must match the AR ID from the scoreboard entry
        if r_id /= v.burst_id then
          v.id_errs := r.id_errs + 1;
        end if;

        ------------------------------------------------------------------
        -- RLAST checks (per-beat, using v.burst_beats = after-decrement).
        --
        -- RLAST_EARLY:  r_last asserted but more beats expected.
        --   v.burst_beats > 0  →  burst not yet finished, r_last came early.
        -- RLAST_MISS:   r_last NOT asserted but this was the last beat.
        --   v.burst_beats = 0  →  all beats consumed, r_last should be '1'.
        --
        -- For single-beat bursts (blen=0):  v.burst_beats stays 0 from
        -- the pop, r_last='1' expected.  Neither condition fires.  ✓
        ------------------------------------------------------------------
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
        -- Statistics accumulation — gated by aperture.
        --
        -- Latency:  measured as global_time difference between AR issue
        -- (timestamp from scoreboard) and the LAST R beat of the burst.
        -- Accumulated once per transaction (burst).
        --
        -- First-beat latency:  measured separately for the first beat.
        --
        -- Inter-beat gap:  time between consecutive R beats within a burst.
        -- Only counted for beats after the first (beat_idx > 1).
        ------------------------------------------------------------------
        if v_gate = '1' then
          if v.burst_beats = 0 then
            v_latency := unsigned(global_time) - v.ts_ar;
            v.latency_sum := r.latency_sum + v_latency;

            if v_latency < r.latency_min then
              v.latency_min := v_latency;
            end if;
            if v_latency > r.latency_max then
              v.latency_max := v_latency;
            end if;
          end if;

          v_gap := unsigned(global_time) - r.ts_prev_beat;
          if v.beat_idx > 1 then
            v.ib_gap_sum := r.ib_gap_sum + v_gap;
          end if;

          if v.beat_idx = 1 and v.latency_started = '1' then
            v_latency := unsigned(global_time) - v.ts_ar;
            v.first_lat_sum := r.first_lat_sum + v_latency;

            if v_latency < r.first_lat_min then
              v.first_lat_min := v_latency;
            end if;
            if v_latency > r.first_lat_max then
              v.first_lat_max := v_latency;
            end if;
          end if;
        end if;

        v.ts_prev_beat := unsigned(global_time);

        -- Transaction completed — count it and clear latency flag
        if v.burst_beats = 0 then
          v.xactions := r.xactions + 1;
          v.latency_started := '0';
        end if;
      end if;
    end if;

    r_in <= v;  -- latch next state
  end process p_comb;

  ---------------------------------------------------------------------
  -- Register process — updates state on rising clock edge.
  -- Synchronous reset (active-low) restores defaults.
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

  -- Stat output assignments — direct reads from registered state.
  -- No pipeline latency; these update on the clock edge after the
  -- event occurs.
  stat_xactions           <= std_logic_vector(r.xactions);
  stat_beats              <= std_logic_vector(r.beats);
  stat_latency_sum        <= std_logic_vector(r.latency_sum);
  stat_latency_min        <= std_logic_vector(r.latency_min);
  stat_latency_max        <= std_logic_vector(r.latency_max);
  stat_first_latency_sum  <= std_logic_vector(r.first_lat_sum);
  stat_first_latency_min  <= std_logic_vector(r.first_lat_min);
  stat_first_latency_max  <= std_logic_vector(r.first_lat_max);
  stat_interbeat_gap_sum  <= std_logic_vector(r.ib_gap_sum);
  stat_elapsed_cycles     <= std_logic_vector(r.elapsed);
  stat_pipeline_busy      <= r.busy;
  stat_data_errors        <= std_logic_vector(r.data_errs);
  stat_id_errors          <= std_logic_vector(r.id_errs);
  stat_rlast_errors       <= std_logic_vector(r.rlast_errs);
  stat_resp_errors        <= std_logic_vector(r.resp_errs);
  stat_sb_underflow_errors <= std_logic_vector(r.sb_uf_errs);

end architecture;
