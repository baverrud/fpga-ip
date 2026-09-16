-----------------------------------------------------------------------
--Filename         : axi_read_tester.vhd
--Description      : Synthesizable multi-client AXI read-path tester.
--                 :  - One shared axi_read_bridge to the native AXI read
--                 :    master (ar/r) interface.
--                 :  - One client slice per GC_NUM_CLIENTS:
--                 :      * axi_req_gen  - generates client read requests.
--                 :      * axi_monitor  - passively taps req/rsp and
--                 :                       accumulates statistics.
--                 :      * axilite_io   - AXI4-Lite config/status registers
--                 :                       (o_data drives the generator and
--                 :                       monitor control; i_data returns
--                 :                       their statistics).
--                 :  - aperture, stat_rst and err_rst are per-client EXTERNAL
--                 :    inputs; global_time is a shared EXTERNAL input - so an
--                 :    array of these testers can share common control and
--                 :    timing signals instead of register bits.
--                 :
--                 : Per-client register map (see README for the full table):
--                 :   o_data[0] : enable (bit 0)
--                 :   o_data[1] : mon_enable (bit 0)
--                 :   o_data[2] : data_check_en (bit 0)
--                 :   o_data[3] : cfg_len_mode (bit 0)
--                 :   o_data[4] : cfg_addr_mode (bit 0)
--                 :   o_data[5] : cfg_req_len
--                 :   o_data[6] : cfg_max_len
--                 :   o_data[7] : cfg_pace
--                 :   o_data[8] : cfg_pace_init
--                 :   o_data[9] : cfg_base_addr
--                 :   o_data[10]: cfg_addr_range
--                 :   o_data[11]: LED control (bit 0 -> led output)
--                 :   i_data[0..2]  : req_gen stats (issued, stall, cfg_err)
--                 :   i_data[3..30] : all 24 monitor stats (48-bit sums as
--                 :                   low+high words)
--                 :
--                 : This is a synthesis target (a silicon read-path test /
--                 : diagnostic engine), NOT a simulation testbench.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_tester is
  generic (
    GC_NUM_CLIENTS       : positive := 4;
    GC_ADDR_WIDTH        : positive := 32;
    GC_ID_WIDTH          : positive := 4;
    GC_CLIENT_DATA_BYTES : positive := 64;
    GC_NATIVE_DATA_BYTES : positive := 16;
    GC_NATIVE_ARLEN_WIDTH : positive range 2 to 8 := 8;
    GC_MAX_BURST         : positive := 32;      -- max client beats per burst
    GC_CLIENT_FIFO_DEPTH : positive range 2 to positive'high := 32;
    GC_CDC_DEPTH         : positive range 2 to 1024 := 8;
    GC_SYNC_STAGES       : positive range 2 to 4 := 2;
    GC_MON_SB_DEPTH      : positive := 32;     -- per-client monitor scoreboard depth
    GC_MON_TIME_WIDTH    : positive := 48       -- global_time counter width
  );
  port (
    aclk : in std_logic;
    mem_aclk    : in std_logic;
    aresetn     : in std_logic;

    -- Per-client AXI4-Lite slave (config/status registers)
    s_axi_awaddr  : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(15 downto 0);
    s_axi_awprot  : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(2 downto 0);
    s_axi_awvalid : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_awready : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_wdata   : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
    s_axi_wstrb   : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(3 downto 0);
    s_axi_wvalid  : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_wready  : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_bresp   : out slv_array_t(0 to GC_NUM_CLIENTS-1)(1 downto 0);
    s_axi_bvalid  : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_bready  : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_araddr  : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(15 downto 0);
    s_axi_arprot  : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(2 downto 0);
    s_axi_arvalid : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_arready : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_rdata   : out slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
    s_axi_rresp   : out slv_array_t(0 to GC_NUM_CLIENTS-1)(1 downto 0);
    s_axi_rvalid  : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_rready  : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- Per-client monitor pipeline-busy status (0 = idle/drained)
    pipeline_busy : out std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- One LED bit per client, controlled by that client's axilite_io
    led : out std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- Global external control for all client slices.
    aperture : in std_logic;  -- measurement window
    stat_rst : in std_logic;  -- clears statistics
    err_rst  : in std_logic;  -- clears monitor error counters

    -- Shared global time reference (feeds the monitor latency statistics)
    global_time : in unsigned(GC_MON_TIME_WIDTH-1 downto 0);

    -- Native AXI read master (connect to the downstream AXI read slave)
    ar_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : out std_logic_vector(GC_NATIVE_ARLEN_WIDTH-1 downto 0);
    ar_valid : out std_logic;
    ar_ready : in  std_logic;
    r_id     : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data   : in  std_logic_vector(8*GC_NATIVE_DATA_BYTES-1 downto 0);
    r_resp   : in  std_logic_vector(1 downto 0);
    r_last   : in  std_logic;
    r_valid  : in  std_logic;
    r_ready  : out std_logic
  );
