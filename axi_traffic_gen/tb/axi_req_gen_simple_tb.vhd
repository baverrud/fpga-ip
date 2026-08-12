-----------------------------------------------------------------------
--Filename         : axi_req_gen_simple_tb.vhd
--Description      : Simple, hand-editable testbench for axi_req_gen.
--                   Instantiates the full integration chain like
--                   axi_req_gen_tb:  axi_req_gen -> axi_read_bridge ->
--                   axi_mem_model, with axi_monitor tapping the bridge
--                   client req/rsp.  Uses plain signal initialization
--                   (defaults in the declarations) so tests can be added
--                   by editing the sequencer process.  The sequencer is
--                   left as a skeleton -- initial values are set, then
--                   it runs a short smoke window and waits for you to
--                   add your own stimulus.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity axi_req_gen_simple_tb is
end entity;

architecture sim of axi_req_gen_simple_tb is
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

  signal client_aclk : std_logic := '0';
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

  -- Request generator control/config -- initial values
  signal gen_enable   : std_logic := '0';
  signal gen_aperture : std_logic := '1';
  signal gen_stat_rst : std_logic := '0';
  signal cfg_req_len  : std_logic_vector(C_GEN_LEN_WIDTH-1 downto 0) :=
                          std_logic_vector(to_unsigned(3, C_GEN_LEN_WIDTH));  -- 4 beats
  signal cfg_len_mode : std_logic := '0';                                 -- fixed length
  signal cfg_max_len  : std_logic_vector(C_GEN_LEN_WIDTH-1 downto 0) :=
                          std_logic_vector(to_unsigned(15, C_GEN_LEN_WIDTH));
  signal cfg_pace      : std_logic_vector(31 downto 0) := x"00000000";  -- every cycle
  signal cfg_pace_init : std_logic_vector(31 downto 0) := x"00000000";
  signal cfg_base_addr : std_logic_vector(C_ADDR_WIDTH-1 downto 0) :=
                          std_logic_vector(to_unsigned(16#1000#, C_ADDR_WIDTH));
  signal cfg_addr_range : std_logic_vector(C_ADDR_WIDTH-1 downto 0) :=
                          std_logic_vector(to_unsigned(16#8000#, C_ADDR_WIDTH));
  signal cfg_addr_mode : std_logic := '0';  -- linear

  -- Generator output / statistics
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

  procedure wait_cycles(n : natural) is
  begin
    for i in 1 to n loop
      wait until rising_edge(client_aclk);
    end loop;
  end procedure;

begin

  p_client_clk : process
  begin
    client_aclk <= '0';
    while not sim_done loop
      wait for C_CLIENT_PERIOD / 2;
      client_aclk <= not client_aclk;
    end loop;
    client_aclk <= '0';
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

  p_time : process(client_aclk)
  begin
    if rising_edge(client_aclk) then
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
      report "axi_req_gen_simple_tb watchdog timeout" severity failure;
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
      aclk            => client_aclk,
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
      client_aclk => client_aclk,
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
      aclk                     => client_aclk,
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
  p_addr_check : process(client_aclk)
    variable burst_bytes : natural;
  begin
    if rising_edge(client_aclk) and aresetn = '1' and
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

  ---------------------------------------------------------------------
  -- Sequencer -- edit here to add tests.  Initial values are set in the
  -- declarations above; this block just applies reset and runs a short
  -- smoke window, then stops.
  ---------------------------------------------------------------------
  p_seq : process
    variable l : line;
  begin
    -- Reset
    aresetn        <= '0';
    gen_enable     <= '0';
    gen_aperture   <= '0';
    gen_stat_rst   <= '0';
    mon_stat_rst   <= '0';
    mon_err_rst    <= '0';
    rsp_ready(0)   <= '1';
    wait_cycles(4);
    aresetn <= '1';
    wait_cycles(4);

    -- Smoke window: run the generator for a few cycles, then stop.
    -- NOTE: add your own stimulus / monitor checks below.
    gen_aperture <= '1';
    gen_enable   <= '1';
    wait_cycles(64);
    gen_enable   <= '0';

    wait_cycles(16);
    std.env.stop;
    sim_done <= true;
    wait;
  end process p_seq;

end architecture;
