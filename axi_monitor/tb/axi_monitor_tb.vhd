-----------------------------------------------------------------------
--Filename         : axi_monitor_tb.vhd
--Description      : Testbench for axi_monitor (passive AR/R monitor).
--
--                   Architecture:
--                     axi_ar_gen             -- generates AR traffic
--                     axi_mem_model          -- responds with R beats
--                     axi_monitor            -- taps AR + R between them
--
--                   The monitor is fully passive: it never drives
--                   ar_valid/ar_ready/r_valid/r_ready.  The TB acts as
--                   the R-channel consumer (drives r_ready), and the
--                   ar_gen drives the AR channel into the mem_model.
--
--                   Checks:  normal linear/random/paced traffic,
--                   one-beat and non-zero pace_init operation, AR format
--                   and address-window/alignment compliance, R backpressure,
--                   per-instance enable gating, disabled data checking,
--                   injected data/ID/RRESP/RLAST errors, stat_rst, and
--                   err_rst behavior.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity axi_monitor_tb is
end entity;

architecture sim of axi_monitor_tb is

  constant C_CLK_PERIOD : time    := 10 ns;
  constant C_DATA_BYTES : natural := 16;
  constant C_ADDR_WIDTH : natural := 49;
  constant C_ID_WIDTH   : natural := 6;
  constant C_TIME_WIDTH : natural := 48;
  constant C_STAT_WIDTH : natural := 48;

  signal aclk     : std_logic := '0';
  signal aresetn  : std_logic := '0';
  signal sim_done : boolean  := false;

  signal global_time   : unsigned(C_TIME_WIDTH-1 downto 0) := (others => '0');
  signal mon_enable    : std_logic := '1';   -- monitor per-instance enable (kept high)
  signal aperture      : std_logic := '0';
  signal stat_rst      : std_logic := '0';
  signal err_rst       : std_logic := '0';
  signal data_check_en : std_logic := '1';

  -- Traffic source (ar_gen) config
  signal enable          : std_logic := '0';
  signal gen_aperture    : std_logic := '1';
  signal arid            : std_logic_vector(C_ID_WIDTH-1 downto 0) := (others => '0');
  signal ar_length      : std_logic_vector(log2ceil(256)-1 downto 0) := x"0F";
  signal pace            : std_logic_vector(31 downto 0) := x"00000000";
  signal pace_init       : std_logic_vector(31 downto 0) := x"00000000";
  signal base_addr       : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := std_logic_vector(to_unsigned(16#1000#, C_ADDR_WIDTH));
  signal addr_range      : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := std_logic_vector(to_unsigned(16#10000#, C_ADDR_WIDTH));
  signal addr_mode       : std_logic := '0';

  -- AR channel (gen drives, mem accepts, monitor taps)
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;
  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);
  signal ar_size  : std_logic_vector(2 downto 0);
  signal ar_burst : std_logic_vector(1 downto 0);

  -- R channel (mem drives, TB consumes via r_ready, monitor taps)
  signal r_valid : std_logic;
  signal r_ready : std_logic := '1';   -- TB acts as R consumer
  signal r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data  : std_logic_vector(8*C_DATA_BYTES-1 downto 0);
  signal r_resp  : std_logic_vector(1 downto 0);
  signal r_last  : std_logic;

  -- Raw memory-model R channel and optional error injection before the
  -- monitor tap.  The normal path is transparent; each injection is
  -- enabled only during the dedicated error tests.
  signal mem_r_valid : std_logic;
  signal mem_r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal mem_r_data  : std_logic_vector(8*C_DATA_BYTES-1 downto 0);
  signal mem_r_resp  : std_logic_vector(1 downto 0);
  signal mem_r_last  : std_logic;
  signal inject_data_error  : std_logic := '0';
  signal inject_id_error    : std_logic := '0';
  signal inject_resp_error  : std_logic := '0';
  signal inject_rlast_error : std_logic := '0';
  signal spurious_r_valid   : std_logic := '0';  -- R beat with no AR descriptor

  signal check_ar_corner_cases : std_logic := '0';

  -- Small-FIFO monitor instance used to drive scoreboard backpressure.
  signal bp_stat_ar_seen         : std_logic_vector(31 downto 0);
  signal bp_stat_ar_stall        : std_logic_vector(31 downto 0);
  signal bp_stat_sb_backpressure : std_logic_vector(31 downto 0);

  -- Memory model control
  signal ar_base_enable   : std_logic := '1';
  signal ar_jitter_enable : std_logic := '0';
  signal r_base_enable    : std_logic := '1';
  signal r_jitter_enable  : std_logic := '0';
  signal base_latency     : std_logic_vector(15 downto 0) := x"0005";
  signal base_beat_gap    : std_logic_vector(15 downto 0) := x"0003";

  -- Monitor statistics
  signal stat_ar_seen             : std_logic_vector(31 downto 0);
  signal stat_ar_stall            : std_logic_vector(31 downto 0);
  signal stat_sb_backpressure     : std_logic_vector(31 downto 0);
  signal stat_xactions            : std_logic_vector(31 downto 0);
  signal stat_beats               : std_logic_vector(31 downto 0);
  signal stat_latency_sum         : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_latency_min         : std_logic_vector(31 downto 0);
  signal stat_latency_max         : std_logic_vector(31 downto 0);
  signal stat_first_latency_sum   : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_first_latency_min   : std_logic_vector(31 downto 0);
  signal stat_first_latency_max   : std_logic_vector(31 downto 0);
  signal stat_interbeat_gap_sum   : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_interbeat_gap_min   : std_logic_vector(31 downto 0);
  signal stat_interbeat_gap_max   : std_logic_vector(31 downto 0);
  signal stat_burst_len_sum       : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_burst_len_min       : std_logic_vector(31 downto 0);
  signal stat_burst_len_max       : std_logic_vector(31 downto 0);
  signal stat_elapsed_cycles      : std_logic_vector(31 downto 0);
  signal stat_r_stall             : std_logic_vector(31 downto 0);
  signal pipeline_busy            : std_logic;
  signal stat_max_outstanding     : std_logic_vector(31 downto 0);
  signal stat_data_errors         : std_logic_vector(31 downto 0);
  signal stat_id_errors           : std_logic_vector(31 downto 0);
  signal stat_rlast_errors        : std_logic_vector(31 downto 0);
  signal stat_resp_errors         : std_logic_vector(31 downto 0);
  signal stat_sb_underflow_errors : std_logic_vector(31 downto 0);

  -- Generator stats (for cross-checking ar_seen vs ar_issued).  The
  -- gen_ prefix disambiguates from the monitor's same-named ports
  -- (both axi_ar_gen and axi_monitor export stat_ar_stall).
  signal gen_stat_ar_stall    : std_logic_vector(31 downto 0);
  signal gen_stat_ar_issued   : std_logic_vector(31 downto 0);
  signal gen_stat_cfg_errors  : std_logic_vector(31 downto 0);

  -- Global time counter
  signal global_time_cnt : unsigned(C_TIME_WIDTH-1 downto 0) := (others => '0');

  procedure wait_cycles(n : natural) is
  begin
    for i in 1 to n loop
      wait until rising_edge(aclk);
    end loop;
  end procedure;

  -- Wait until the R channel has completed all AR transactions accepted
  -- by the monitor (i.e. stat_xactions has caught up with stat_ar_seen),
  -- or max_cycles has elapsed.  Needed because the axi_mem_model drains
  -- bursts with several cycles of latency; fixed drain windows are not
  -- robust to that.
  procedure wait_drained(max_cycles : natural) is
    variable n : natural := 0;
  begin
    while unsigned(stat_xactions) < unsigned(stat_ar_seen) and n < max_cycles loop
      wait until rising_edge(aclk);
      n := n + 1;
    end loop;
  end procedure;

begin

  -- Clock
  aclk <= not aclk after C_CLK_PERIOD/2 when not sim_done else '0';

  -- Global time counter (free-running)
  p_gt : process
  begin
    wait until rising_edge(aclk);
    if aresetn = '0' then
      global_time_cnt <= (others => '0');
    else
      global_time_cnt <= global_time_cnt + 1;
    end if;
  end process;
  global_time <= global_time_cnt;

  -- Preserve the memory response by default, with deliberate corruption
  -- available for the monitor error-counter tests.  spurious_r_valid
  -- injects an R beat with no matching AR descriptor (scoreboard
  -- underflow).
  r_valid <= mem_r_valid or spurious_r_valid;
  r_id    <= mem_r_id when inject_id_error = '0' else not mem_r_id;
  r_data  <= mem_r_data when inject_data_error = '0' else not mem_r_data;
  r_resp  <= mem_r_resp when inject_resp_error = '0' else "10";
  r_last  <= mem_r_last xor inject_rlast_error;

  -- Check the externally visible AR encoding and the generator's claimed
  -- address-window protection and alignment on every accepted AR.
  p_ar_corner_checks : process(aclk)
    variable burst_bytes : natural;
  begin
    if rising_edge(aclk) and aresetn = '1' and
       check_ar_corner_cases = '1' and ar_valid = '1' and ar_ready = '1' then
      assert ar_size = std_logic_vector(to_unsigned(log2ceil(C_DATA_BYTES), 3))
        report "AR corner check: ar_size mismatch"
        severity failure;
      assert ar_burst = "01"
        report "AR corner check: ar_burst is not INCR"
        severity failure;

      -- Every start must be aligned to the transfer size (C_DATA_BYTES).
      assert unsigned(ar_addr(log2ceil(C_DATA_BYTES)-1 downto 0)) = 0
        report "AR corner check: ar_addr not aligned to C_DATA_BYTES"
        severity failure;

      burst_bytes := (to_integer(unsigned(ar_len)) + 1) * C_DATA_BYTES;
      assert unsigned(ar_addr) >= unsigned(base_addr) and
             unsigned(ar_addr) + burst_bytes <=
             unsigned(base_addr) + unsigned(addr_range)
        report "AR corner check: burst outside configured address window"
        severity failure;
    end if;
  end process;

  ---------------------------------------------------------------------
  -- Traffic source:  axi_ar_gen
  -- Generates AR bursts at pace=0 (a new AR every clock cycle when the
  -- mem_model accepts).  It has no scoreboard of its own -- the monitor
  -- builds its own scoreboard from the tapped AR.
  ---------------------------------------------------------------------
  u_gen : entity work.axi_ar_gen
    generic map (
      GC_DATA_BYTES => C_DATA_BYTES,
      GC_ADDR_WIDTH => C_ADDR_WIDTH,
      GC_ID_WIDTH   => C_ID_WIDTH,
      GC_MAX_BURST  => 256
    )
    port map (
      aclk        => aclk,
      aresetn     => aresetn,
      enable      => enable,
      aperture    => gen_aperture,
      stat_rst    => stat_rst,
      arid        => arid,
      ar_length   => ar_length,
      pace        => pace,
      pace_init   => pace_init,
      base_addr   => base_addr,
      addr_range  => addr_range,
      addr_mode   => addr_mode,
      ar_valid    => ar_valid,
      ar_ready    => ar_ready,
      ar_id       => ar_id,
      ar_addr     => ar_addr,
      ar_len      => ar_len,
      ar_size     => ar_size,
      ar_burst    => ar_burst,
      stat_ar_stall   => gen_stat_ar_stall,
      stat_ar_issued  => gen_stat_ar_issued,
      stat_cfg_errors => gen_stat_cfg_errors
    );

  ---------------------------------------------------------------------
  -- Responding slave:  axi_mem_model
  ---------------------------------------------------------------------
  u_mem : entity work.axi_mem_model
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_AR_FIFO_DEPTH => 256,
      GC_TIMER_WIDTH   => 16,
      GC_R_FIFO_DEPTH  => 8
    )
    port map (
      aclk             => aclk,
      aresetn          => aresetn,
      ar_base_enable   => ar_base_enable,
      ar_jitter_enable => ar_jitter_enable,
      r_base_enable    => r_base_enable,
      r_jitter_enable  => r_jitter_enable,
      base_latency     => base_latency,
      base_beat_gap    => base_beat_gap,
      ar_id            => ar_id,
      ar_addr          => ar_addr,
      ar_len           => ar_len,
      ar_valid         => ar_valid,
      ar_ready         => ar_ready,
      r_id             => mem_r_id,
      r_data           => mem_r_data,
      r_resp           => mem_r_resp,
      r_last           => mem_r_last,
      r_valid          => mem_r_valid,
      r_ready          => r_ready
    );

  ---------------------------------------------------------------------
  -- DUT:  axi_monitor -- passive tap between generator and memory model
  ---------------------------------------------------------------------
  u_monitor : entity work.axi_monitor
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_TIME_WIDTH    => C_TIME_WIDTH,
      GC_STAT_WIDTH    => C_STAT_WIDTH,
      -- The generator can accept ARs much faster than the mem_model drains
      -- (mem latency 5 + gap 3, 16-beat bursts), so peak outstanding can
      -- far exceed 256.  Use a deep scoreboard so descriptors are never
      -- dropped; stat_sb_backpressure still tracks any saturation.
      GC_SB_FIFO_DEPTH => 4096
    )
    port map (
      aclk                    => aclk,
      aresetn                 => aresetn,
      global_time             => global_time,
      enable                  => mon_enable,
      aperture                => aperture,
      stat_rst                => stat_rst,
      err_rst                 => err_rst,
      data_check_en           => data_check_en,
      ar_valid                => ar_valid,
      ar_ready                => ar_ready,
      ar_id                   => ar_id,
      ar_addr                 => ar_addr,
      ar_len                  => ar_len,
      r_valid                 => r_valid,
      r_ready                 => r_ready,
      r_id                    => r_id,
      r_data                  => r_data,
      r_resp                  => r_resp,
      r_last                  => r_last,
      stat_ar_seen            => stat_ar_seen,
      stat_ar_stall           => stat_ar_stall,
      stat_sb_backpressure    => stat_sb_backpressure,
      stat_xactions           => stat_xactions,
      stat_beats              => stat_beats,
      stat_latency_sum        => stat_latency_sum,
      stat_latency_min        => stat_latency_min,
      stat_latency_max        => stat_latency_max,
      stat_first_latency_sum  => stat_first_latency_sum,
      stat_first_latency_min  => stat_first_latency_min,
      stat_first_latency_max  => stat_first_latency_max,
      stat_interbeat_gap_sum  => stat_interbeat_gap_sum,
      stat_interbeat_gap_min  => stat_interbeat_gap_min,
      stat_interbeat_gap_max  => stat_interbeat_gap_max,
      stat_burst_len_sum      => stat_burst_len_sum,
      stat_burst_len_min      => stat_burst_len_min,
      stat_burst_len_max      => stat_burst_len_max,
      stat_elapsed_cycles     => stat_elapsed_cycles,
      stat_r_stall            => stat_r_stall,
      pipeline_busy           => pipeline_busy,
      stat_max_outstanding    => stat_max_outstanding,
      stat_data_errors        => stat_data_errors,
      stat_id_errors          => stat_id_errors,
      stat_rlast_errors       => stat_rlast_errors,
      stat_resp_errors        => stat_resp_errors,
      stat_sb_underflow_errors => stat_sb_underflow_errors
    );

  ---------------------------------------------------------------------
  -- Small-FIFO monitor (same passive tap, tiny scoreboard).  Used only
  -- to force scoreboard backpressure during the corner-case tests.
  ---------------------------------------------------------------------
  u_monitor_bp : entity work.axi_monitor
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_TIME_WIDTH    => C_TIME_WIDTH,
      GC_STAT_WIDTH    => C_STAT_WIDTH,
      GC_SB_FIFO_DEPTH => 4
    )
    port map (
      aclk                    => aclk,
      aresetn                 => aresetn,
      global_time             => global_time,
      enable                  => mon_enable,
      aperture                => aperture,
      stat_rst                => stat_rst,
      err_rst                 => err_rst,
      data_check_en           => data_check_en,
      ar_valid                => ar_valid,
      ar_ready                => ar_ready,
      ar_id                   => ar_id,
      ar_addr                 => ar_addr,
      ar_len                  => ar_len,
      r_valid                 => r_valid,
      r_ready                 => r_ready,
      r_id                    => r_id,
      r_data                  => r_data,
      r_resp                  => r_resp,
      r_last                  => r_last,
      stat_ar_seen            => bp_stat_ar_seen,
      stat_ar_stall           => bp_stat_ar_stall,
      stat_sb_backpressure    => bp_stat_sb_backpressure,
      stat_xactions           => open,
      stat_beats              => open,
      stat_latency_sum        => open,
      stat_latency_min        => open,
      stat_latency_max        => open,
      stat_first_latency_sum  => open,
      stat_first_latency_min  => open,
      stat_first_latency_max  => open,
      stat_interbeat_gap_sum  => open,
      stat_interbeat_gap_min  => open,
      stat_interbeat_gap_max  => open,
      stat_burst_len_sum      => open,
      stat_burst_len_min      => open,
      stat_burst_len_max      => open,
      stat_elapsed_cycles     => open,
      stat_r_stall            => open,
      pipeline_busy           => open,
      stat_max_outstanding    => open,
      stat_data_errors        => open,
      stat_id_errors          => open,
      stat_rlast_errors       => open,
      stat_resp_errors        => open,
      stat_sb_underflow_errors => open
    );

  ---------------------------------------------------------------------
  -- Stimulus
  ---------------------------------------------------------------------
  p_stimulus : process
    variable l : line;
  begin
    -- Reset
    aresetn <= '0';
    wait_cycles(10);
    aresetn <= '1';
    wait_cycles(5);

    write(l, string'("=== T1: Passive monitoring, 16-beat linear bursts, data check ON ==="));
    writeline(output, l);

    -- Configure generator: 16-beat bursts, linear, no pace
    arid         <= (others => '0');
    ar_length    <= x"0F";
    pace         <= x"00000000";
    pace_init    <= x"00000000";
    base_addr    <= std_logic_vector(to_unsigned(16#1000#, C_ADDR_WIDTH));
    addr_range   <= std_logic_vector(to_unsigned(16#10000#, C_ADDR_WIDTH));
    addr_mode    <= '0';
    data_check_en <= '1';

    aperture   <= '1';
    check_ar_corner_cases <= '1';
    enable <= '1';

    -- Run for enough cycles to issue many bursts and drain R
    wait_cycles(2000);

    -- Stop generation, keep monitoring window open to drain
    enable <= '0';
    wait_drained(500000);

    -- Check:  ar_seen should equal generator ARs issued
    if unsigned(stat_ar_seen) = unsigned(gen_stat_ar_issued) then
      write(l, string'("  PASS: stat_ar_seen = "));
      write(l, to_integer(unsigned(stat_ar_seen)));
      write(l, string'(" = ar_issued"));
      writeline(output, l);
    else
      write(l, string'("  FAIL: ar_seen="));
      write(l, to_integer(unsigned(stat_ar_seen)));
      write(l, string'(" ar_issued="));
      write(l, to_integer(unsigned(gen_stat_ar_issued)));
      writeline(output, l);
      assert false report "T1 ar_seen mismatch" severity failure;
    end if;

    -- Check:  every burst completed -> xactions == ar_seen
    if unsigned(stat_xactions) = unsigned(stat_ar_seen) then
      write(l, string'("  PASS: stat_xactions = "));
      write(l, to_integer(unsigned(stat_xactions)));
      writeline(output, l);
    else
      write(l, string'("  FAIL: xactions="));
      write(l, to_integer(unsigned(stat_xactions)));
      write(l, string'(" ar_seen="));
      write(l, to_integer(unsigned(stat_ar_seen)));
      writeline(output, l);
      assert false report "T1 xactions mismatch" severity failure;
    end if;

    -- Check:  beats == xactions * 16
    if unsigned(stat_beats) = unsigned(stat_xactions) * 16 then
      write(l, string'("  PASS: stat_beats = "));
      write(l, to_integer(unsigned(stat_beats)));
      writeline(output, l);
    else
      write(l, string'("  FAIL: beats="));
      write(l, to_integer(unsigned(stat_beats)));
      writeline(output, l);
      assert false report "T1 beats mismatch" severity failure;
    end if;

    -- Check:  burst-length stats all equal 16
    if unsigned(stat_burst_len_min) = 16 and
       unsigned(stat_burst_len_max) = 16 then
      write(l, string'("  PASS: burst_len min/max = 16/16"));
      writeline(output, l);
    else
      write(l, string'("  FAIL: burst_len min="));
      write(l, to_integer(unsigned(stat_burst_len_min)));
      write(l, string'(" max="));
      write(l, to_integer(unsigned(stat_burst_len_max)));
      writeline(output, l);
      assert false report "T1 burst_len mismatch" severity failure;
    end if;

    -- Check:  no errors (data check ON against address-derived memory)
    if unsigned(stat_data_errors) = 0 and
       unsigned(stat_id_errors) = 0 and
       unsigned(stat_rlast_errors) = 0 and
       unsigned(stat_resp_errors) = 0 and
       unsigned(stat_sb_underflow_errors) = 0 then
      write(l, string'("  PASS: no data/id/rlast/resp/underflow errors"));
      writeline(output, l);
    else
      write(l, string'("  FAIL: data="));
      write(l, to_integer(unsigned(stat_data_errors)));
      write(l, string'(" id="));
      write(l, to_integer(unsigned(stat_id_errors)));
      write(l, string'(" rlast="));
      write(l, to_integer(unsigned(stat_rlast_errors)));
      write(l, string'(" resp="));
      write(l, to_integer(unsigned(stat_resp_errors)));
      write(l, string'(" sb_uf="));
      write(l, to_integer(unsigned(stat_sb_underflow_errors)));
      writeline(output, l);
      assert false report "T1 errors present" severity failure;
    end if;

    -- Check:  max_outstanding > 0 (traffic observed)
    if unsigned(stat_max_outstanding) > 0 then
      write(l, string'("  PASS: max_outstanding = "));
      write(l, to_integer(unsigned(stat_max_outstanding)));
      writeline(output, l);
    else
      write(l, string'("  FAIL: max_outstanding = 0"));
      writeline(output, l);
    end if;

    -- Check:  timing statistics are bounded and consistent with the
    -- mem_model configuration (base_latency=5, base_beat_gap=3).
    if unsigned(stat_latency_min) >= 5 and
       unsigned(stat_latency_max) >= unsigned(stat_latency_min) and
       unsigned(stat_first_latency_min) >= 5 and
       unsigned(stat_interbeat_gap_min) >= 1 then
      write(l, string'("  PASS: timing stats in expected bounds"));
      writeline(output, l);
    else
      write(l, string'("  FAIL: latency_min="));
      write(l, to_integer(unsigned(stat_latency_min)));
      write(l, string'(" latency_max="));
      write(l, to_integer(unsigned(stat_latency_max)));
      write(l, string'(" first_lat_min="));
      write(l, to_integer(unsigned(stat_first_latency_min)));
      write(l, string'(" gap_min="));
      write(l, to_integer(unsigned(stat_interbeat_gap_min)));
      writeline(output, l);
      assert false report "T1 timing stats out of bounds" severity failure;
    end if;

    write(l, string'("  xactions="));
    write(l, to_integer(unsigned(stat_xactions)));
    write(l, string'(" beats="));
    write(l, to_integer(unsigned(stat_beats)));
    write(l, string'(" ar_stall="));
    write(l, to_integer(unsigned(stat_ar_stall)));
    write(l, string'(" r_stall="));
    write(l, to_integer(unsigned(stat_r_stall)));
    write(l, string'(" latency_min="));
    write(l, to_integer(unsigned(stat_latency_min)));
    write(l, string'(" latency_max="));
    write(l, to_integer(unsigned(stat_latency_max)));
    writeline(output, l);

    ------------------------------------------------------------------
    -- T2: stat_rst clears counters (not burst tracking)
    ------------------------------------------------------------------
    write(l, string'("=== T2: stat_rst ==="));
    writeline(output, l);
    stat_rst <= '1';
    wait_cycles(2);
    stat_rst <= '0';
    wait_cycles(2);
    if unsigned(stat_beats) = 0 and unsigned(stat_xactions) = 0 then
      write(l, string'("  PASS: stat_rst cleared beats/xactions"));
      writeline(output, l);
    else
      write(l, string'("  FAIL: stat_rst did not clear"));
      writeline(output, l);
      assert false report "T2 stat_rst failed" severity failure;
    end if;

    ------------------------------------------------------------------
    -- T3: data_check_en = '0' -- beats still counted, data errors stay 0
    ------------------------------------------------------------------
    write(l, string'("=== T3: data check disabled ==="));
    writeline(output, l);
    data_check_en <= '0';
    enable        <= '1';
    aperture      <= '1';
    wait_cycles(1000);
    enable        <= '0';
    wait_drained(500000);

    if unsigned(stat_beats) > 0 and unsigned(stat_data_errors) = 0 then
      write(l, string'("  PASS: beats counted, no data errors (check off)"));
      writeline(output, l);
    else
      write(l, string'("  FAIL: beats="));
      write(l, to_integer(unsigned(stat_beats)));
      write(l, string'(" data_errs="));
      write(l, to_integer(unsigned(stat_data_errors)));
      writeline(output, l);
      assert false report "T3 data check off failed" severity failure;
    end if;

    ------------------------------------------------------------------
    -- T4: random addressing (power-of-two range) -- monitor tracks it
    ------------------------------------------------------------------
    write(l, string'("=== T4: Random addressing ==="));
    writeline(output, l);
    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst  <= '1'; wait_cycles(2); err_rst  <= '0';
    data_check_en <= '1';
    base_addr     <= std_logic_vector(to_unsigned(16#20000#, C_ADDR_WIDTH));
    addr_range    <= std_logic_vector(to_unsigned(16#10000#, C_ADDR_WIDTH));
    addr_mode     <= '1';
    enable        <= '1';
    aperture      <= '1';
    check_ar_corner_cases <= '1';
    wait_cycles(1500);
    enable        <= '0';
    wait_drained(500000);

    if unsigned(stat_ar_seen) = unsigned(gen_stat_ar_issued) and
       unsigned(stat_xactions) = unsigned(stat_ar_seen) then
      write(l, string'("  PASS: random mode ar_seen/xactions match"));
      writeline(output, l);
    else
      write(l, string'("  FAIL: ar_seen="));
      write(l, to_integer(unsigned(stat_ar_seen)));
      write(l, string'(" ar_issued="));
      write(l, to_integer(unsigned(gen_stat_ar_issued)));
      write(l, string'(" xactions="));
      write(l, to_integer(unsigned(stat_xactions)));
      writeline(output, l);
      assert false report "T4 random mismatch" severity failure;
    end if;

    if unsigned(stat_data_errors) = 0 and unsigned(stat_id_errors) = 0 then
      write(l, string'("  PASS: no errors in random mode"));
      writeline(output, l);
    else
      write(l, string'("  FAIL: data="));
      write(l, to_integer(unsigned(stat_data_errors)));
      write(l, string'(" id="));
      write(l, to_integer(unsigned(stat_id_errors)));
      writeline(output, l);
      assert false report "T4 errors present" severity failure;
    end if;

    ------------------------------------------------------------------
    -- T5: paced generation (pace=1) -- exercises the S_PACE_WAIT path
    ------------------------------------------------------------------
    write(l, string'("=== T5: Paced generation (pace=1) ==="));
    writeline(output, l);
    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst  <= '1'; wait_cycles(2); err_rst  <= '0';
    data_check_en <= '1';
    ar_length     <= x"07";
    pace          <= x"00000001";
    pace_init     <= x"00000000";
    base_addr     <= std_logic_vector(to_unsigned(16#1000#, C_ADDR_WIDTH));
    addr_range    <= std_logic_vector(to_unsigned(16#10000#, C_ADDR_WIDTH));
    addr_mode     <= '0';
    enable        <= '1';
    aperture      <= '1';
    check_ar_corner_cases <= '1';
    wait_cycles(1000);
    enable        <= '0';
    wait_drained(500000);

    if unsigned(stat_ar_seen) = unsigned(gen_stat_ar_issued) and
       unsigned(stat_xactions) = unsigned(stat_ar_seen) then
      write(l, string'("  PASS: paced mode ar_seen/xactions match"));
      writeline(output, l);
    else
      write(l, string'("  FAIL: ar_seen="));
      write(l, to_integer(unsigned(stat_ar_seen)));
      write(l, string'(" ar_issued="));
      write(l, to_integer(unsigned(gen_stat_ar_issued)));
      write(l, string'(" xactions="));
      write(l, to_integer(unsigned(stat_xactions)));
      writeline(output, l);
      assert false report "T5 paced mismatch" severity failure;
    end if;

    if unsigned(stat_beats) = unsigned(stat_xactions) * 8 then
      write(l, string'("  PASS: beats = xactions*8 (8-beat bursts)"));
      writeline(output, l);
    else
      write(l, string'("  FAIL: beats="));
      write(l, to_integer(unsigned(stat_beats)));
      write(l, string'(" xactions="));
      write(l, to_integer(unsigned(stat_xactions)));
      writeline(output, l);
      assert false report "T5 beats mismatch" severity failure;
    end if;

    if unsigned(stat_data_errors) = 0 and unsigned(stat_id_errors) = 0 then
      write(l, string'("  PASS: no errors in paced mode"));
      writeline(output, l);
    else
      write(l, string'("  FAIL: data="));
      write(l, to_integer(unsigned(stat_data_errors)));
      write(l, string'(" id="));
      write(l, to_integer(unsigned(stat_id_errors)));
      writeline(output, l);
      assert false report "T5 errors present" severity failure;
    end if;

    ------------------------------------------------------------------
    -- T6: pace=2, pace_init, and one-beat bursts
    ------------------------------------------------------------------
    write(l, string'("=== T6: pace=2, pace_init, one-beat bursts ==="));
    writeline(output, l);
    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst  <= '1'; wait_cycles(2); err_rst <= '0';
    ar_length <= x"00";
    pace      <= x"00000002";
    pace_init <= x"00000003";
    base_addr <= std_logic_vector(to_unsigned(16#3000#, C_ADDR_WIDTH));
    addr_range <= std_logic_vector(to_unsigned(16#1000#, C_ADDR_WIDTH));
    addr_mode <= '0';
    data_check_en <= '1';
    enable <= '1';
    aperture <= '1';
    check_ar_corner_cases <= '1';
    wait_cycles(300);
    enable <= '0';
    wait_drained(500000);

    assert unsigned(stat_ar_seen) = unsigned(gen_stat_ar_issued) and
           unsigned(stat_xactions) = unsigned(stat_ar_seen) and
           unsigned(stat_beats) = unsigned(stat_xactions) and
           unsigned(stat_burst_len_min) = 1 and
           unsigned(stat_burst_len_max) = 1
      report "T6: paced one-beat accounting mismatch"
      severity failure;
    assert unsigned(stat_data_errors) = 0 and
           unsigned(stat_id_errors) = 0 and
           unsigned(stat_rlast_errors) = 0 and
           unsigned(stat_resp_errors) = 0 and
           unsigned(stat_sb_underflow_errors) = 0
      report "T6: unexpected paced one-beat error"
      severity failure;
    write(l, string'("  PASS: pace/init/one-beat path"));
    writeline(output, l);

    ------------------------------------------------------------------
    -- T7: R-channel backpressure must be counted without corruption
    ------------------------------------------------------------------
    write(l, string'("=== T7: R-channel backpressure ==="));
    writeline(output, l);
    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst  <= '1'; wait_cycles(2); err_rst <= '0';
    r_ready <= '0';
    ar_length <= x"07";
    pace <= x"00000000";
    pace_init <= x"00000000";
    base_addr <= std_logic_vector(to_unsigned(16#4000#, C_ADDR_WIDTH));
    addr_range <= std_logic_vector(to_unsigned(16#10000#, C_ADDR_WIDTH));
    addr_mode <= '0';
    data_check_en <= '1';
    enable <= '1';
    aperture <= '1';
    check_ar_corner_cases <= '1';
    wait_cycles(100);
    r_ready <= '1';
    wait_cycles(1000);
    enable <= '0';
    wait_drained(500000);

    assert unsigned(stat_r_stall) > 0
      report "T7: R backpressure was not counted"
      severity failure;
    assert unsigned(stat_data_errors) = 0 and
           unsigned(stat_id_errors) = 0 and
           unsigned(stat_rlast_errors) = 0 and
           unsigned(stat_resp_errors) = 0 and
           unsigned(stat_sb_underflow_errors) = 0
      report "T7: R backpressure caused monitor errors"
      severity failure;
    write(l, string'("  PASS: R stall counted, no errors"));
    writeline(output, l);

    ------------------------------------------------------------------
    -- T8: per-instance monitor disable while traffic continues
    ------------------------------------------------------------------
    write(l, string'("=== T8: monitor enable gating ==="));
    writeline(output, l);
    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst  <= '1'; wait_cycles(2); err_rst <= '0';
    mon_enable <= '0';
    enable <= '1';
    aperture <= '1';
    wait_cycles(300);
    enable <= '0';
    wait_cycles(5000);

    assert unsigned(stat_ar_seen) = 0 and
           unsigned(stat_xactions) = 0 and
           unsigned(stat_beats) = 0 and
           unsigned(stat_data_errors) = 0 and
           unsigned(stat_sb_underflow_errors) = 0 and
           pipeline_busy = '0'
      report "T8: disabled monitor was not inert"
      severity failure;
    mon_enable <= '1';
    write(l, string'("  PASS: disabled monitor remained inert"));
    writeline(output, l);

    ------------------------------------------------------------------
    -- T9: each R protocol/data error counter and err_rst
    ------------------------------------------------------------------
    write(l, string'("=== T9: injected R errors and err_rst ==="));
    writeline(output, l);
    ar_length <= x"00";
    pace <= x"00000000";
    base_addr <= std_logic_vector(to_unsigned(16#5000#, C_ADDR_WIDTH));
    addr_range <= std_logic_vector(to_unsigned(16#1000#, C_ADDR_WIDTH));
    addr_mode <= '0';
    aperture <= '1';
    enable <= '1';
    check_ar_corner_cases <= '1';

    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst <= '1'; wait_cycles(2); err_rst <= '0';
    inject_data_error <= '1';
    wait_cycles(100);
    enable <= '0';
    wait_drained(500000);
    inject_data_error <= '0';
    assert unsigned(stat_data_errors) > 0
      report "T9: data error was not detected"
      severity failure;

    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst <= '1'; wait_cycles(2); err_rst <= '0';
    enable <= '1';
    inject_id_error <= '1';
    wait_cycles(100);
    enable <= '0';
    wait_drained(500000);
    inject_id_error <= '0';
    assert unsigned(stat_id_errors) > 0
      report "T9: ID error was not detected"
      severity failure;

    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst <= '1'; wait_cycles(2); err_rst <= '0';
    enable <= '1';
    inject_resp_error <= '1';
    wait_cycles(100);
    enable <= '0';
    wait_drained(500000);
    inject_resp_error <= '0';
    assert unsigned(stat_resp_errors) > 0
      report "T9: response error was not detected"
      severity failure;

    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst <= '1'; wait_cycles(2); err_rst <= '0';
    enable <= '1';
    inject_rlast_error <= '1';
    wait_cycles(100);
    enable <= '0';
    wait_drained(500000);
    inject_rlast_error <= '0';
    assert unsigned(stat_rlast_errors) > 0
      report "T9: RLAST error was not detected"
      severity failure;

    err_rst <= '1'; wait_cycles(2); err_rst <= '0';
    assert unsigned(stat_data_errors) = 0 and
           unsigned(stat_id_errors) = 0 and
           unsigned(stat_resp_errors) = 0 and
           unsigned(stat_rlast_errors) = 0
      report "T9: err_rst did not clear injected errors"
      severity failure;
    write(l, string'("  PASS: data/ID/RESP/RLAST errors and err_rst"));
    writeline(output, l);

    ------------------------------------------------------------------
    -- T10: burst start near the window end is clamped/wrapped so the
    -- full burst always fits inside [base, base+range-bsize].
    ------------------------------------------------------------------
    write(l, string'("=== T10: window-end clamp ==="));
    writeline(output, l);
    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst  <= '1'; wait_cycles(2); err_rst <= '0';
    inject_data_error <= '0';
    inject_id_error <= '0';
    inject_resp_error <= '0';
    inject_rlast_error <= '0';
    ar_length <= x"0F";
    pace <= x"00000000";
    pace_init <= x"00000000";
    base_addr <= std_logic_vector(to_unsigned(16#1FF0#, C_ADDR_WIDTH));
    addr_range <= std_logic_vector(to_unsigned(16#2000#, C_ADDR_WIDTH));
    addr_mode <= '0';
    data_check_en <= '1';
    enable <= '1';
    aperture <= '1';
    check_ar_corner_cases <= '1';
    wait_cycles(100);
    enable <= '0';
    wait_drained(500000);
    assert unsigned(stat_ar_seen) = unsigned(gen_stat_ar_issued) and
           unsigned(stat_xactions) = unsigned(stat_ar_seen)
      report "T10: boundary traffic accounting mismatch"
      severity failure;
    write(l, string'("  PASS: no burst exceeded the window end"));
    writeline(output, l);

    ------------------------------------------------------------------
    -- T11: maximum burst length (255 -> 256 beats) completes
    ------------------------------------------------------------------
    write(l, string'("=== T11: maximum burst length ==="));
    writeline(output, l);
    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst  <= '1'; wait_cycles(2); err_rst <= '0';
    ar_length <= x"FF";              -- max ARLEN -> 256 beats
    pace <= x"00000064";             -- leave time for one burst
    pace_init <= x"00000000";
    base_addr <= std_logic_vector(to_unsigned(16#6000#, C_ADDR_WIDTH));
    addr_range <= std_logic_vector(to_unsigned(16#2000#, C_ADDR_WIDTH));
    addr_mode <= '0';
    aperture <= '1';
    gen_aperture <= '1';
    enable <= '1';
    check_ar_corner_cases <= '1';
    wait_cycles(100);
    enable <= '0';
    wait_drained(500000);
    assert unsigned(stat_burst_len_max) = 256
      report "T11: ar_length did not produce a 256-beat burst"
      severity failure;
    write(l, string'("  PASS: max burst length (256 beats)"));
    writeline(output, l);

    ------------------------------------------------------------------
    -- T12: aperture gates AR-side statistics, not R-side completion
    ------------------------------------------------------------------
    write(l, string'("=== T12: independent AR aperture gating ==="));
    writeline(output, l);
    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst  <= '1'; wait_cycles(2); err_rst <= '0';
    ar_length <= x"00";
    pace <= x"00000000";
    pace_init <= x"00000000";
    base_addr <= std_logic_vector(to_unsigned(16#7000#, C_ADDR_WIDTH));
    addr_range <= std_logic_vector(to_unsigned(16#1000#, C_ADDR_WIDTH));
    addr_mode <= '0';
    aperture <= '0';
    gen_aperture <= '1';
    enable <= '1';
    check_ar_corner_cases <= '1';
    wait_cycles(100);
    enable <= '0';
    wait_cycles(5000);
    assert unsigned(stat_ar_seen) = 0
      report "T12: AR statistics accumulated while aperture was low"
      severity failure;
    assert unsigned(stat_xactions) > 0 and unsigned(stat_beats) > 0
      report "T12: R-side completion was incorrectly aperture-gated"
      severity failure;
    assert unsigned(stat_data_errors) = 0 and
           unsigned(stat_id_errors) = 0 and
           unsigned(stat_rlast_errors) = 0 and
           unsigned(stat_resp_errors) = 0 and
           unsigned(stat_sb_underflow_errors) = 0
      report "T12: aperture test caused monitor errors"
      severity failure;
    write(l, string'("  PASS: AR aperture gate and R completion"));
    writeline(output, l);

    ------------------------------------------------------------------
    -- T13: scoreboard underflow -- R beats with no AR descriptor
    ------------------------------------------------------------------
    write(l, string'("=== T13: scoreboard underflow ==="));
    writeline(output, l);
    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst  <= '1'; wait_cycles(2); err_rst <= '0';
    enable <= '0';
    aperture <= '1';
    wait_drained(500000);
    assert unsigned(stat_sb_underflow_errors) = 0 and
           unsigned(stat_ar_seen) = 0
      report "T13: unexpected state before underflow injection"
      severity failure;

    -- Inject spurious R beats with no matching AR entry.  r_ready stays
    -- high so the R monitor pops an empty scoreboard.
    r_ready <= '1';
    spurious_r_valid <= '1';
    wait_cycles(3);
    spurious_r_valid <= '0';
    wait_cycles(5);

    assert unsigned(stat_sb_underflow_errors) = 3
      report "T13: underflow counter did not increment per spurious beat"
      severity failure;
    assert unsigned(stat_beats) = 3
      report "T13: spurious beats were not counted as beats"
      severity failure;
    assert unsigned(stat_data_errors) = 0
      report "T13: underflow beats must not trigger data errors"
      severity failure;
    write(l, string'("  PASS: underflow detected and counted"));
    writeline(output, l);

    ------------------------------------------------------------------
    -- T14: scoreboard backpressure -- tiny FIFO stalls under load
    ------------------------------------------------------------------
    write(l, string'("=== T14: scoreboard backpressure ==="));
    writeline(output, l);
    stat_rst <= '1'; wait_cycles(2); stat_rst <= '0';
    err_rst  <= '1'; wait_cycles(2); err_rst <= '0';
    spurious_r_valid <= '0';
    r_ready <= '0';               -- hold R back so the small scoreboard fills
    ar_length <= x"0F";     -- 16-beat bursts
    pace <= x"00000000";
    pace_init <= x"00000000";
    base_addr <= std_logic_vector(to_unsigned(16#2000#, C_ADDR_WIDTH));
    addr_range <= std_logic_vector(to_unsigned(16#4000#, C_ADDR_WIDTH));
    addr_mode <= '0';
    aperture <= '1';
    gen_aperture <= '1';
    enable <= '1';
    wait_cycles(300);
    enable <= '0';
    r_ready <= '1';               -- release R so the pipeline drains
    wait_drained(500000);

    -- Small monitor (depth 4) must have seen scoreboard backpressure.
    assert unsigned(bp_stat_sb_backpressure) > 0
      report "T14: small monitor never saw scoreboard backpressure"
      severity failure;
    -- The deep monitor should not have errored; beats drain fine.
    assert unsigned(stat_sb_underflow_errors) = 0
      report "T14: deep monitor reported underflow"
      severity failure;
    assert unsigned(stat_beats) > 0 and
           unsigned(stat_beats) = unsigned(stat_xactions) * 16
      report "T14: beat accounting broken under backpressure"
      severity failure;
    write(l, string'("  PASS: scoreboard backpressure observed"));
    writeline(output, l);

    write(l, string'("=== Simulation complete ==="));
    writeline(output, l);
    sim_done <= true;
    wait;
  end process p_stimulus;

  -- Watchdog
  p_watchdog : process
  begin
    wait for 20 ms;
    assert sim_done report "Watchdog timeout" severity failure;
    wait;
  end process;

end architecture;