end entity axi_read_tester;

architecture rtl of axi_read_tester is

  -- Request-length widths.
  constant C_LEN_WIDTH    : positive := log2ceil(GC_MAX_BURST);
  constant C_CLIENT_LEN_W : positive := GC_NATIVE_ARLEN_WIDTH -
                             log2ceil(GC_CLIENT_DATA_BYTES / GC_NATIVE_DATA_BYTES);

  -- Per-client register counts (see header / README register map).
  constant C_NUM_ODATA  : positive := 12;
  constant C_NUM_IDATA  : positive := 32;  -- 3 generator + 28 monitor + busy

  -- Monitor statistics width (axi_monitor GC_STAT_WIDTH): the four *_sum
  -- counters are wider than one 32-bit status word and occupy two.
  constant C_MON_STAT_W : positive := 48;

  -- Bridge client-side request bus.
  signal bridge_req_addr  : slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);
  signal bridge_req_len   : slv_array_t(0 to GC_NUM_CLIENTS-1)(C_CLIENT_LEN_W-1 downto 0);
  signal bridge_req_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal bridge_req_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);

  -- Bridge client-side response bus (consumed only by the monitor taps).
  signal bridge_rsp_data  : slv_array_t(0 to GC_NUM_CLIENTS-1)(8*GC_CLIENT_DATA_BYTES-1 downto 0);
  signal bridge_rsp_resp  : slv_array_t(0 to GC_NUM_CLIENTS-1)(1 downto 0);
  signal bridge_rsp_last  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal bridge_rsp_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal bridge_rsp_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);

  -- Per-client generator request bus.
  signal gen_req_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal gen_req_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal gen_req_addr  : slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);
  signal gen_req_len   : slv_array_t(0 to GC_NUM_CLIENTS-1)(C_LEN_WIDTH-1 downto 0);

  -- Control signals are separate per-client nets between o_data registers
  -- and the request generator or monitor.
  signal enable         : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal mon_enable     : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal data_check_en  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal cfg_len_mode   : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal cfg_addr_mode  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal cfg_req_len    : slv_array_t(0 to GC_NUM_CLIENTS-1)(C_LEN_WIDTH-1 downto 0);
  signal cfg_max_len    : slv_array_t(0 to GC_NUM_CLIENTS-1)(C_LEN_WIDTH-1 downto 0);
  signal cfg_pace       : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal cfg_pace_init  : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal cfg_base_addr  : slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);
  signal cfg_addr_range : slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);

  -- Per-client statistic signals. Separate arrays keep generator and monitor
  -- stat_req_stall ports distinct without record types.
  signal gen_stat_req_stall       : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal gen_stat_req_issued      : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal gen_stat_cfg_errors      : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_req_seen            : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_req_stall           : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_sb_backpressure     : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_xactions            : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_beats               : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_latency_sum         : slv_array_t(0 to GC_NUM_CLIENTS-1)(C_MON_STAT_W-1 downto 0);
  signal stat_latency_min         : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_latency_max         : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_first_latency_sum   : slv_array_t(0 to GC_NUM_CLIENTS-1)(C_MON_STAT_W-1 downto 0);
  signal stat_first_latency_min   : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_first_latency_max   : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_interbeat_gap_sum   : slv_array_t(0 to GC_NUM_CLIENTS-1)(C_MON_STAT_W-1 downto 0);
  signal stat_interbeat_gap_min   : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_interbeat_gap_max   : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_burst_len_sum       : slv_array_t(0 to GC_NUM_CLIENTS-1)(C_MON_STAT_W-1 downto 0);
  signal stat_burst_len_min       : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_burst_len_max       : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_elapsed_cycles      : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal measurement_start_time  : slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_MON_TIME_WIDTH-1 downto 0);
  signal measurement_elapsed     : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal measurement_started     : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal stat_rsp_stall           : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_max_outstanding     : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_data_errors         : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_rlast_errors        : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_resp_errors         : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);
  signal stat_sb_underflow_errors : slv_array_t(0 to GC_NUM_CLIENTS-1)(31 downto 0);

