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
--                 :   o_data[0] : enable, mon_enable, data_check_en,
--                 :              cfg_len_mode/cfg_addr_mode, cfg_req_len,
--                 :              cfg_max_len (bits 1,2,4,5 reserved)
--                 :   o_data[1] : cfg_pace
--                 :   o_data[2] : cfg_pace_init
--                 :   o_data[3] : cfg_base_addr
--                 :   o_data[4] : cfg_addr_range
--                 :   o_data[5] : LED control (bit 0 -> led output)
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
    s_axi_wdata   : in  slv32_array_t(0 to GC_NUM_CLIENTS-1);
    s_axi_wstrb   : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(3 downto 0);
    s_axi_wvalid  : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_wready  : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_bresp   : out slv2_array_t(0 to GC_NUM_CLIENTS-1);
    s_axi_bvalid  : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_bready  : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_araddr  : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(15 downto 0);
    s_axi_arprot  : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(2 downto 0);
    s_axi_arvalid : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_arready : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_rdata   : out slv32_array_t(0 to GC_NUM_CLIENTS-1);
    s_axi_rresp   : out slv2_array_t(0 to GC_NUM_CLIENTS-1);
    s_axi_rvalid  : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    s_axi_rready  : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- Per-client monitor pipeline-busy status (0 = idle/drained)
    pipeline_busy : out std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- One LED bit per client, controlled by that client's axilite_io
    -- o_data[5] bit 0.
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
  constant C_ODATA      : positive := 6;
  constant C_IDATA      : positive := 31;  -- 3 generator + 28 monitor words

  -- Monitor statistics width (axi_monitor GC_STAT_WIDTH): the four *_sum
  -- counters are wider than one 32-bit status word and occupy two.
  constant C_MON_STAT_W : positive := 48;

  -- Statistics collected per client.  Fields mirror the source port names
  -- (axi_req_gen / axi_monitor outputs); two records keep the generator and
  -- monitor stat_req_stall ports distinct.  The i_data status registers are
  -- packed from these signals below.
  type gen_stat_t is record
    stat_req_stall  : std_logic_vector(31 downto 0);
    stat_req_issued : std_logic_vector(31 downto 0);
    stat_cfg_errors : std_logic_vector(31 downto 0);
  end record;

  type mon_stat_t is record
    stat_req_seen            : std_logic_vector(31 downto 0);
    stat_req_stall           : std_logic_vector(31 downto 0);
    stat_sb_backpressure     : std_logic_vector(31 downto 0);
    stat_xactions            : std_logic_vector(31 downto 0);
    stat_beats               : std_logic_vector(31 downto 0);
    stat_latency_sum         : std_logic_vector(C_MON_STAT_W-1 downto 0);
    stat_latency_min         : std_logic_vector(31 downto 0);
    stat_latency_max         : std_logic_vector(31 downto 0);
    stat_first_latency_sum   : std_logic_vector(C_MON_STAT_W-1 downto 0);
    stat_first_latency_min   : std_logic_vector(31 downto 0);
    stat_first_latency_max   : std_logic_vector(31 downto 0);
    stat_interbeat_gap_sum   : std_logic_vector(C_MON_STAT_W-1 downto 0);
    stat_interbeat_gap_min   : std_logic_vector(31 downto 0);
    stat_interbeat_gap_max   : std_logic_vector(31 downto 0);
    stat_burst_len_sum       : std_logic_vector(C_MON_STAT_W-1 downto 0);
    stat_burst_len_min       : std_logic_vector(31 downto 0);
    stat_burst_len_max       : std_logic_vector(31 downto 0);
    stat_elapsed_cycles      : std_logic_vector(31 downto 0);
    stat_rsp_stall           : std_logic_vector(31 downto 0);
    stat_max_outstanding     : std_logic_vector(31 downto 0);
    stat_data_errors         : std_logic_vector(31 downto 0);
    stat_rlast_errors        : std_logic_vector(31 downto 0);
    stat_resp_errors         : std_logic_vector(31 downto 0);
    stat_sb_underflow_errors : std_logic_vector(31 downto 0);
  end record;

  -- Bridge client-side request bus.
  signal bridge_req_addr  : slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);
  signal bridge_req_len   : slv_array_t(0 to GC_NUM_CLIENTS-1)(C_CLIENT_LEN_W-1 downto 0);
  signal bridge_req_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal bridge_req_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);

  -- Bridge client-side response bus (consumed only by the monitor taps).
  signal bridge_rsp_data  : slv_array_t(0 to GC_NUM_CLIENTS-1)(8*GC_CLIENT_DATA_BYTES-1 downto 0);
  signal bridge_rsp_resp  : slv2_array_t(0 to GC_NUM_CLIENTS-1);
  signal bridge_rsp_last  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal bridge_rsp_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal bridge_rsp_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);

  -- Per-client generator request bus.
  signal gen_req_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal gen_req_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal gen_req_addr  : slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);
  signal gen_req_len   : slv_array_t(0 to GC_NUM_CLIENTS-1)(C_LEN_WIDTH-1 downto 0);

  -- Per-client register planes (axilite_io o_data / i_data).
  type oplane_t is array (0 to GC_NUM_CLIENTS-1) of slv32_array_t(0 to C_ODATA-1);
  signal o_data : oplane_t;
  type iplane_t is array (0 to GC_NUM_CLIENTS-1) of slv32_array_t(0 to C_IDATA-1);
  signal i_data : iplane_t;

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
    -- Unused axilite_io stream ports are tied off. GC_NUM_OSTREAM/ISTREAM is
    -- kept at 1 (not 0): XSim cannot elaborate axilite_io with a null stream
    -- range ("null index range cannot have an index value").
    signal m_axis_tdata_nc  : std_logic_vector(31 downto 0);
    signal m_axis_tvalid_nc : std_logic_vector(0 downto 0);
    signal s_axis_tdata_nc  : slv32_array_t(0 to 0);
    signal s_axis_tready_nc : std_logic_vector(0 downto 0);

    -- Control decoded from the o_data registers (signals mirror the driven
    -- sub-IP port names so no o_data element is wired directly to a port).
    signal enable         : std_logic;
    signal mon_enable     : std_logic;
    signal data_check_en  : std_logic;
    signal cfg_len_mode   : std_logic;
    signal cfg_addr_mode  : std_logic;
    signal cfg_req_len    : std_logic_vector(C_LEN_WIDTH-1 downto 0);
    signal cfg_max_len    : std_logic_vector(C_LEN_WIDTH-1 downto 0);
    signal cfg_pace       : std_logic_vector(31 downto 0);
    signal cfg_pace_init  : std_logic_vector(31 downto 0);
    signal cfg_base_addr  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    signal cfg_addr_range : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);

    -- Statistics collected from the sub-IPs.  Fields mirror the source port
    -- names; the i_data status registers are packed from these below.  Two
    -- records keep the generator and monitor stat_req_stall ports distinct.
    signal gen_stat : gen_stat_t;
    signal mon_stat : mon_stat_t;
  begin

    -- Decode the register plane into per-port control signals.
    enable        <= o_data(i)(0)(0);
    mon_enable    <= o_data(i)(0)(3);
    data_check_en <= o_data(i)(0)(6);
    cfg_len_mode  <= o_data(i)(0)(7);
    cfg_addr_mode <= o_data(i)(0)(8);
    cfg_req_len   <= o_data(i)(0)(9 + C_LEN_WIDTH - 1 downto 9);
    cfg_max_len   <= o_data(i)(0)(9 + 2*C_LEN_WIDTH - 1 downto 9 + C_LEN_WIDTH);
    cfg_pace      <= o_data(i)(1);
    cfg_pace_init <= o_data(i)(2);
    cfg_base_addr <= o_data(i)(3)(31 downto 0);
    cfg_addr_range<= o_data(i)(4)(31 downto 0);

    -- AXI4-Lite config/status register bridge for this client.
    u_axilite : entity work.axilite_io
      generic map (
        GC_NUM_ODATA   => C_ODATA,
        GC_NUM_IDATA   => C_IDATA,
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
        o_data        => o_data(i),
        i_data        => i_data(i),
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
        enable   => enable,
        aperture => aperture,
        stat_rst => stat_rst,
        cfg_req_len    => cfg_req_len,
        cfg_len_mode   => cfg_len_mode,
        cfg_max_len    => cfg_max_len,
        cfg_pace       => cfg_pace,
        cfg_pace_init  => cfg_pace_init,
        cfg_base_addr  => cfg_base_addr,
        cfg_addr_range => cfg_addr_range,
        cfg_addr_mode  => cfg_addr_mode,
        req_valid => gen_req_valid(i),
        req_ready => gen_req_ready(i),
        req_addr  => gen_req_addr(i),
        req_len   => gen_req_len(i),
        stat_req_stall  => gen_stat.stat_req_stall,
        stat_req_issued => gen_stat.stat_req_issued,
        stat_cfg_errors => gen_stat.stat_cfg_errors
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
        enable        => mon_enable,
        stat_rst      => stat_rst,
        err_rst       => err_rst,
        data_check_en => data_check_en,
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
        stat_req_seen            => mon_stat.stat_req_seen,
        stat_req_stall           => mon_stat.stat_req_stall,
        stat_sb_backpressure     => mon_stat.stat_sb_backpressure,
        stat_xactions            => mon_stat.stat_xactions,
        stat_beats               => mon_stat.stat_beats,
        stat_latency_sum         => mon_stat.stat_latency_sum,
        stat_latency_min         => mon_stat.stat_latency_min,
        stat_latency_max         => mon_stat.stat_latency_max,
        stat_first_latency_sum   => mon_stat.stat_first_latency_sum,
        stat_first_latency_min   => mon_stat.stat_first_latency_min,
        stat_first_latency_max   => mon_stat.stat_first_latency_max,
        stat_interbeat_gap_sum   => mon_stat.stat_interbeat_gap_sum,
        stat_interbeat_gap_min   => mon_stat.stat_interbeat_gap_min,
        stat_interbeat_gap_max   => mon_stat.stat_interbeat_gap_max,
        stat_burst_len_sum       => mon_stat.stat_burst_len_sum,
        stat_burst_len_min       => mon_stat.stat_burst_len_min,
        stat_burst_len_max       => mon_stat.stat_burst_len_max,
        stat_elapsed_cycles      => mon_stat.stat_elapsed_cycles,
        stat_rsp_stall           => mon_stat.stat_rsp_stall,
        stat_max_outstanding     => mon_stat.stat_max_outstanding,
        stat_data_errors         => mon_stat.stat_data_errors,
        stat_rlast_errors        => mon_stat.stat_rlast_errors,
        stat_resp_errors         => mon_stat.stat_resp_errors,
        stat_sb_underflow_errors => mon_stat.stat_sb_underflow_errors
      );

    -- Drive the bridge client request bus from this client's generator.
    bridge_req_addr(i)  <= gen_req_addr(i);
    bridge_req_len(i)   <= std_logic_vector(resize(unsigned(gen_req_len(i)), C_CLIENT_LEN_W));
    bridge_req_valid(i) <= gen_req_valid(i);
    gen_req_ready(i)    <= bridge_req_ready(i);

    -- The read data is consumed only by the monitor tap; always ready so the
    -- bridge presents every response beat for observation.
    bridge_rsp_ready(i) <= '1';

    -- LED bit from this client's register plane (o_data[5] bit 0).
    led(i) <= o_data(i)(5)(0);

    -- Pack the collected statistics into the status register plane.  The
    -- four 48-bit monitor *_sum counters occupy low + high words.
    i_data(i)(0)  <= gen_stat.stat_req_issued;
    i_data(i)(1)  <= gen_stat.stat_req_stall;
    i_data(i)(2)  <= gen_stat.stat_cfg_errors;
    i_data(i)(3)  <= mon_stat.stat_req_seen;
    i_data(i)(4)  <= mon_stat.stat_req_stall;
    i_data(i)(5)  <= mon_stat.stat_sb_backpressure;
    i_data(i)(6)  <= mon_stat.stat_xactions;
    i_data(i)(7)  <= mon_stat.stat_beats;
    i_data(i)(8)  <= mon_stat.stat_latency_sum(31 downto 0);
    i_data(i)(9)  <= std_logic_vector(resize(unsigned(
                       mon_stat.stat_latency_sum(C_MON_STAT_W-1 downto 32)), 32));
    i_data(i)(10) <= mon_stat.stat_latency_min;
    i_data(i)(11) <= mon_stat.stat_latency_max;
    i_data(i)(12) <= mon_stat.stat_first_latency_sum(31 downto 0);
    i_data(i)(13) <= std_logic_vector(resize(unsigned(
                       mon_stat.stat_first_latency_sum(C_MON_STAT_W-1 downto 32)), 32));
    i_data(i)(14) <= mon_stat.stat_first_latency_min;
    i_data(i)(15) <= mon_stat.stat_first_latency_max;
    i_data(i)(16) <= mon_stat.stat_interbeat_gap_sum(31 downto 0);
    i_data(i)(17) <= std_logic_vector(resize(unsigned(
                       mon_stat.stat_interbeat_gap_sum(C_MON_STAT_W-1 downto 32)), 32));
    i_data(i)(18) <= mon_stat.stat_interbeat_gap_min;
    i_data(i)(19) <= mon_stat.stat_interbeat_gap_max;
    i_data(i)(20) <= mon_stat.stat_burst_len_sum(31 downto 0);
    i_data(i)(21) <= std_logic_vector(resize(unsigned(
                       mon_stat.stat_burst_len_sum(C_MON_STAT_W-1 downto 32)), 32));
    i_data(i)(22) <= mon_stat.stat_burst_len_min;
    i_data(i)(23) <= mon_stat.stat_burst_len_max;
    i_data(i)(24) <= mon_stat.stat_elapsed_cycles;
    i_data(i)(25) <= mon_stat.stat_rsp_stall;
    i_data(i)(26) <= mon_stat.stat_max_outstanding;
    i_data(i)(27) <= mon_stat.stat_data_errors;
    i_data(i)(28) <= mon_stat.stat_rlast_errors;
    i_data(i)(29) <= mon_stat.stat_resp_errors;
    i_data(i)(30) <= mon_stat.stat_sb_underflow_errors;

  end generate gen_clients;

end architecture rtl;
