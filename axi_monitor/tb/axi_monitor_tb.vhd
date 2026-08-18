-----------------------------------------------------------------------
--Filename         : axi_monitor_tb.vhd
--Description      : Integration testbench for axi_monitor.  Instantiates
--                   axi_read_bridge + axi_mem_model and taps one bridge
--                   client (client 0) with axi_monitor, validating that
--                   the monitor's stats track real bridge traffic with
--                   zero false errors.  A second monitor instance is
--                   driven by a hand-written req/rsp process to verify
--                   the error-detection paths (data / resp / rlast /
--                   scoreboard underflow) and the soft resets.
--
--                   Corner-case coverage (phases E-M): rsp backpressure,
--                   req backpressure (credit exhaustion), scoreboard
--                   backpressure (small-FIFO monitor), per-instance
--                   disable/re-enable, stat_rst mid-traffic, err_rst
--                   coincident with error detection, maximum and mixed
--                   burst lengths, sustained varied traffic, and
--                   stat-accumulator consistency (elapsed counter,
--                   min/max/sum, pipeline_busy, max_outstanding).
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_monitor_tb is
end entity axi_monitor_tb;

architecture sim of axi_monitor_tb is
  constant C_NUM_CLIENTS      : positive := 4;
  constant C_ADDR_WIDTH       : positive := 32;
  constant C_ID_WIDTH         : positive := 4;
  constant C_CLIENT_BYTES     : positive := 64;
  constant C_NATIVE_BYTES     : positive := 16;
  constant C_CLIENT_LEN_WIDTH : positive := 6;
  constant C_CLIENT_FIFO_DEPTH : positive := 32;
  constant C_CDC_DEPTH        : positive := 8;
  constant C_CLIENT_PERIOD    : time := 10 ns;
  constant C_MEM_PERIOD       : time := 4 ns;
  constant C_TIMEOUT          : time := 2 ms;

  constant C_MON_TIME_WIDTH   : positive := 48;
  constant C_MON_STAT_WIDTH   : positive := 48;
  constant C_MON_SB_DEPTH     : positive := 16;

  signal aclk : std_logic := '0';
  signal mem_aclk    : std_logic := '0';
  signal aresetn     : std_logic := '0';
  signal sim_done    : boolean := false;

  signal global_time : unsigned(C_MON_TIME_WIDTH-1 downto 0) := (others => '0');

  -- Bridge client interfaces
  signal req_addr  : slv_array_t(0 to C_NUM_CLIENTS-1)(C_ADDR_WIDTH-1 downto 0) := (others => (others => '0'));
  signal req_len   : slv_array_t(0 to C_NUM_CLIENTS-1)(C_CLIENT_LEN_WIDTH-1 downto 0) := (others => (others => '0'));
  signal req_valid : std_logic_vector(0 to C_NUM_CLIENTS-1) := (others => '0');
  signal req_ready : std_logic_vector(0 to C_NUM_CLIENTS-1);

  signal rsp_data  : slv_array_t(0 to C_NUM_CLIENTS-1)(8*C_CLIENT_BYTES-1 downto 0);
  signal rsp_resp  : slv2_array_t(0 to C_NUM_CLIENTS-1);
  signal rsp_last  : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal rsp_valid : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal rsp_ready : std_logic_vector(0 to C_NUM_CLIENTS-1) := (others => '1');

  -- Native AXI interface (bridge <-> mem model)
  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);
  signal ar_size  : std_logic_vector(2 downto 0);
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;
  signal r_id     : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data   : std_logic_vector(8*C_NATIVE_BYTES-1 downto 0);
  signal r_resp   : std_logic_vector(1 downto 0);
  signal r_last   : std_logic;
  signal r_valid  : std_logic;
  signal r_ready  : std_logic;

  -- Monitor (client 0) control
  signal mon_enable      : std_logic := '0';
  signal mon_stat_rst    : std_logic := '0';
  signal mon_err_rst     : std_logic := '0';
  signal mon_data_check  : std_logic := '1';
  signal mon_pipeline    : std_logic;

  signal mon_req_len8 : std_logic_vector(7 downto 0);

  -- Monitor (client 0) statistics
  signal stat_req_seen            : std_logic_vector(31 downto 0);
  signal stat_req_stall           : std_logic_vector(31 downto 0);
  signal stat_sb_backpressure     : std_logic_vector(31 downto 0);
  signal stat_xactions            : std_logic_vector(31 downto 0);
  signal stat_beats               : std_logic_vector(31 downto 0);
  signal stat_latency_sum         : std_logic_vector(C_MON_STAT_WIDTH-1 downto 0);
  signal stat_latency_min         : std_logic_vector(31 downto 0);
  signal stat_latency_max         : std_logic_vector(31 downto 0);
  signal stat_first_latency_sum   : std_logic_vector(C_MON_STAT_WIDTH-1 downto 0);
  signal stat_first_latency_min   : std_logic_vector(31 downto 0);
  signal stat_first_latency_max   : std_logic_vector(31 downto 0);
  signal stat_interbeat_gap_sum   : std_logic_vector(C_MON_STAT_WIDTH-1 downto 0);
  signal stat_interbeat_gap_min   : std_logic_vector(31 downto 0);
  signal stat_interbeat_gap_max   : std_logic_vector(31 downto 0);
  signal stat_burst_len_sum       : std_logic_vector(C_MON_STAT_WIDTH-1 downto 0);
  signal stat_burst_len_min       : std_logic_vector(31 downto 0);
  signal stat_burst_len_max       : std_logic_vector(31 downto 0);
  signal stat_elapsed_cycles      : std_logic_vector(31 downto 0);
  signal stat_rsp_stall           : std_logic_vector(31 downto 0);
  signal stat_max_outstanding     : std_logic_vector(31 downto 0);
  signal stat_data_errors         : std_logic_vector(31 downto 0);
  signal stat_rlast_errors        : std_logic_vector(31 downto 0);
  signal stat_resp_errors         : std_logic_vector(31 downto 0);
  signal stat_sb_underflow_errors : std_logic_vector(31 downto 0);

  -- Error-injection monitor (hand-driven req/rsp)
  signal err_enable     : std_logic := '0';
  signal err_data_check : std_logic := '1';
  signal err_pipeline   : std_logic;
  signal err_req_valid  : std_logic := '0';
  signal err_req_ready  : std_logic := '1';  -- hand-driven slave always accepts
  signal err_req_addr   : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal err_req_len    : std_logic_vector(7 downto 0) := (others => '0');
  signal err_rsp_valid  : std_logic := '0';
  signal err_rsp_ready  : std_logic := '1';
  signal err_rsp_data   : std_logic_vector(8*C_CLIENT_BYTES-1 downto 0) := (others => '0');
  signal err_rsp_resp   : std_logic_vector(1 downto 0) := (others => '0');
  signal err_rsp_last   : std_logic := '0';
  signal err_stat_data_errors         : std_logic_vector(31 downto 0);
  signal err_stat_xactions            : std_logic_vector(31 downto 0);
  signal err_stat_beats               : std_logic_vector(31 downto 0);
  signal err_stat_req_seen            : std_logic_vector(31 downto 0);
  signal err_stat_req_stall           : std_logic_vector(31 downto 0);
  signal err_stat_burst_len_min       : std_logic_vector(31 downto 0);
  signal err_stat_burst_len_max       : std_logic_vector(31 downto 0);
  signal err_stat_rlast_errors        : std_logic_vector(31 downto 0);
  signal err_stat_resp_errors         : std_logic_vector(31 downto 0);
  signal err_stat_sb_underflow_errors : std_logic_vector(31 downto 0);

  signal watchdog_expired : boolean := false;

  -- Small-FIFO monitor (client 0 tap) to force scoreboard backpressure.
  signal bp_req_len8 : std_logic_vector(7 downto 0);
  signal bp_stat_req_seen        : std_logic_vector(31 downto 0);
  signal bp_stat_sb_backpressure : std_logic_vector(31 downto 0);

  -- Error-injection monitor soft resets (driven by p_stim).
  signal err_stat_rst : std_logic := '0';
  signal err_err_rst  : std_logic := '0';

  -- References for stat-consistency checks (mirror the RTL counters).
  signal mon_elapsed_ref : unsigned(31 downto 0) := (others => '0');
  signal busy_high_seen  : std_logic := '0';