begin

  assert GC_ID_WIDTH >= log2ceil(GC_NUM_CLIENTS)
    report "axi_read_tester: GC_ID_WIDTH cannot encode GC_NUM_CLIENTS clients"
    severity failure;
  assert GC_MAX_BURST <= 2 ** C_CLIENT_LEN_W
    report "axi_read_tester: GC_MAX_BURST exceeds the bridge client len width"
    severity failure;
  assert GC_CLIENT_DATA_BYTES >= GC_NATIVE_DATA_BYTES
    report "axi_read_tester: client data width must be >= native data width"
    severity failure;

  ---------------------------------------------------------------------
  -- Shared client/native read bridge.
  ---------------------------------------------------------------------
  u_bridge : entity work.axi_read_bridge
    generic map (
      GC_NUM_CLIENTS        => GC_NUM_CLIENTS,
      GC_ADDR_WIDTH         => GC_ADDR_WIDTH,
      GC_ID_WIDTH           => GC_ID_WIDTH,
      GC_CLIENT_DATA_BYTES  => GC_CLIENT_DATA_BYTES,
      GC_NATIVE_DATA_BYTES  => GC_NATIVE_DATA_BYTES,
      GC_NATIVE_ARLEN_WIDTH => GC_NATIVE_ARLEN_WIDTH,
      GC_CLIENT_FIFO_DEPTH  => GC_CLIENT_FIFO_DEPTH,
      GC_CDC_DEPTH          => GC_CDC_DEPTH,
      GC_SYNC_STAGES        => GC_SYNC_STAGES
    )
    port map (
      aclk => aclk,
      mem_aclk    => mem_aclk,
      aresetn     => aresetn,
      req_addr  => bridge_req_addr,
      req_len   => bridge_req_len,
      req_valid => bridge_req_valid,
      req_ready => bridge_req_ready,
      rsp_data  => bridge_rsp_data,
      rsp_resp  => bridge_rsp_resp,
      rsp_last  => bridge_rsp_last,
      rsp_valid => bridge_rsp_valid,
      rsp_ready => bridge_rsp_ready,
      ar_id    => ar_id,
      ar_addr  => ar_addr,
      ar_len   => ar_len,
      ar_valid => ar_valid,
      ar_ready => ar_ready,
      r_id     => r_id,
      r_data   => r_data,
      r_resp   => r_resp,
      r_last   => r_last,
      r_valid  => r_valid,
      r_ready  => r_ready
    );

  ---------------------------------------------------------------------
  -- Per-client slice: register interface + request generator + monitor.
  ---------------------------------------------------------------------
  gen_clients : for i in 0 to GC_NUM_CLIENTS-1 generate
    -- These are private axilite_io signals. Each o_data array element is an
    -- individual registered output control word.
    signal o_data : slv_array_t(0 to C_NUM_ODATA-1)(31 downto 0);
    signal i_data : slv_array_t(0 to C_NUM_IDATA-1)(31 downto 0);

    -- Unused stream ports are private tie-offs for this axilite_io instance.
    signal m_axis_tdata_nc  : std_logic_vector(31 downto 0);
    signal m_axis_tvalid_nc : std_logic_vector(0 downto 0);
    signal s_axis_tdata_nc  : slv_array_t(0 to 0)(31 downto 0);
    signal s_axis_tready_nc : std_logic_vector(0 downto 0);
  begin

    -- Decode each separately registered output register into per-client
    -- control signals before connecting the sub-IP ports.
    enable(i)        <= o_data(0)(0);
    mon_enable(i)    <= o_data(1)(0);
    data_check_en(i) <= o_data(2)(0);
    cfg_len_mode(i)  <= o_data(3)(0);
    cfg_addr_mode(i) <= o_data(4)(0);
    cfg_req_len(i)   <= o_data(5)(C_LEN_WIDTH-1 downto 0);
    cfg_max_len(i)   <= o_data(6)(C_LEN_WIDTH-1 downto 0);
    cfg_pace(i)      <= o_data(7);
    cfg_pace_init(i) <= o_data(8);
    cfg_base_addr(i) <= o_data(9)(GC_ADDR_WIDTH-1 downto 0);
    cfg_addr_range(i)<= o_data(10)(GC_ADDR_WIDTH-1 downto 0);
    led(i)           <= o_data(11)(0);

    -- AXI4-Lite config/status register bridge for this client.
    u_axilite : entity work.axilite_io
      generic map (
        GC_NUM_ODATA   => C_NUM_ODATA,
        GC_NUM_IDATA   => C_NUM_IDATA,
        GC_NUM_OSTREAM => 1,
        GC_NUM_ISTREAM => 1
      )
      port map (
        aclk          => aclk,
        aresetn       => aresetn,
        s_axi_awaddr  => s_axi_awaddr(i),
        s_axi_awprot  => s_axi_awprot(i),
        s_axi_awvalid => s_axi_awvalid(i),
        s_axi_awready => s_axi_awready(i),
        s_axi_wdata   => s_axi_wdata(i),
        s_axi_wstrb   => s_axi_wstrb(i),
        s_axi_wvalid  => s_axi_wvalid(i),
        s_axi_wready  => s_axi_wready(i),
        s_axi_bresp   => s_axi_bresp(i),
        s_axi_bvalid  => s_axi_bvalid(i),
        s_axi_bready  => s_axi_bready(i),
        s_axi_araddr  => s_axi_araddr(i),
        s_axi_arprot  => s_axi_arprot(i),
        s_axi_arvalid => s_axi_arvalid(i),
        s_axi_arready => s_axi_arready(i),
        s_axi_rdata   => s_axi_rdata(i),
        s_axi_rresp   => s_axi_rresp(i),
        s_axi_rvalid  => s_axi_rvalid(i),
        s_axi_rready  => s_axi_rready(i),
          o_data        => o_data,
          i_data        => i_data,
        m_axis_tdata  => m_axis_tdata_nc,
        m_axis_tvalid => m_axis_tvalid_nc,
        s_axis_tdata  => s_axis_tdata_nc,
        s_axis_tready => s_axis_tready_nc
      );

    -- Read-request generator for this client.
    u_req_gen : entity work.axi_req_gen
      generic map (
        GC_DATA_BYTES => GC_CLIENT_DATA_BYTES,
        GC_ADDR_WIDTH => GC_ADDR_WIDTH,
        GC_MAX_BURST  => GC_MAX_BURST
      )
      port map (
        aclk    => aclk,
        aresetn => aresetn,
        enable   => enable(i),
        aperture => aperture,
        stat_rst => stat_rst,
        cfg_req_len    => cfg_req_len(i),
        cfg_len_mode   => cfg_len_mode(i),
        cfg_max_len    => cfg_max_len(i),
        cfg_pace       => cfg_pace(i),
        cfg_pace_init  => cfg_pace_init(i),
        cfg_base_addr  => cfg_base_addr(i),
        cfg_addr_range => cfg_addr_range(i),
        cfg_addr_mode  => cfg_addr_mode(i),
        req_valid => gen_req_valid(i),
        req_ready => gen_req_ready(i),
        req_addr  => gen_req_addr(i),
        req_len   => gen_req_len(i),
        stat_req_stall  => gen_stat_req_stall(i),
        stat_req_issued => gen_stat_req_issued(i),
        stat_cfg_errors => gen_stat_cfg_errors(i)
      );

    -- Request/response monitor for this client (passive taps).
    u_monitor : entity work.axi_monitor
      generic map (
        GC_DATA_BYTES    => GC_CLIENT_DATA_BYTES,
        GC_ADDR_WIDTH    => GC_ADDR_WIDTH,
        GC_TIME_WIDTH    => GC_MON_TIME_WIDTH,
        GC_STAT_WIDTH    => 48,
        GC_SB_FIFO_DEPTH => GC_MON_SB_DEPTH
      )
      port map (
        aclk        => aclk,
        aresetn     => aresetn,
        global_time => global_time,
        enable        => mon_enable(i),
        stat_rst      => stat_rst,
        err_rst       => err_rst,
        data_check_en => data_check_en(i),
        pipeline_busy => pipeline_busy(i),
        req_valid => gen_req_valid(i),
        req_ready => gen_req_ready(i),
        req_addr  => gen_req_addr(i),
        req_len   => std_logic_vector(resize(unsigned(gen_req_len(i)), 8)),
        rsp_valid => bridge_rsp_valid(i),
        rsp_ready => bridge_rsp_ready(i),
        rsp_data  => bridge_rsp_data(i),
        rsp_resp  => bridge_rsp_resp(i),
        rsp_last  => bridge_rsp_last(i),
        stat_req_seen            => stat_req_seen(i),
        stat_req_stall           => stat_req_stall(i),
        stat_sb_backpressure     => stat_sb_backpressure(i),
        stat_xactions            => stat_xactions(i),
        stat_beats               => stat_beats(i),
        stat_latency_sum         => stat_latency_sum(i),
        stat_latency_min         => stat_latency_min(i),
        stat_latency_max         => stat_latency_max(i),
        stat_first_latency_sum   => stat_first_latency_sum(i),
        stat_first_latency_min   => stat_first_latency_min(i),
        stat_first_latency_max   => stat_first_latency_max(i),
        stat_interbeat_gap_sum   => stat_interbeat_gap_sum(i),
        stat_interbeat_gap_min   => stat_interbeat_gap_min(i),
        stat_interbeat_gap_max   => stat_interbeat_gap_max(i),
        stat_burst_len_sum       => stat_burst_len_sum(i),
        stat_burst_len_min       => stat_burst_len_min(i),
        stat_burst_len_max       => stat_burst_len_max(i),
        stat_elapsed_cycles      => stat_elapsed_cycles(i),
        stat_rsp_stall           => stat_rsp_stall(i),
        stat_max_outstanding     => stat_max_outstanding(i),
        stat_data_errors         => stat_data_errors(i),
        stat_rlast_errors        => stat_rlast_errors(i),
        stat_resp_errors         => stat_resp_errors(i),
        stat_sb_underflow_errors => stat_sb_underflow_errors(i)
      );

    -- Drive the bridge client request bus from this client's generator.
    bridge_req_addr(i)  <= gen_req_addr(i);
    bridge_req_len(i)   <= std_logic_vector(resize(unsigned(gen_req_len(i)), C_CLIENT_LEN_W));
    bridge_req_valid(i) <= gen_req_valid(i);
    gen_req_ready(i)    <= bridge_req_ready(i);

    -- The read data is consumed only by the monitor tap; always ready so the
    -- bridge presents every response beat for observation.
    bridge_rsp_ready(i) <= '1';

    -- Measure from the shared aperture start until the last accepted
    -- response beat, including any pending-transfer drain after aperture
    -- closes. The monitor's legacy elapsed counter is not aperture-scoped.
    p_measurement_time : process(aclk)
    begin
      if rising_edge(aclk) then
        if aresetn = '0' then
          measurement_start_time(i) <= (others => '0');
          measurement_elapsed(i) <= (others => '0');
          measurement_started(i) <= '0';
        elsif stat_rst = '1' then
          measurement_start_time(i) <= (others => '0');
          measurement_elapsed(i) <= (others => '0');
          measurement_started(i) <= '0';
        else
          if aperture = '1' and measurement_started(i) = '0' then
            measurement_start_time(i) <= std_logic_vector(global_time);
            measurement_elapsed(i) <= (others => '0');
            measurement_started(i) <= '1';
          elsif measurement_started(i) = '1' and
                bridge_rsp_valid(i) = '1' and
                bridge_rsp_ready(i) = '1' then
            measurement_elapsed(i) <= std_logic_vector(resize(
              global_time - unsigned(measurement_start_time(i)), 32));
          end if;
        end if;
      end if;
    end process;

    -- Pack the collected statistics into the status register plane.  The
    -- four 48-bit monitor *_sum counters occupy low + high words.
    i_data(0)  <= gen_stat_req_issued(i);
    i_data(1)  <= gen_stat_req_stall(i);
    i_data(2)  <= gen_stat_cfg_errors(i);
    i_data(3)  <= stat_req_seen(i);
    i_data(4)  <= stat_req_stall(i);
    i_data(5)  <= stat_sb_backpressure(i);
    i_data(6)  <= stat_xactions(i);
    i_data(7)  <= stat_beats(i);
    i_data(8)  <= stat_latency_sum(i)(31 downto 0);
    i_data(9)  <= std_logic_vector(resize(unsigned(
                       stat_latency_sum(i)(C_MON_STAT_W-1 downto 32)), 32));
    i_data(10) <= stat_latency_min(i);
    i_data(11) <= stat_latency_max(i);
    i_data(12) <= stat_first_latency_sum(i)(31 downto 0);
    i_data(13) <= std_logic_vector(resize(unsigned(
                       stat_first_latency_sum(i)(C_MON_STAT_W-1 downto 32)), 32));
    i_data(14) <= stat_first_latency_min(i);
    i_data(15) <= stat_first_latency_max(i);
    i_data(16) <= stat_interbeat_gap_sum(i)(31 downto 0);
    i_data(17) <= std_logic_vector(resize(unsigned(
                       stat_interbeat_gap_sum(i)(C_MON_STAT_W-1 downto 32)), 32));
    i_data(18) <= stat_interbeat_gap_min(i);
    i_data(19) <= stat_interbeat_gap_max(i);
    i_data(20) <= stat_burst_len_sum(i)(31 downto 0);
    i_data(21) <= std_logic_vector(resize(unsigned(
                       stat_burst_len_sum(i)(C_MON_STAT_W-1 downto 32)), 32));
    i_data(22) <= stat_burst_len_min(i);
    i_data(23) <= stat_burst_len_max(i);
    i_data(24) <= measurement_elapsed(i);
    i_data(25) <= stat_rsp_stall(i);
    i_data(26) <= stat_max_outstanding(i);
    i_data(27) <= stat_data_errors(i);
    i_data(28) <= stat_rlast_errors(i);
    i_data(29) <= stat_resp_errors(i);
    i_data(30) <= stat_sb_underflow_errors(i);
    i_data(31) <= (31 downto 1 => '0') & pipeline_busy(i);

  end generate gen_clients;

end architecture rtl;
