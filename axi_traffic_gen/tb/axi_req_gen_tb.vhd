-----------------------------------------------------------------------
--Filename         : axi_req_gen_tb.vhd
--Description      : Integration testbench for axi_req_gen.  Drives
--                   axi_req_gen into axi_read_bridge (client side) with
--                   axi_mem_model on the native AXI side, and taps the
--                   bridge client req/rsp with axi_monitor, validating
--                   that generated traffic is tracked end-to-end with
--                   zero false errors.
--
--                   Phases: fixed line-rate linear, paced, random
--                   addressing, random request length, combined random
--                   addressing + random length, response backpressure
--                   (req/rsp stall counting), maximum (32-beat
--                   credit-limited) burst, and stat_rst.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_req_gen_tb is
end entity axi_req_gen_tb;

architecture sim of axi_req_gen_tb is
  constant C_CLIENT_BYTES      : positive := 64;
  constant C_NATIVE_BYTES      : positive := 16;
  constant C_ADDR_WIDTH        : positive := 32;
  constant C_ID_WIDTH          : positive := 4;
  constant C_NUM_CLIENTS       : positive := 1;
  constant C_CLIENT_FIFO_DEPTH : positive := 32;
  constant C_CDC_DEPTH         : positive := 8;
  constant C_GEN_MAX_BURST     : positive := 32;
  constant C_GEN_LEN_WIDTH     : positive := log2ceil(C_GEN_MAX_BURST);  -- 5
  constant C_CLIENT_PERIOD     : time := 10 ns;
  constant C_MEM_PERIOD        : time := 4 ns;
  constant C_TIMEOUT           : time := 2 ms;

  constant C_MON_TIME_WIDTH : positive := 48;
  constant C_MON_STAT_WIDTH : positive := 48;
  constant C_MON_SB_DEPTH   : positive := 64;

  signal aclk : std_logic := '0';
  signal mem_aclk    : std_logic := '0';
  signal aresetn     : std_logic := '0';
  signal sim_done    : boolean := false;

  signal global_time : unsigned(C_MON_TIME_WIDTH-1 downto 0) := (others => '0');

  -- Bridge client interface (single client driven by the generator)
  signal req_addr : slv_array_t(0 to C_NUM_CLIENTS-1)(C_ADDR_WIDTH-1 downto 0);
  signal req_len  : slv_array_t(0 to C_NUM_CLIENTS-1)(5 downto 0);
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

  -- Request generator
  signal gen_enable     : std_logic := '0';
  signal gen_aperture   : std_logic := '0';
  signal gen_stat_rst   : std_logic := '0';
  signal cfg_req_len    : std_logic_vector(C_GEN_LEN_WIDTH-1 downto 0) := (others => '0');
  signal cfg_len_mode   : std_logic := '0';
  signal cfg_max_len    : std_logic_vector(C_GEN_LEN_WIDTH-1 downto 0) := (others => '0');
  signal cfg_pace       : std_logic_vector(31 downto 0) := (others => '0');
  signal cfg_pace_init  : std_logic_vector(31 downto 0) := (others => '0');
  signal cfg_base_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal cfg_addr_range : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal cfg_addr_mode  : std_logic := '0';
  signal gen_req_valid       : std_logic;
  signal gen_req_ready       : std_logic;
  signal gen_req_addr        : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal gen_req_len         : std_logic_vector(C_GEN_LEN_WIDTH-1 downto 0);
  signal gen_stat_req_stall  : std_logic_vector(31 downto 0);
  signal gen_stat_req_issued : std_logic_vector(31 downto 0);
  signal gen_stat_cfg_errors : std_logic_vector(31 downto 0);

  -- Monitor (taps the bridge client req/rsp)
  signal mon_enable     : std_logic := '1';
  signal mon_stat_rst   : std_logic := '0';
  signal mon_err_rst    : std_logic := '0';
  signal mon_data_check : std_logic := '1';
  signal mon_pipeline : std_logic;
  signal mon_req_len8 : std_logic_vector(7 downto 0);

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

  -- Address-variation tracker: counts transitions between consecutive
  -- accepted request addresses (proves random addressing varies).
  signal addr_changes : natural := 0;
  signal addr_var_rst : std_logic := '0';

  -- Reference for stat_elapsed_cycles (increments while the monitor is
  -- enabled, cleared by mon_stat_rst - mirrors the RTL counter).
  signal mon_elapsed_ref : unsigned(31 downto 0) := (others => '0');
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
      report "axi_req_gen_tb watchdog timeout" severity failure;
    end if;
    wait;
  end process;

  -- Request generator drives bridge client 0 (zero-extend the 5-bit
  -- req_len to the bridge's 6-bit port).
  req_addr(0)  <= gen_req_addr;
  req_len(0)   <= '0' & gen_req_len;
  req_valid(0) <= gen_req_valid;
  gen_req_ready <= req_ready(0);

  u_gen : entity work.axi_req_gen
    generic map (
      GC_DATA_BYTES => C_CLIENT_BYTES,
      GC_ADDR_WIDTH => C_ADDR_WIDTH,
      GC_MAX_BURST  => C_GEN_MAX_BURST
    )
    port map (
      aclk            => aclk,
      aresetn         => aresetn,
      enable          => gen_enable,
      aperture        => gen_aperture,
      stat_rst        => gen_stat_rst,
      cfg_req_len     => cfg_req_len,
      cfg_len_mode    => cfg_len_mode,
      cfg_max_len     => cfg_max_len,
      cfg_pace        => cfg_pace,
      cfg_pace_init   => cfg_pace_init,
      cfg_base_addr   => cfg_base_addr,
      cfg_addr_range  => cfg_addr_range,
      cfg_addr_mode   => cfg_addr_mode,
      req_valid       => gen_req_valid,
      req_ready       => gen_req_ready,
      req_addr        => gen_req_addr,
      req_len         => gen_req_len,
      stat_req_stall  => gen_stat_req_stall,
      stat_req_issued => gen_stat_req_issued,
      stat_cfg_errors => gen_stat_cfg_errors
    );

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
      ar_size     => ar_size,
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
      aclk             => mem_aclk,
      aresetn          => aresetn,
      ar_base_enable   => '0',
      ar_jitter_enable => '0',
      r_base_enable    => '0',
      r_jitter_enable  => '0',
      base_latency     => (others => '0'),
      base_beat_gap    => (others => '0'),
      ar_id            => ar_id,
      ar_addr          => ar_addr,
      ar_len           => ar_len,
      ar_valid         => ar_valid,
      ar_ready         => ar_ready,
      r_id             => r_id,
      r_data           => r_data,
      r_resp           => r_resp,
      r_last           => r_last,
      r_valid          => r_valid,
      r_ready          => r_ready
    );

  -- Monitor taps the bridge client req/rsp (client 0).
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
      aclk                     => aclk,
      aresetn                  => aresetn,
      global_time              => global_time,
      enable                   => mon_enable,
      stat_rst                 => mon_stat_rst,
      err_rst                  => mon_err_rst,
      data_check_en            => mon_data_check,
      pipeline_busy            => mon_pipeline,
      req_valid                => req_valid(0),
      req_ready                => req_ready(0),
      req_addr                 => req_addr(0),
      req_len                  => mon_req_len8,
      rsp_valid                => rsp_valid(0),
      rsp_ready                => rsp_ready(0),
      rsp_data                 => rsp_data(0),
      rsp_resp                 => rsp_resp(0),
      rsp_last                 => rsp_last(0),
      stat_req_seen            => stat_req_seen,
      stat_req_stall           => stat_req_stall,
      stat_sb_backpressure     => stat_sb_backpressure,
      stat_xactions            => stat_xactions,
      stat_beats               => stat_beats,
      stat_latency_sum         => stat_latency_sum,
      stat_latency_min         => stat_latency_min,
      stat_latency_max         => stat_latency_max,
      stat_first_latency_sum   => stat_first_latency_sum,
      stat_first_latency_min   => stat_first_latency_min,
      stat_first_latency_max   => stat_first_latency_max,
      stat_interbeat_gap_sum   => stat_interbeat_gap_sum,
      stat_interbeat_gap_min   => stat_interbeat_gap_min,
      stat_interbeat_gap_max   => stat_interbeat_gap_max,
      stat_burst_len_sum       => stat_burst_len_sum,
      stat_burst_len_min       => stat_burst_len_min,
      stat_burst_len_max       => stat_burst_len_max,
      stat_elapsed_cycles      => stat_elapsed_cycles,
      stat_rsp_stall           => stat_rsp_stall,
      stat_max_outstanding     => stat_max_outstanding,
      stat_data_errors         => stat_data_errors,
      stat_rlast_errors        => stat_rlast_errors,
      stat_resp_errors         => stat_resp_errors,
      stat_sb_underflow_errors => stat_sb_underflow_errors
    );

  -- Check every accepted request: start aligned to C_CLIENT_BYTES and
  -- the full burst inside [base, base+range].
  p_addr_check : process(aclk)
    variable burst_bytes : natural;
  begin
    if rising_edge(aclk) and aresetn = '1' and
       req_valid(0) = '1' and req_ready(0) = '1' then
      assert unsigned(req_addr(0)(log2ceil(C_CLIENT_BYTES)-1 downto 0)) = 0
        report "req addr not aligned to client bytes" severity failure;
      burst_bytes := (to_integer(unsigned(req_len(0))) + 1) * C_CLIENT_BYTES;
      assert unsigned(req_addr(0)) >= unsigned(cfg_base_addr) and
             unsigned(req_addr(0)) + burst_bytes <=
             unsigned(cfg_base_addr) + unsigned(cfg_addr_range)
        report "req burst outside address window" severity failure;
    end if;
  end process;

  -- Count transitions between consecutive accepted request addresses.
  -- Cleared by addr_var_rst (pulsed by p_reset_stats); proves random
  -- addressing actually varies the presented addresses.
  p_addr_var : process(aclk)
    variable prev_addr : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
    variable have_prev : boolean := false;
  begin
    if rising_edge(aclk) then
      if aresetn = '0' or addr_var_rst = '1' then
        addr_changes <= 0;
        prev_addr    := (others => '0');
        have_prev    := false;
      elsif req_valid(0) = '1' and req_ready(0) = '1' then
        if have_prev and req_addr(0) /= prev_addr then
          addr_changes <= addr_changes + 1;
        end if;
        prev_addr := req_addr(0);
        have_prev := true;
      end if;
    end if;
  end process;

  -- Reference counter for stat_elapsed_cycles: increments while the
  -- client-0 monitor is enabled, cleared by mon_stat_rst (same as RTL).
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

  p_stim : process
    variable wait_count : natural;

    -- Pulse the generator and monitor soft resets.
    procedure p_reset_stats is
    begin
      wait until falling_edge(aclk);
      gen_stat_rst <= '1';
      mon_stat_rst <= '1';
      mon_err_rst  <= '1';
      addr_var_rst <= '1';
      wait until rising_edge(aclk);
      wait for 1 ns;
      gen_stat_rst <= '0';
      mon_stat_rst <= '0';
      mon_err_rst  <= '0';
      addr_var_rst <= '0';
      wait until rising_edge(aclk);
      wait for 1 ns;
    end procedure;

    -- Wait until the monitor pipeline drains (scoreboard empty).
    procedure p_drain(
      constant tag : in string
    ) is
      variable waited : natural := 0;
    begin
      waited := 0;
      loop
        wait until rising_edge(aclk);
        wait for 1 ns;
        exit when mon_pipeline = '0';
        waited := waited + 1;
        assert waited < 500000
          report "drain timeout: " & tag severity failure;
      end loop;
    end procedure;

    -- Assert clean traffic: no monitor errors, no scoreboard
    -- backpressure, no generator cfg errors.
    procedure p_check_clean(
      constant tag : in string
    ) is
    begin
      assert stat_data_errors = x"00000000" and
             stat_rlast_errors = x"00000000" and
             stat_resp_errors  = x"00000000" and
             stat_sb_underflow_errors = x"00000000"
        report tag & ": monitor errors on traffic" severity failure;
      assert stat_sb_backpressure = x"00000000"
        report tag & ": scoreboard backpressure" severity failure;
      assert gen_stat_cfg_errors = x"00000000"
        report tag & ": generator cfg errors" severity failure;
    end procedure;

    -- Assert the full stat audit: clean traffic (errors, backpressure,
    -- cfg errors) plus every stat counter behaving correctly:
    --   - generator and monitor req_stall cross-check (same bus tap)
    --   - stat_elapsed_cycles vs the reference counter
    --   - stat_burst_len_sum == stat_beats (no underflow beats)
    --   - min <= max and sum >= max for the latency / first-latency /
    --     interbeat-gap / burst-length accumulator groups
    --   - interbeat gap >= 1, latency_min set, max_outstanding > 0
    -- Optional check_stall also asserts the req_stall counters counted
    -- (guaranteed at line rate, not necessarily under pacing).
    -- NOTE: only valid in a clean window (no stat_rst mid-burst, which
    -- would break burst_len_sum == beats for a straddling burst).
    procedure p_check_stats(
      constant tag         : in string;
      constant check_stall : in boolean
    ) is
    begin
      p_check_clean(tag);

      assert gen_stat_req_stall = stat_req_stall
        report tag & ": gen/monitor req_stall diverged" severity failure;
      assert stat_elapsed_cycles = std_logic_vector(mon_elapsed_ref)
        report tag & ": elapsed counter drifted" severity failure;
      assert unsigned(stat_burst_len_sum) =
             resize(unsigned(stat_beats), C_MON_STAT_WIDTH)
        report tag & ": burst_len_sum != beats" severity failure;
      assert unsigned(stat_latency_min) <= unsigned(stat_latency_max) and
             unsigned(stat_latency_sum) >= resize(unsigned(stat_latency_max), C_MON_STAT_WIDTH)
        report tag & ": latency stats inconsistent" severity failure;
      assert unsigned(stat_first_latency_min) <= unsigned(stat_first_latency_max) and
             unsigned(stat_first_latency_sum) >= resize(unsigned(stat_first_latency_max), C_MON_STAT_WIDTH)
        report tag & ": first-latency stats inconsistent" severity failure;
      assert unsigned(stat_interbeat_gap_min) >= 1 and
             unsigned(stat_interbeat_gap_min) <= unsigned(stat_interbeat_gap_max) and
             unsigned(stat_interbeat_gap_sum) >= resize(unsigned(stat_interbeat_gap_max), C_MON_STAT_WIDTH)
        report tag & ": interbeat-gap stats inconsistent" severity failure;
      assert unsigned(stat_burst_len_min) <= unsigned(stat_burst_len_max) and
             unsigned(stat_burst_len_sum) >= resize(unsigned(stat_burst_len_max), C_MON_STAT_WIDTH)
        report tag & ": burst-length stats inconsistent" severity failure;
      assert stat_latency_min /= x"FFFFFFFF"
        report tag & ": latency_min never set" severity failure;
      assert to_integer(unsigned(stat_max_outstanding)) > 0
        report tag & ": max_outstanding zero" severity failure;
      if check_stall then
        assert unsigned(gen_stat_req_stall) > 0
          report tag & ": generator req_stall not counted" severity failure;
        assert unsigned(stat_req_stall) > 0
          report tag & ": monitor req_stall not counted" severity failure;
      end if;
    end procedure;
  begin
    wait for 100 ns;
    aresetn <= '1';

    -- Generator defaults (fixed 4-beat bursts).
    cfg_req_len    <= std_logic_vector(to_unsigned(3, C_GEN_LEN_WIDTH));
    cfg_len_mode   <= '0';
    cfg_max_len    <= std_logic_vector(to_unsigned(15, C_GEN_LEN_WIDTH));
    cfg_pace       <= x"00000000";
    cfg_pace_init  <= x"00000000";
    cfg_base_addr  <= x"00001000";
    cfg_addr_range <= x"00008000";
    cfg_addr_mode  <= '0';

    wait until rising_edge(aclk);
    gen_aperture <= '1';

    -- ---------------------------------------------------------------
    -- Phase 1: fixed 4-beat bursts, line rate, linear addressing.
    -- ---------------------------------------------------------------
    p_reset_stats;
    gen_enable <= '1';
    for i in 1 to 1500 loop
      wait until rising_edge(aclk);
    end loop;
    gen_enable <= '0';
    p_drain("phase 1");
    p_check_stats("P1", true);

    assert unsigned(gen_stat_req_issued) > 50
      report "P1: traffic volume too low" severity failure;
    assert stat_req_seen = gen_stat_req_issued
      report "P1: monitor req_seen != generator issued" severity failure;
    assert stat_xactions = stat_req_seen
      report "P1: xactions != req_seen" severity failure;
    assert stat_beats = std_logic_vector(resize(unsigned(stat_xactions) * 4, 32))
      report "P1: beats != xactions*4" severity failure;
    assert stat_burst_len_min = x"00000004" and stat_burst_len_max = x"00000004"
      report "P1: burst length stats wrong" severity failure;

    -- ---------------------------------------------------------------
    -- Phase 2: paced generation (cfg_pace=2).
    -- ---------------------------------------------------------------
    p_reset_stats;
    cfg_pace <= x"00000002";
    gen_enable <= '1';
    for i in 1 to 2000 loop
      wait until rising_edge(aclk);
    end loop;
    gen_enable <= '0';
    p_drain("phase 2");
    p_check_stats("P2", false);

    assert unsigned(gen_stat_req_issued) > 0
      report "P2: no requests issued" severity failure;
    assert stat_req_seen = gen_stat_req_issued
      report "P2: monitor req_seen != generator issued" severity failure;
    assert stat_xactions = stat_req_seen
      report "P2: xactions != req_seen" severity failure;
    assert stat_beats = std_logic_vector(resize(unsigned(stat_xactions) * 4, 32))
      report "P2: beats != xactions*4" severity failure;
    assert stat_burst_len_min = x"00000004" and stat_burst_len_max = x"00000004"
      report "P2: burst length stats wrong" severity failure;

    -- ---------------------------------------------------------------
    -- Phase 3: random addressing (cfg_addr_mode=1, range is a power
    -- of two).
    -- ---------------------------------------------------------------
    p_reset_stats;
    cfg_pace      <= x"00000000";
    cfg_addr_mode <= '1';
    gen_enable <= '1';
    for i in 1 to 1500 loop
      wait until rising_edge(aclk);
    end loop;
    gen_enable <= '0';
    p_drain("phase 3");
    p_check_stats("P3", true);

    assert stat_req_seen = gen_stat_req_issued and
           stat_xactions = stat_req_seen and
           stat_beats = std_logic_vector(resize(unsigned(stat_xactions) * 4, 32))
      report "P3: accounting mismatch" severity failure;
    assert stat_burst_len_min = x"00000004" and stat_burst_len_max = x"00000004"
      report "P3: burst length stats wrong" severity failure;
    assert addr_changes > 50
      report "P3: random addressing never varied addresses" severity failure;

    -- ---------------------------------------------------------------
    -- Phase 4: random request length (cfg_len_mode=1, max 16 beats).
    -- ---------------------------------------------------------------
    p_reset_stats;
    cfg_addr_mode <= '0';
    cfg_len_mode  <= '1';
    cfg_max_len   <= std_logic_vector(to_unsigned(15, C_GEN_LEN_WIDTH));
    gen_enable <= '1';
    for i in 1 to 2000 loop
      wait until rising_edge(aclk);
    end loop;
    gen_enable <= '0';
    p_drain("phase 4");
    p_check_stats("P4", true);

    assert stat_req_seen = gen_stat_req_issued
      report "P4: monitor req_seen != generator issued" severity failure;
    assert stat_xactions = stat_req_seen
      report "P4: xactions != req_seen" severity failure;
    assert unsigned(stat_beats) >= unsigned(stat_xactions)
      report "P4: beats < xactions" severity failure;
    assert unsigned(stat_burst_len_min) >= 1 and
           unsigned(stat_burst_len_max) <= 16
      report "P4: random length out of bounds" severity failure;
    assert unsigned(stat_burst_len_min) < unsigned(stat_burst_len_max)
      report "P4: random length never varied" severity failure;

    -- ---------------------------------------------------------------
    -- Phase 4B: combined random modes - random addressing AND random
    -- request length together.  Both PRNGs step together and every
    -- variable-length burst is fitted to a random address; the
    -- p_addr_check process validates alignment and window fit for each
    -- accepted request.
    -- ---------------------------------------------------------------
    p_reset_stats;
    cfg_addr_mode <= '1';
    cfg_len_mode  <= '1';
    cfg_max_len   <= std_logic_vector(to_unsigned(15, C_GEN_LEN_WIDTH));
    gen_enable <= '1';
    for i in 1 to 2000 loop
      wait until rising_edge(aclk);
    end loop;
    gen_enable <= '0';
    p_drain("phase 4B");
    p_check_stats("P4B", true);

    assert stat_req_seen = gen_stat_req_issued
      report "P4B: monitor req_seen != generator issued" severity failure;
    assert stat_xactions = stat_req_seen
      report "P4B: xactions != req_seen" severity failure;
    assert unsigned(stat_beats) >= unsigned(stat_xactions)
      report "P4B: beats < xactions" severity failure;
    assert unsigned(stat_burst_len_min) >= 1 and
           unsigned(stat_burst_len_max) <= 16
      report "P4B: random length out of bounds" severity failure;
    assert unsigned(stat_burst_len_min) < unsigned(stat_burst_len_max)
      report "P4B: random length never varied" severity failure;
    assert addr_changes > 50
      report "P4B: random addressing never varied addresses" severity failure;

    -- ---------------------------------------------------------------
    -- Phase 5: response backpressure.  Hold rsp_ready low while the
    -- generator runs: the bridge backpressures, the generator stalls
    -- (req_stall), and the monitor counts both req and rsp stalls.
    -- ---------------------------------------------------------------
    p_reset_stats;
    cfg_len_mode <= '0';
    cfg_req_len  <= std_logic_vector(to_unsigned(3, C_GEN_LEN_WIDTH));
    gen_enable <= '1';
    for i in 1 to 100 loop
      wait until rising_edge(aclk);
    end loop;
    rsp_ready(0) <= '0';              -- apply response backpressure
    for i in 1 to 200 loop
      wait until rising_edge(aclk);
    end loop;
    rsp_ready(0) <= '1';              -- release
    for i in 1 to 300 loop
      wait until rising_edge(aclk);
    end loop;
    gen_enable <= '0';
    p_drain("phase 5");
    p_check_stats("P5", false);

    assert unsigned(gen_stat_req_stall) > 0
      report "P5: generator req_stall not counted" severity failure;
    assert unsigned(stat_req_stall) > 0
      report "P5: monitor req_stall not counted" severity failure;
    assert unsigned(stat_rsp_stall) > 0
      report "P5: monitor rsp_stall not counted" severity failure;
    assert stat_req_seen = gen_stat_req_issued and
           stat_xactions = stat_req_seen
      report "P5: accounting mismatch under backpressure" severity failure;

    -- ---------------------------------------------------------------
    -- Phase 6: maximum burst length (32 beats, credit-limited).
    -- ---------------------------------------------------------------
    p_reset_stats;
    cfg_req_len <= std_logic_vector(to_unsigned(31, C_GEN_LEN_WIDTH));
    gen_enable <= '1';
    for i in 1 to 1000 loop
      wait until rising_edge(aclk);
    end loop;
    gen_enable <= '0';
    p_drain("phase 6");
    p_check_stats("P6", true);

    assert unsigned(gen_stat_req_issued) > 5
      report "P6: traffic volume too low" severity failure;
    assert stat_req_seen = gen_stat_req_issued and
           stat_xactions = stat_req_seen
      report "P6: accounting mismatch" severity failure;
    assert stat_beats = std_logic_vector(resize(unsigned(stat_xactions) * 32, 32))
      report "P6: beats != xactions*32" severity failure;
    assert stat_burst_len_min = x"00000020" and stat_burst_len_max = x"00000020"
      report "P6: burst length stats wrong" severity failure;

    -- ---------------------------------------------------------------
    -- Phase 7: stat_rst mid-traffic clears the generator and monitor
    -- counters without corrupting in-flight tracking; a clean second
    -- window has exact accounting.
    -- ---------------------------------------------------------------
    p_reset_stats;
    cfg_req_len <= std_logic_vector(to_unsigned(3, C_GEN_LEN_WIDTH));
    gen_enable <= '1';
    for i in 1 to 200 loop
      wait until rising_edge(aclk);
    end loop;
    p_reset_stats;                     -- clear mid-traffic
    for i in 1 to 200 loop
      wait until rising_edge(aclk);
    end loop;
    gen_enable <= '0';
    p_drain("phase 7");
    p_check_clean("P7");

    -- Clean second window: exact accounting.
    p_reset_stats;
    gen_enable <= '1';
    for i in 1 to 300 loop
      wait until rising_edge(aclk);
    end loop;
    gen_enable <= '0';
    p_drain("phase 7 clean");
    p_check_stats("P7 clean", true);
    assert stat_req_seen = gen_stat_req_issued and
           stat_xactions = stat_req_seen and
           stat_beats = std_logic_vector(resize(unsigned(stat_xactions) * 4, 32))
      report "P7: clean window accounting mismatch" severity failure;

    report "ALL REQ GEN INTEGRATION CHECKS PASSED" severity note;
    sim_done <= true;
    wait;
  end process;
end architecture sim;