begin

  p_client_clk : process
  begin
    aclk <= '0';
    while not sim_done loop
      wait for C_CLIENT_PERIOD / 2;
      aclk <= not aclk;
    end loop;
    aclk <= '0';
    wait;
  end process;

  p_mem_clk : process
  begin
    mem_aclk <= '0';
    while not sim_done loop
      wait for C_MEM_PERIOD / 2;
      mem_aclk <= not mem_aclk;
    end loop;
    mem_aclk <= '0';
    wait;
  end process;

  p_time : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        global_time <= (others => '0');
      else
        global_time <= global_time + 1;
      end if;
    end if;
  end process;

  p_watchdog : process
  begin
    wait for C_TIMEOUT;
    if not sim_done then
      watchdog_expired <= true;
      report "axi_monitor_tb watchdog timeout" severity failure;
    end if;
    wait;
  end process;

  -- Reference counter for stat_elapsed_cycles: increments while the
  -- client-0 monitor is enabled, cleared by stat_rst (same as the RTL).
  p_elapsed_ref : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' or mon_stat_rst = '1' then
        mon_elapsed_ref <= (others => '0');
      elsif mon_enable = '1' then
        mon_elapsed_ref <= mon_elapsed_ref + 1;
      end if;
    end if;
  end process;

  -- Latch: set the first cycle the client-0 monitor pipeline is busy.
  p_busy_track : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' or mon_stat_rst = '1' then
        busy_high_seen <= '0';
      elsif mon_pipeline = '1' then
        busy_high_seen <= '1';
      end if;
    end if;
  end process;

  u_bridge : entity work.axi_read_bridge
    generic map (
      GC_NUM_CLIENTS        => C_NUM_CLIENTS,
      GC_ADDR_WIDTH         => C_ADDR_WIDTH,
      GC_ID_WIDTH           => C_ID_WIDTH,
      GC_CLIENT_DATA_BYTES  => C_CLIENT_BYTES,
      GC_NATIVE_DATA_BYTES  => C_NATIVE_BYTES,
      GC_NATIVE_ARLEN_WIDTH => 8,
      GC_CLIENT_FIFO_DEPTH  => C_CLIENT_FIFO_DEPTH,
      GC_CDC_DEPTH          => C_CDC_DEPTH
    )
    port map (
      aclk => aclk,
      mem_aclk    => mem_aclk,
      aresetn     => aresetn,
      req_addr    => req_addr,
      req_len     => req_len,
      req_valid   => req_valid,
      req_ready   => req_ready,
      rsp_data    => rsp_data,
      rsp_resp    => rsp_resp,
      rsp_last    => rsp_last,
      rsp_valid   => rsp_valid,
      rsp_ready   => rsp_ready,
      ar_id       => ar_id,
      ar_addr     => ar_addr,
      ar_len      => ar_len,
      ar_valid    => ar_valid,
      ar_ready    => ar_ready,
      r_id        => r_id,
      r_data      => r_data,
      r_resp      => r_resp,
      r_last      => r_last,
      r_valid     => r_valid,
      r_ready     => r_ready
    );

  u_mem : entity work.axi_mem_model
    generic map (
      GC_DATA_BYTES    => C_NATIVE_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_TIMER_WIDTH   => 16,
      GC_AR_FIFO_DEPTH => 8,
      GC_R_FIFO_DEPTH  => 8
    )
    port map (
      aclk            => mem_aclk,
      aresetn         => aresetn,
      ar_base_enable  => '0',
      ar_jitter_enable => '0',
      r_base_enable   => '0',
      r_jitter_enable => '0',
      base_latency    => (others => '0'),
      base_beat_gap   => (others => '0'),
      ar_id           => ar_id,
      ar_addr         => ar_addr,
      ar_len          => ar_len,
      ar_valid        => ar_valid,
      ar_ready        => ar_ready,
      r_id            => r_id,
      r_data          => r_data,
      r_resp          => r_resp,
      r_last          => r_last,
      r_valid         => r_valid,
      r_ready         => r_ready
    );

  -- Monitor taps client 0's req/rsp interface.
  mon_req_len8 <= "00" & req_len(0);

  u_monitor : entity work.axi_monitor
    generic map (
      GC_DATA_BYTES    => C_CLIENT_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_TIME_WIDTH    => C_MON_TIME_WIDTH,
      GC_STAT_WIDTH    => C_MON_STAT_WIDTH,
      GC_SB_FIFO_DEPTH => C_MON_SB_DEPTH
    )
    port map (
      aclk                    => aclk,
      aresetn                 => aresetn,
      global_time             => global_time,
      enable                  => mon_enable,
      stat_rst                => mon_stat_rst,
      err_rst                 => mon_err_rst,
      data_check_en           => mon_data_check,
      pipeline_busy           => mon_pipeline,
      req_valid               => req_valid(0),
      req_ready               => req_ready(0),
      req_addr                => req_addr(0),
      req_len                 => mon_req_len8,
      rsp_valid               => rsp_valid(0),
      rsp_ready               => rsp_ready(0),
      rsp_data                => rsp_data(0),
      rsp_resp                => rsp_resp(0),
      rsp_last                => rsp_last(0),
      stat_req_seen           => stat_req_seen,
      stat_req_stall          => stat_req_stall,
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
      stat_rsp_stall          => stat_rsp_stall,
      stat_max_outstanding    => stat_max_outstanding,
      stat_data_errors        => stat_data_errors,
      stat_rlast_errors       => stat_rlast_errors,
      stat_resp_errors        => stat_resp_errors,
      stat_sb_underflow_errors => stat_sb_underflow_errors
    );

  -- Error-injection monitor: hand-driven req/rsp to exercise error paths.
  u_mon_err : entity work.axi_monitor
    generic map (
      GC_DATA_BYTES    => C_CLIENT_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_TIME_WIDTH    => C_MON_TIME_WIDTH,
      GC_STAT_WIDTH    => C_MON_STAT_WIDTH,
      GC_SB_FIFO_DEPTH => C_MON_SB_DEPTH
    )
    port map (
      aclk                    => aclk,
      aresetn                 => aresetn,
      global_time             => global_time,
      enable                  => err_enable,
      stat_rst                => err_stat_rst,
      err_rst                 => err_err_rst,
      data_check_en           => err_data_check,
      pipeline_busy           => err_pipeline,
      req_valid               => err_req_valid,
      req_ready               => err_req_ready,
      req_addr                => err_req_addr,
      req_len                 => err_req_len,
      rsp_valid               => err_rsp_valid,
      rsp_ready               => err_rsp_ready,
      rsp_data                => err_rsp_data,
      rsp_resp                => err_rsp_resp,
      rsp_last                => err_rsp_last,
      stat_req_seen           => err_stat_req_seen,
      stat_req_stall          => err_stat_req_stall,
      stat_sb_backpressure    => open,
      stat_xactions           => err_stat_xactions,
      stat_beats              => err_stat_beats,
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
      stat_burst_len_min      => err_stat_burst_len_min,
      stat_burst_len_max      => err_stat_burst_len_max,
      stat_elapsed_cycles     => open,
      stat_rsp_stall          => open,
      stat_max_outstanding    => open,
      stat_data_errors        => err_stat_data_errors,
      stat_rlast_errors       => err_stat_rlast_errors,
      stat_resp_errors        => err_stat_resp_errors,
      stat_sb_underflow_errors => err_stat_sb_underflow_errors
    );

  -- Small-FIFO monitor: same client-0 tap, tiny scoreboard.  Used only
  -- to force scoreboard backpressure during the corner-case tests.
  bp_req_len8 <= "00" & req_len(0);

  u_monitor_bp : entity work.axi_monitor
    generic map (
      GC_DATA_BYTES    => C_CLIENT_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_TIME_WIDTH    => C_MON_TIME_WIDTH,
      GC_STAT_WIDTH    => C_MON_STAT_WIDTH,
      GC_SB_FIFO_DEPTH => 4
    )
    port map (
      aclk                    => aclk,
      aresetn                 => aresetn,
      global_time             => global_time,
      enable                  => mon_enable,
      stat_rst                => mon_stat_rst,
      err_rst                 => mon_err_rst,
      data_check_en           => mon_data_check,
      pipeline_busy           => open,
      req_valid               => req_valid(0),
      req_ready               => req_ready(0),
      req_addr                => req_addr(0),
      req_len                 => bp_req_len8,
      rsp_valid               => rsp_valid(0),
      rsp_ready               => rsp_ready(0),
      rsp_data                => rsp_data(0),
      rsp_resp                => rsp_resp(0),
      rsp_last                => rsp_last(0),
      stat_req_seen           => bp_stat_req_seen,
      stat_req_stall          => open,
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
      stat_rsp_stall          => open,
      stat_max_outstanding    => open,
      stat_data_errors        => open,
      stat_rlast_errors       => open,
      stat_resp_errors        => open,
      stat_sb_underflow_errors => open
    );

  p_stim : process
    variable wait_count : natural;
    variable v_expected_data : std_logic_vector(8*C_CLIENT_BYTES-1 downto 0);
    variable v_bad_data      : std_logic_vector(8*C_CLIENT_BYTES-1 downto 0) := (others => '0');
    variable v_rsp_data      : std_logic_vector(8*C_CLIENT_BYTES-1 downto 0);
    variable v_rsp_resp      : std_logic_vector(1 downto 0);
    variable v_rsp_last      : std_logic;
    variable v_word : natural;

    -- Issue one client read request (req channel): drive addr/len/valid and
    -- hold until a rising-edge ready handshake.
    procedure req_w(
      signal   clk      : in  std_logic;
      signal   addr     : out std_logic_vector;
      signal   len      : out std_logic_vector;
      signal   valid    : out std_logic;
      signal   ready    : in  std_logic;
      constant req_addr : in  std_logic_vector;
      constant req_len  : in  std_logic_vector
    ) is
    begin
      addr  <= req_addr;
      len   <= req_len;
      valid <= '1';
      loop
        wait until rising_edge(clk);
        exit when ready = '1';
      end loop;
      valid <= '0';
    end procedure;

    -- Read one client response beat (rsp channel): hold ready until a
    -- rising-edge valid handshake, then return data/resp/last.
    procedure rsp_rd(
      signal   clk    : in  std_logic;
      signal   ready  : out std_logic;
      signal   valid  : in  std_logic;
      signal   data   : in  std_logic_vector;
      signal   resp   : in  std_logic_vector;
      signal   last   : in  std_logic;
      variable r_data : out std_logic_vector;
      variable r_resp : out std_logic_vector;
      variable r_last : out std_logic
    ) is
    begin
      ready <= '1';
      loop
        wait until rising_edge(clk);
        exit when valid = '1';
      end loop;
      r_data := data;
      r_resp := resp;
      r_last := last;
      ready  <= '0';
    end procedure;

    -- Drive one client response beat (rsp channel, responder role): hold
    -- valid and the payload until a rising-edge ready handshake.
    procedure rsp_w(
      signal   clk      : in  std_logic;
      signal   valid    : out std_logic;
      signal   ready    : in  std_logic;
      signal   data     : out std_logic_vector;
      signal   resp     : out std_logic_vector;
      signal   last     : out std_logic;
      constant rsp_data : in  std_logic_vector;
      constant rsp_resp : in  std_logic_vector;
      constant rsp_last : in  std_logic
    ) is
    begin
      valid <= '1';
      data  <= rsp_data;
      resp  <= rsp_resp;
      last  <= rsp_last;
      loop
        wait until rising_edge(clk);
        exit when ready = '1';
      end loop;
      valid <= '0';
    end procedure;

    -- Pulse both soft resets (each sampled at one rising edge).
    procedure p_stat_err_rst(
      signal clk   : in  std_logic;
      signal s_rst : out std_logic;
      signal e_rst : out std_logic
    ) is
    begin
      wait until falling_edge(clk);
      s_rst <= '1';
      e_rst <= '1';
      wait until rising_edge(clk);
      s_rst <= '0';
      e_rst <= '0';
      wait until rising_edge(clk);
    end procedure;

    -- Wait until the monitor pipeline drains (scoreboard empty).
    procedure p_drain(
      signal   clk      : in  std_logic;
      signal   pipeline : in  std_logic;
      constant tag      : in  string;
      variable waited   : inout natural
    ) is
    begin
      waited := 0;
      loop
        wait until rising_edge(clk);
        exit when pipeline = '0';
        waited := waited + 1;
        assert waited < 100000
          report "drain timeout: " & tag severity failure;
      end loop;
    end procedure;

    -- Read a burst of `beats` response beats (rsp channel): hold ready
    -- until each valid handshake, return data/resp/last, and check
    -- resp=OKAY and last only on the final beat.
    procedure p_rsp_burst(
      signal   clk    : in  std_logic;
      signal   ready  : out std_logic;
      signal   valid  : in  std_logic;
      signal   data   : in  std_logic_vector;
      signal   resp   : in  std_logic_vector;
      signal   last   : in  std_logic;
      variable r_data : out std_logic_vector;
      variable r_resp : out std_logic_vector;
      variable r_last : out std_logic;
      constant beats  : in  natural;
      constant tag    : in  string
    ) is
      variable n : natural;
    begin
      n := 0;
      while n < beats loop
        ready <= '1';
        loop
          wait until rising_edge(clk);
          exit when valid = '1';
        end loop;
        r_data := data;
        r_resp := resp;
        r_last := last;
        ready  <= '0';
        assert r_resp = "00"
          report "rsp resp wrong (" & tag & ")" severity failure;
        if n = beats-1 then
          assert r_last = '1'
            report "final rsp not last (" & tag & ")" severity failure;
        else
          assert r_last = '0'
            report "early rsp asserted last (" & tag & ")" severity failure;
        end if;
        n := n + 1;
      end loop;
    end procedure;
  begin
    wait for 100 ns;
    aresetn <= '1';

    -- Enable the client-0 monitor (data check on).
    wait until rising_edge(aclk);
    mon_enable <= '1';

    -- ---------------------------------------------------------------
    -- Phase A: single-beat request on client 0.  One req, one rsp beat.
    -- ---------------------------------------------------------------
    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"00001000", std_logic_vector(to_unsigned(0, C_CLIENT_LEN_WIDTH)));

    rsp_rd(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0), rsp_resp(0),
           rsp_last(0), v_rsp_data, v_rsp_resp, v_rsp_last);
    assert v_rsp_resp = "00" and v_rsp_last = '1'
      report "A: client 0 response sideband wrong" severity failure;

    -- Drain the scoreboard.
    wait_count := 0;
    loop
      wait until rising_edge(aclk);
      exit when mon_pipeline = '0';
      wait_count := wait_count + 1;
      assert wait_count < 4000 report "phase A drain timeout" severity failure;
    end loop;

    assert stat_req_seen = x"00000001"
      report "A: req_seen /= 1" severity failure;
    assert stat_xactions = x"00000001"
      report "A: xactions /= 1" severity failure;
    assert stat_beats = x"00000001"
      report "A: beats /= 1" severity failure;
    assert stat_burst_len_min = x"00000001" and stat_burst_len_max = x"00000001"
      report "A: burst length stats wrong" severity failure;
    assert stat_data_errors = x"00000000"
      report "A: data errors on clean traffic" severity failure;
    assert stat_rlast_errors = x"00000000"
      report "A: rlast errors on clean traffic" severity failure;
    assert stat_resp_errors = x"00000000"
      report "A: resp errors on clean traffic" severity failure;
    assert stat_sb_underflow_errors = x"00000000"
      report "A: scoreboard underflow on clean traffic" severity failure;
    assert stat_latency_min /= x"FFFFFFFF"
      report "A: latency_min never set" severity failure;
    assert to_integer(unsigned(stat_latency_max)) > 0
      report "A: latency_max zero" severity failure;

    -- ---------------------------------------------------------------
    -- Phase B: three-beat request on client 0 (len=2).  Three rsp beats.
    -- ---------------------------------------------------------------
    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"00002000", std_logic_vector(to_unsigned(2, C_CLIENT_LEN_WIDTH)));

    for n in 0 to 2 loop
      rsp_rd(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0), rsp_resp(0),
             rsp_last(0), v_rsp_data, v_rsp_resp, v_rsp_last);
      assert v_rsp_resp = "00"
        report "B: client 0 response resp wrong" severity failure;
      if n = 2 then
        assert v_rsp_last = '1'
          report "B: final response not last" severity failure;
      else
        assert v_rsp_last = '0'
          report "B: early response asserted last" severity failure;
      end if;
    end loop;

    wait_count := 0;
    loop
      wait until rising_edge(aclk);
      exit when mon_pipeline = '0';
      wait_count := wait_count + 1;
      assert wait_count < 4000 report "phase B drain timeout" severity failure;
    end loop;

    assert stat_req_seen = x"00000002"
      report "B: req_seen /= 2" severity failure;
    assert stat_xactions = x"00000002"
      report "B: xactions /= 2" severity failure;
    assert stat_beats = x"00000004"
      report "B: beats /= 4" severity failure;
    assert stat_burst_len_min = x"00000001" and stat_burst_len_max = x"00000003"
      report "B: burst length stats wrong" severity failure;
    assert stat_data_errors = x"00000000" and stat_rlast_errors = x"00000000"
       and stat_resp_errors = x"00000000" and stat_sb_underflow_errors = x"00000000"
      report "B: errors on clean traffic" severity failure;

    -- ---------------------------------------------------------------
    -- Phase C: stat_rst / err_rst behavior on the client-0 monitor.
    -- Pulse both and verify counters clear; traffic continues cleanly.
    -- ---------------------------------------------------------------
    wait until falling_edge(aclk);
    mon_stat_rst <= '1';
    mon_err_rst  <= '1';
    wait until rising_edge(aclk);
    mon_stat_rst <= '0';
    mon_err_rst  <= '0';
    wait until rising_edge(aclk);
    assert stat_req_seen = x"00000000"
      report "C: stat_rst did not clear req_seen" severity failure;
    assert stat_xactions = x"00000000" and stat_beats = x"00000000"
      report "C: stat_rst did not clear core stats" severity failure;
    assert stat_latency_min = x"FFFFFFFF"
      report "C: stat_rst did not restore latency_min sentinel" severity failure;
    assert stat_data_errors = x"00000000" and stat_rlast_errors = x"00000000"
      report "C: err_rst did not clear errors" severity failure;

    -- ---------------------------------------------------------------
    -- Phase D: error-injection monitor (hand-driven req/rsp).
    --   Beat 0: wrong data               -> stat_data_errors
    --   Beat 1: bad resp (SLVERR), last  -> stat_resp_errors, completes
    --   Beat 2: spurious rsp_last        -> stat_rlast_errors + underflow
    -- ---------------------------------------------------------------
    wait until falling_edge(aclk);
    err_enable <= '1';
    wait until rising_edge(aclk);
    wait until falling_edge(aclk);
    req_w(aclk, err_req_addr, err_req_len, err_req_valid, err_req_ready,
          x"00001000", x"01");          -- 2 beats

    -- Beat 0: wrong data, OKAY, not last.
    rsp_w(aclk, err_rsp_valid, err_rsp_ready, err_rsp_data, err_rsp_resp,
          err_rsp_last, v_bad_data, "00", '0');

    -- Beat 1: correct data, SLVERR, last.
    v_expected_data := (others => '0');
    for v_word in 0 to C_CLIENT_BYTES/4-1 loop
      v_expected_data(32*v_word+31 downto 32*v_word) :=
        std_logic_vector(to_unsigned(16#1040# + v_word*4, 32));
    end loop;
    rsp_w(aclk, err_rsp_valid, err_rsp_ready, err_rsp_data, err_rsp_resp,
          err_rsp_last, v_expected_data, "10", '1');   -- SLVERR -> resp error

    -- Spurious rsp_last with no scoreboard entry.
    rsp_w(aclk, err_rsp_valid, err_rsp_ready, err_rsp_data, err_rsp_resp,
          err_rsp_last, v_bad_data, "00", '1');

    -- Drain and check.
    wait_count := 0;
    loop
      wait until rising_edge(aclk);
      exit when err_pipeline = '0';
      wait_count := wait_count + 1;
      assert wait_count < 100 report "phase D drain timeout" severity failure;
    end loop;

    assert err_stat_xactions = x"00000001"
      report "D: xactions /= 1" severity failure;
    assert err_stat_beats = x"00000003"
      report "D: beats /= 3" severity failure;
    assert err_stat_data_errors = x"00000001"
      report "D: data_errors /= 1" severity failure;
    assert err_stat_resp_errors = x"00000001"
      report "D: resp_errors /= 1" severity failure;
    assert err_stat_rlast_errors = x"00000001"
      report "D: rlast_errors /= 1" severity failure;
    assert err_stat_sb_underflow_errors = x"00000001"
      report "D: sb_underflow_errors /= 1" severity failure;
    assert err_stat_burst_len_min = x"00000002" and err_stat_burst_len_max = x"00000002"
      report "D: burst length stats wrong" severity failure;

    -- ---------------------------------------------------------------
    -- Phase E: R-side backpressure.  A 5-beat request is held by
    -- deasserting rsp_ready mid-stream; stat_rsp_stall must count the
    -- held cycles and the inter-beat gap must stretch.
    -- ---------------------------------------------------------------
    p_stat_err_rst(aclk, mon_stat_rst, mon_err_rst);

    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"00004000", std_logic_vector(to_unsigned(4, C_CLIENT_LEN_WIDTH)));

    -- Wait for the first response beat to be presented, consume it, then
    -- stall the rest: beat 2 is presented but not accepted, so both the
    -- stall counter and the inter-beat gap are stretched.
    loop
      wait until rising_edge(aclk);
      exit when rsp_valid(0) = '1';
    end loop;
    rsp_rd(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0), rsp_resp(0),
           rsp_last(0), v_rsp_data, v_rsp_resp, v_rsp_last);
    assert v_rsp_resp = "00" and v_rsp_last = '0'
      report "E: first response beat wrong" severity failure;

    rsp_ready(0) <= '0';
    for i in 1 to 30 loop
      wait until rising_edge(aclk);
    end loop;
    rsp_ready(0) <= '1';

    p_rsp_burst(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0),
                rsp_resp(0), rsp_last(0), v_rsp_data, v_rsp_resp,
                v_rsp_last, 4, "E");

    p_drain(aclk, mon_pipeline, "phase E", wait_count);

    assert stat_req_seen = x"00000001"
      report "E: req_seen /= 1" severity failure;
    assert stat_xactions = x"00000001"
      report "E: xactions /= 1" severity failure;
    assert stat_beats = x"00000005"
      report "E: beats /= 5" severity failure;
    assert to_integer(unsigned(stat_rsp_stall)) > 0
      report "E: rsp_stall not counted" severity failure;
    assert to_integer(unsigned(stat_interbeat_gap_max)) > 1
      report "E: backpressure did not stretch the inter-beat gap" severity failure;
    assert stat_burst_len_min = x"00000005" and stat_burst_len_max = x"00000005"
      report "E: burst length stats wrong" severity failure;
    assert stat_data_errors = x"00000000" and stat_rlast_errors = x"00000000"
       and stat_resp_errors = x"00000000" and stat_sb_underflow_errors = x"00000000"
      report "E: errors on backpressured traffic" severity failure;

    -- ---------------------------------------------------------------
    -- Phase F: Req-side backpressure on the hand-driven monitor.  The
    -- bridge's axi_ar_mux live-refills a held req_valid at every grant
    -- edge (line-rate sustain), so a bus-side req stall is inherently a
    -- re-presentation; stat_req_stall is therefore exercised here on the
    -- hand-driven monitor:  err_req_valid high with err_req_ready low for
    -- 30 cycles, then a clean 2-beat transaction.
    -- ---------------------------------------------------------------
    err_stat_rst <= '1';
    err_err_rst  <= '1';
    wait until rising_edge(aclk);
    err_stat_rst <= '0';
    err_err_rst  <= '0';
    wait until rising_edge(aclk);

    err_enable <= '1';
    wait until rising_edge(aclk);

    -- Present a request but hold req_ready low: 30 stall cycles.
    err_req_addr  <= x"00005000";
    err_req_len   <= x"01";          -- 2 beats
    err_req_valid <= '1';
    err_req_ready <= '0';
    for i in 1 to 30 loop
      wait until rising_edge(aclk);
    end loop;

    -- Complete the req handshake, then restore always-accept.
    err_req_ready <= '1';
    wait until rising_edge(aclk);
    err_req_valid <= '0';
    err_req_ready <= '1';

    -- Clean 2-beat response with address-derived data.
    for b in 0 to 1 loop
      v_expected_data := (others => '0');
      for v_word in 0 to C_CLIENT_BYTES/4-1 loop
        v_expected_data(32*v_word+31 downto 32*v_word) :=
          std_logic_vector(to_unsigned(16#5000# + b*64 + v_word*4, 32));
      end loop;
      if b = 1 then
        rsp_w(aclk, err_rsp_valid, err_rsp_ready, err_rsp_data, err_rsp_resp,
              err_rsp_last, v_expected_data, "00", '1');
      else
        rsp_w(aclk, err_rsp_valid, err_rsp_ready, err_rsp_data, err_rsp_resp,
              err_rsp_last, v_expected_data, "00", '0');
      end if;
    end loop;

    wait until rising_edge(aclk);
    assert to_integer(unsigned(err_stat_req_stall)) > 0
      report "F: req_stall not counted" severity failure;
    assert err_stat_req_seen = x"00000001"
      report "F: req_seen /= 1" severity failure;
    assert err_stat_xactions = x"00000001"
      report "F: xactions /= 1" severity failure;
    assert err_stat_beats = x"00000002"
      report "F: beats /= 2" severity failure;
    assert err_stat_data_errors = x"00000000" and err_stat_rlast_errors = x"00000000"
       and err_stat_resp_errors = x"00000000" and err_stat_sb_underflow_errors = x"00000000"
      report "F: errors on backpressured req" severity failure;

    -- ---------------------------------------------------------------
    -- Phase G: Scoreboard backpressure.  A small-FIFO monitor instance
    -- (depth 4) is flooded with 16 one-beat requests while responses are
    -- held; its scoreboard fills and stat_sb_backpressure must count.
    -- ---------------------------------------------------------------
    p_stat_err_rst(aclk, mon_stat_rst, mon_err_rst);

    rsp_ready(0) <= '0';   -- hold responses so no scoreboard pops
    for i in 0 to 15 loop
      req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
            std_logic_vector(to_unsigned(16#6000# + 16#100#*i, 32)),
            std_logic_vector(to_unsigned(0, C_CLIENT_LEN_WIDTH)));
    end loop;

    wait until rising_edge(aclk);
    assert to_integer(unsigned(bp_stat_sb_backpressure)) > 0
      report "G: small monitor never saw scoreboard backpressure"
      severity failure;

    rsp_ready(0) <= '1';
    -- Sixteen one-beat transactions: every beat carries rsp_last.
    for n in 0 to 15 loop
      rsp_rd(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0), rsp_resp(0),
             rsp_last(0), v_rsp_data, v_rsp_resp, v_rsp_last);
      assert v_rsp_resp = "00" and v_rsp_last = '1'
        report "G: client 0 response sideband wrong" severity failure;
    end loop;

    p_drain(aclk, mon_pipeline, "phase G", wait_count);

    assert stat_req_seen = x"00000010"
      report "G: req_seen /= 16" severity failure;
    assert stat_xactions = x"00000010"
      report "G: xactions /= 16" severity failure;
    assert stat_beats = x"00000010"
      report "G: beats /= 16" severity failure;
    assert stat_data_errors = x"00000000" and stat_rlast_errors = x"00000000"
       and stat_resp_errors = x"00000000" and stat_sb_underflow_errors = x"00000000"
      report "G: errors on flooded traffic" severity failure;

    -- ---------------------------------------------------------------
    -- Phase H: Per-instance disable.  With the client-0 monitor off,
    -- traffic flows but all stats stay inert; re-enabling resumes
    -- cleanly with exact accounting.
    -- ---------------------------------------------------------------
    p_stat_err_rst(aclk, mon_stat_rst, mon_err_rst);

    mon_enable <= '0';
    wait until rising_edge(aclk);

    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"00007000", std_logic_vector(to_unsigned(0, C_CLIENT_LEN_WIDTH)));
    p_rsp_burst(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0),
                rsp_resp(0), rsp_last(0), v_rsp_data, v_rsp_resp,
                v_rsp_last, 1, "H0");

    -- Let the pipeline flush while disabled.
    for i in 1 to 50 loop
      wait until rising_edge(aclk);
    end loop;

    assert stat_req_seen = x"00000000" and stat_xactions = x"00000000"
       and stat_beats = x"00000000"
      report "H: disabled monitor counted traffic" severity failure;
    assert stat_data_errors = x"00000000" and stat_sb_underflow_errors = x"00000000"
      report "H: disabled monitor reported errors" severity failure;
    assert mon_pipeline = '0'
      report "H: disabled monitor pipeline not idle" severity failure;

    -- Re-enable and run a clean window.
    mon_enable <= '1';
    p_stat_err_rst(aclk, mon_stat_rst, mon_err_rst);

    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"00007100", std_logic_vector(to_unsigned(1, C_CLIENT_LEN_WIDTH)));
    p_rsp_burst(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0),
                rsp_resp(0), rsp_last(0), v_rsp_data, v_rsp_resp,
                v_rsp_last, 2, "H1");

    p_drain(aclk, mon_pipeline, "phase H", wait_count);

    assert stat_req_seen = x"00000001"
      report "H: re-enabled req_seen /= 1" severity failure;
    assert stat_xactions = x"00000001"
      report "H: re-enabled xactions /= 1" severity failure;
    assert stat_beats = x"00000002"
      report "H: re-enabled beats /= 2" severity failure;
    assert stat_data_errors = x"00000000" and stat_rlast_errors = x"00000000"
       and stat_resp_errors = x"00000000" and stat_sb_underflow_errors = x"00000000"
      report "H: re-enabled monitor reported errors" severity failure;

    -- ---------------------------------------------------------------
    -- Phase I: stat_rst mid-traffic.  A 4-beat request is issued and
    -- stat_rst is pulsed while the response is in flight.  Burst
    -- tracking must survive (the in-flight burst still completes with
    -- exact beats), and a clean window must be exact.
    -- ---------------------------------------------------------------
    p_stat_err_rst(aclk, mon_stat_rst, mon_err_rst);

    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"00008000", std_logic_vector(to_unsigned(3, C_CLIENT_LEN_WIDTH)));

    -- Pulse stat_rst while the response is still in flight.
    wait until rising_edge(aclk);
    mon_stat_rst <= '1';
    wait until rising_edge(aclk);
    mon_stat_rst <= '0';
    wait until rising_edge(aclk);

    p_rsp_burst(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0),
                rsp_resp(0), rsp_last(0), v_rsp_data, v_rsp_resp,
                v_rsp_last, 4, "I");

    p_drain(aclk, mon_pipeline, "phase I", wait_count);

    assert stat_xactions = x"00000001"
      report "I: mid-traffic stat_rst lost the in-flight burst" severity failure;
    assert stat_beats = x"00000004"
      report "I: mid-traffic stat_rst lost beats" severity failure;
    assert stat_burst_len_max = x"00000004"
      report "I: mid-traffic stat_rst corrupted burst tracking" severity failure;
    assert stat_data_errors = x"00000000" and stat_rlast_errors = x"00000000"
       and stat_resp_errors = x"00000000" and stat_sb_underflow_errors = x"00000000"
      report "I: mid-traffic stat_rst caused errors" severity failure;

    -- Clean second window: exact accounting.
    p_stat_err_rst(aclk, mon_stat_rst, mon_err_rst);
    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"00008100", std_logic_vector(to_unsigned(0, C_CLIENT_LEN_WIDTH)));
    p_rsp_burst(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0),
                rsp_resp(0), rsp_last(0), v_rsp_data, v_rsp_resp,
                v_rsp_last, 1, "I clean");
    p_drain(aclk, mon_pipeline, "phase I clean", wait_count);
    assert stat_req_seen = x"00000001"
      report "I: clean window req_seen /= 1" severity failure;
    assert stat_xactions = x"00000001"
      report "I: clean window xactions /= 1" severity failure;
    assert stat_beats = x"00000001"
      report "I: clean window beats /= 1" severity failure;

    -- ---------------------------------------------------------------
    -- Phase J: err_rst coincident with error detection.  A data error
    -- accumulates, then err_rst is pulsed on the same edge a further
    -- wrong-data beat is accepted -- the reset must win.
    -- ---------------------------------------------------------------
    err_stat_rst <= '1';
    err_err_rst  <= '1';
    wait until rising_edge(aclk);
    err_stat_rst <= '0';
    err_err_rst  <= '0';
    wait until rising_edge(aclk);

    err_enable <= '1';
    wait until rising_edge(aclk);

    req_w(aclk, err_req_addr, err_req_len, err_req_valid, err_req_ready,
          x"00001000", x"01");          -- 2 beats

    -- Beat 0: wrong data, OKAY, not last -> data error.
    rsp_w(aclk, err_rsp_valid, err_rsp_ready, err_rsp_data, err_rsp_resp,
          err_rsp_last, v_bad_data, "00", '0');
    wait until rising_edge(aclk);
    assert err_stat_data_errors = x"00000001"
      report "J: data error not detected" severity failure;

    -- Beat 1: wrong data, last, with err_rst asserted on the same edge.
    err_err_rst <= '1';
    rsp_w(aclk, err_rsp_valid, err_rsp_ready, err_rsp_data, err_rsp_resp,
          err_rsp_last, v_bad_data, "00", '1');
    wait until rising_edge(aclk);
    err_err_rst <= '0';
    wait until rising_edge(aclk);

    assert err_stat_data_errors = x"00000000"
      report "J: err_rst did not win over coincident error" severity failure;
    assert err_stat_rlast_errors = x"00000000" and err_stat_resp_errors = x"00000000"
       and err_stat_sb_underflow_errors = x"00000000"
      report "J: unexpected errors after err_rst" severity failure;
    assert err_stat_xactions = x"00000001"
      report "J: xactions /= 1" severity failure;
    assert err_stat_beats = x"00000002"
      report "J: beats /= 2" severity failure;
    assert err_stat_burst_len_min = x"00000002" and err_stat_burst_len_max = x"00000002"
      report "J: burst length stats wrong" severity failure;

    -- ---------------------------------------------------------------
    -- Phase K1: Maximum burst length.  A 32-beat (len=31) request -- the
    -- largest the credit model allows -- completes cleanly end-to-end.
    -- ---------------------------------------------------------------
    p_stat_err_rst(aclk, mon_stat_rst, mon_err_rst);

    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"00009000", std_logic_vector(to_unsigned(31, C_CLIENT_LEN_WIDTH)));
    p_rsp_burst(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0),
                rsp_resp(0), rsp_last(0), v_rsp_data, v_rsp_resp,
                v_rsp_last, 32, "K1");

    p_drain(aclk, mon_pipeline, "phase K1", wait_count);

    assert stat_req_seen = x"00000001"
      report "K1: req_seen /= 1" severity failure;
    assert stat_xactions = x"00000001"
      report "K1: xactions /= 1" severity failure;
    assert stat_beats = x"00000020"
      report "K1: beats /= 32" severity failure;
    assert stat_burst_len_min = x"00000020" and stat_burst_len_max = x"00000020"
      report "K1: burst length stats wrong" severity failure;
    assert stat_data_errors = x"00000000" and stat_rlast_errors = x"00000000"
       and stat_resp_errors = x"00000000" and stat_sb_underflow_errors = x"00000000"
      report "K1: errors on max-length burst" severity failure;

    -- ---------------------------------------------------------------
    -- Phase K2: Mixed burst lengths.  No stat_rst -- accumulates with K1
    -- so the burst-length min/max spread is captured.
    -- ---------------------------------------------------------------
    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"00009100", std_logic_vector(to_unsigned(0, C_CLIENT_LEN_WIDTH)));
    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"00009200", std_logic_vector(to_unsigned(3, C_CLIENT_LEN_WIDTH)));

    p_rsp_burst(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0),
                rsp_resp(0), rsp_last(0), v_rsp_data, v_rsp_resp,
                v_rsp_last, 1, "K2a");
    p_rsp_burst(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0),
                rsp_resp(0), rsp_last(0), v_rsp_data, v_rsp_resp,
                v_rsp_last, 4, "K2b");

    p_drain(aclk, mon_pipeline, "phase K2", wait_count);

    assert stat_req_seen = x"00000003"
      report "K2: req_seen /= 3" severity failure;
    assert stat_xactions = x"00000003"
      report "K2: xactions /= 3" severity failure;
    assert stat_beats = x"00000025"
      report "K2: beats /= 37" severity failure;
    assert stat_burst_len_min = x"00000001" and stat_burst_len_max = x"00000020"
      report "K2: mixed burst length stats wrong" severity failure;
    assert stat_data_errors = x"00000000" and stat_rlast_errors = x"00000000"
       and stat_resp_errors = x"00000000" and stat_sb_underflow_errors = x"00000000"
      report "K2: errors on mixed-length traffic" severity failure;

    -- ---------------------------------------------------------------
    -- Phase L: Stat-accumulator consistency after the K1+K2 window.
    -- min<=max, sum>=max, elapsed-vs-reference, pipeline_busy (seen
    -- high, idle after drain), and max_outstanding.
    -- ---------------------------------------------------------------
    assert busy_high_seen = '1'
      report "L: pipeline_busy never observed high" severity failure;
    assert mon_pipeline = '0'
      report "L: pipeline_busy did not drop after drain" severity failure;
    assert to_integer(unsigned(stat_max_outstanding)) > 0
      report "L: max_outstanding zero" severity failure;
    assert stat_elapsed_cycles = std_logic_vector(mon_elapsed_ref)
      report "L: elapsed cycle counter drifted" severity failure;
    assert unsigned(stat_latency_min) <= unsigned(stat_latency_max) and
           unsigned(stat_latency_sum) >= resize(unsigned(stat_latency_max), C_MON_STAT_WIDTH)
      report "L: latency stat consistency violated" severity failure;
    assert unsigned(stat_first_latency_min) <= unsigned(stat_first_latency_max) and
           unsigned(stat_first_latency_sum) >= resize(unsigned(stat_first_latency_max), C_MON_STAT_WIDTH)
      report "L: first-latency stat consistency violated" severity failure;
    assert unsigned(stat_interbeat_gap_min) <= unsigned(stat_interbeat_gap_max) and
           unsigned(stat_interbeat_gap_sum) >= resize(unsigned(stat_interbeat_gap_max), C_MON_STAT_WIDTH)
      report "L: interbeat-gap stat consistency violated" severity failure;
    assert unsigned(stat_burst_len_min) <= unsigned(stat_burst_len_max) and
           unsigned(stat_burst_len_sum) >= resize(unsigned(stat_burst_len_max), C_MON_STAT_WIDTH)
      report "L: burst-length stat consistency violated" severity failure;

    -- ---------------------------------------------------------------
    -- Phase M: Sustained varied traffic.  Five requests with distinct
    -- addresses, mixed lengths, and idle gaps between some of them.
    -- ---------------------------------------------------------------
    p_stat_err_rst(aclk, mon_stat_rst, mon_err_rst);

    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"0000A000", std_logic_vector(to_unsigned(0, C_CLIENT_LEN_WIDTH)));
    for i in 1 to 3 loop
      wait until rising_edge(aclk);   -- idle gap (pacing)
    end loop;
    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"0000A100", std_logic_vector(to_unsigned(1, C_CLIENT_LEN_WIDTH)));
    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"0000A200", std_logic_vector(to_unsigned(2, C_CLIENT_LEN_WIDTH)));
    for i in 1 to 3 loop
      wait until rising_edge(aclk);
    end loop;
    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"0000A300", std_logic_vector(to_unsigned(0, C_CLIENT_LEN_WIDTH)));
    req_w(aclk, req_addr(0), req_len(0), req_valid(0), req_ready(0),
          x"0000A400", std_logic_vector(to_unsigned(3, C_CLIENT_LEN_WIDTH)));

    p_rsp_burst(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0),
                rsp_resp(0), rsp_last(0), v_rsp_data, v_rsp_resp,
                v_rsp_last, 1, "M1");
    p_rsp_burst(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0),
                rsp_resp(0), rsp_last(0), v_rsp_data, v_rsp_resp,
                v_rsp_last, 2, "M2");
    p_rsp_burst(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0),
                rsp_resp(0), rsp_last(0), v_rsp_data, v_rsp_resp,
                v_rsp_last, 3, "M3");
    p_rsp_burst(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0),
                rsp_resp(0), rsp_last(0), v_rsp_data, v_rsp_resp,
                v_rsp_last, 1, "M4");
    p_rsp_burst(aclk, rsp_ready(0), rsp_valid(0), rsp_data(0),
                rsp_resp(0), rsp_last(0), v_rsp_data, v_rsp_resp,
                v_rsp_last, 4, "M5");

    p_drain(aclk, mon_pipeline, "phase M", wait_count);

    assert stat_req_seen = x"00000005"
      report "M: req_seen /= 5" severity failure;
    assert stat_xactions = x"00000005"
      report "M: xactions /= 5" severity failure;
    assert stat_beats = x"0000000B"
      report "M: beats /= 11" severity failure;
    assert stat_burst_len_min = x"00000001" and stat_burst_len_max = x"00000004"
      report "M: burst length stats wrong" severity failure;
    assert stat_data_errors = x"00000000" and stat_rlast_errors = x"00000000"
       and stat_resp_errors = x"00000000" and stat_sb_underflow_errors = x"00000000"
      report "M: errors on varied traffic" severity failure;

    report "ALL AXI MONITOR CHECKS PASSED" severity note;
    sim_done <= true;
    wait;
  end process;
end architecture sim;
