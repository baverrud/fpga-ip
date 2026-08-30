-----------------------------------------------------------------------
--Filename         : axi_read_tester_array.vhd
--Description      : Parameterizable array wrapper for axi_read_tester.
--                 : Instantiates GC_NUM_TESTERS independent tester cores.
--                 : AXI4-Lite and per-client control ports are flattened
--                 : with index tester * GC_NUM_CLIENTS + client.
--                 : Native AXI read channels are arrayed per tester.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_tester_array is
  generic (
    GC_NUM_TESTERS        : positive := 4;
    GC_NUM_CLIENTS        : positive := 4;
    GC_ADDR_WIDTH         : positive := 32;
    GC_ID_WIDTH           : positive := 6;
    GC_CLIENT_DATA_BYTES  : positive := 64;
    GC_NATIVE_DATA_BYTES  : positive := 16;
    GC_NATIVE_ARLEN_WIDTH : positive range 2 to 8 := 8;
    GC_MAX_BURST          : positive := 32;
    GC_CLIENT_FIFO_DEPTH  : positive range 2 to positive'high := 32;
    GC_CDC_DEPTH          : positive range 2 to 1024 := 8;
    GC_SYNC_STAGES        : positive range 2 to 4 := 2;
    GC_MON_SB_DEPTH       : positive := 256;
    GC_MON_TIME_WIDTH     : positive := 48
  );
  port (
    aclk     : in std_logic;
    mem_aclk : in std_logic;
    aresetn  : in std_logic;

    -- Flattened AXI4-Lite slave ports. Index = tester * GC_NUM_CLIENTS + client.
    s_axi_awaddr  : in  slv_array_t(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1)(15 downto 0);
    s_axi_awprot  : in  slv_array_t(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1)(2 downto 0);
    s_axi_awvalid : in  std_logic_vector(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    s_axi_awready : out std_logic_vector(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    s_axi_wdata   : in  slv32_array_t(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    s_axi_wstrb   : in  slv_array_t(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1)(3 downto 0);
    s_axi_wvalid  : in  std_logic_vector(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    s_axi_wready  : out std_logic_vector(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    s_axi_bresp   : out slv2_array_t(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    s_axi_bvalid  : out std_logic_vector(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    s_axi_bready  : in  std_logic_vector(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    s_axi_araddr  : in  slv_array_t(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1)(15 downto 0);
    s_axi_arprot  : in  slv_array_t(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1)(2 downto 0);
    s_axi_arvalid : in  std_logic_vector(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    s_axi_arready : out std_logic_vector(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    s_axi_rdata   : out slv32_array_t(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    s_axi_rresp   : out slv2_array_t(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    s_axi_rvalid  : out std_logic_vector(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    s_axi_rready  : in  std_logic_vector(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);

    -- Per-client status. External controls are global to every tester/client.
    pipeline_busy : out std_logic_vector(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    led           : out std_logic_vector(0 to GC_NUM_TESTERS*GC_NUM_CLIENTS-1);
    aperture      : in  std_logic;
    stat_rst      : in  std_logic;
    err_rst       : in  std_logic;
    global_time   : in  unsigned(GC_MON_TIME_WIDTH-1 downto 0);

    -- One native AXI read master interface per tester.
    ar_id    : out slv_array_t(0 to GC_NUM_TESTERS-1)(GC_ID_WIDTH-1 downto 0);
    ar_addr  : out slv_array_t(0 to GC_NUM_TESTERS-1)(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : out slv_array_t(0 to GC_NUM_TESTERS-1)(GC_NATIVE_ARLEN_WIDTH-1 downto 0);
    ar_size  : out slv_array_t(0 to GC_NUM_TESTERS-1)(2 downto 0);
    ar_valid : out std_logic_vector(0 to GC_NUM_TESTERS-1);
    ar_ready : in  std_logic_vector(0 to GC_NUM_TESTERS-1);
    r_id     : in  slv_array_t(0 to GC_NUM_TESTERS-1)(GC_ID_WIDTH-1 downto 0);
    r_data   : in  slv_array_t(0 to GC_NUM_TESTERS-1)(8*GC_NATIVE_DATA_BYTES-1 downto 0);
    r_resp   : in  slv2_array_t(0 to GC_NUM_TESTERS-1);
    r_last   : in  std_logic_vector(0 to GC_NUM_TESTERS-1);
    r_valid  : in  std_logic_vector(0 to GC_NUM_TESTERS-1);
    r_ready  : out std_logic_vector(0 to GC_NUM_TESTERS-1)
  );
end entity axi_read_tester_array;

architecture rtl of axi_read_tester_array is
begin
  gen_tester : for tester_index in 0 to GC_NUM_TESTERS-1 generate
    constant C_FLAT_CLIENT_BASE : natural := tester_index * GC_NUM_CLIENTS;
    constant C_NATIVE_AR_SIZE : std_logic_vector(2 downto 0) :=
      std_logic_vector(to_unsigned(log2ceil(GC_NATIVE_DATA_BYTES), 3));

    -- Per-tester AXI4-Lite bus. Its client index starts at zero, unlike the
    -- flattened wrapper bus, which starts at C_FLAT_CLIENT_BASE.
    signal tester_s_axi_awaddr  : slv_array_t(0 to GC_NUM_CLIENTS-1)(15 downto 0);
    signal tester_s_axi_awprot  : slv_array_t(0 to GC_NUM_CLIENTS-1)(2 downto 0);
    signal tester_s_axi_awvalid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tester_s_axi_awready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tester_s_axi_wdata   : slv32_array_t(0 to GC_NUM_CLIENTS-1);
    signal tester_s_axi_wstrb   : slv_array_t(0 to GC_NUM_CLIENTS-1)(3 downto 0);
    signal tester_s_axi_wvalid  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tester_s_axi_wready  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tester_s_axi_bresp   : slv2_array_t(0 to GC_NUM_CLIENTS-1);
    signal tester_s_axi_bvalid  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tester_s_axi_bready  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tester_s_axi_araddr  : slv_array_t(0 to GC_NUM_CLIENTS-1)(15 downto 0);
    signal tester_s_axi_arprot  : slv_array_t(0 to GC_NUM_CLIENTS-1)(2 downto 0);
    signal tester_s_axi_arvalid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tester_s_axi_arready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tester_s_axi_rdata   : slv32_array_t(0 to GC_NUM_CLIENTS-1);
    signal tester_s_axi_rresp   : slv2_array_t(0 to GC_NUM_CLIENTS-1);
    signal tester_s_axi_rvalid  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tester_s_axi_rready  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tester_pipeline_busy : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tester_led           : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  begin
    ar_size(tester_index) <= C_NATIVE_AR_SIZE;

    gen_client : for client_index in 0 to GC_NUM_CLIENTS-1 generate
      constant C_FLAT_CLIENT_INDEX : natural := C_FLAT_CLIENT_BASE + client_index;
    begin
      tester_s_axi_awaddr(client_index) <= s_axi_awaddr(C_FLAT_CLIENT_INDEX);
      tester_s_axi_awprot(client_index) <= s_axi_awprot(C_FLAT_CLIENT_INDEX);
      tester_s_axi_awvalid(client_index) <= s_axi_awvalid(C_FLAT_CLIENT_INDEX);
      s_axi_awready(C_FLAT_CLIENT_INDEX) <= tester_s_axi_awready(client_index);
      tester_s_axi_wdata(client_index) <= s_axi_wdata(C_FLAT_CLIENT_INDEX);
      tester_s_axi_wstrb(client_index) <= s_axi_wstrb(C_FLAT_CLIENT_INDEX);
      tester_s_axi_wvalid(client_index) <= s_axi_wvalid(C_FLAT_CLIENT_INDEX);
      s_axi_wready(C_FLAT_CLIENT_INDEX) <= tester_s_axi_wready(client_index);
      s_axi_bresp(C_FLAT_CLIENT_INDEX) <= tester_s_axi_bresp(client_index);
      s_axi_bvalid(C_FLAT_CLIENT_INDEX) <= tester_s_axi_bvalid(client_index);
      tester_s_axi_bready(client_index) <= s_axi_bready(C_FLAT_CLIENT_INDEX);
      tester_s_axi_araddr(client_index) <= s_axi_araddr(C_FLAT_CLIENT_INDEX);
      tester_s_axi_arprot(client_index) <= s_axi_arprot(C_FLAT_CLIENT_INDEX);
      tester_s_axi_arvalid(client_index) <= s_axi_arvalid(C_FLAT_CLIENT_INDEX);
      s_axi_arready(C_FLAT_CLIENT_INDEX) <= tester_s_axi_arready(client_index);
      s_axi_rdata(C_FLAT_CLIENT_INDEX) <= tester_s_axi_rdata(client_index);
      s_axi_rresp(C_FLAT_CLIENT_INDEX) <= tester_s_axi_rresp(client_index);
      s_axi_rvalid(C_FLAT_CLIENT_INDEX) <= tester_s_axi_rvalid(client_index);
      tester_s_axi_rready(client_index) <= s_axi_rready(C_FLAT_CLIENT_INDEX);
      pipeline_busy(C_FLAT_CLIENT_INDEX) <= tester_pipeline_busy(client_index);
      led(C_FLAT_CLIENT_INDEX) <= tester_led(client_index);
    end generate gen_client;

    u_tester : entity work.axi_read_tester
      generic map (
        GC_NUM_CLIENTS        => GC_NUM_CLIENTS,
        GC_ADDR_WIDTH         => GC_ADDR_WIDTH,
        GC_ID_WIDTH           => GC_ID_WIDTH,
        GC_CLIENT_DATA_BYTES  => GC_CLIENT_DATA_BYTES,
        GC_NATIVE_DATA_BYTES  => GC_NATIVE_DATA_BYTES,
        GC_NATIVE_ARLEN_WIDTH => GC_NATIVE_ARLEN_WIDTH,
        GC_MAX_BURST          => GC_MAX_BURST,
        GC_CLIENT_FIFO_DEPTH  => GC_CLIENT_FIFO_DEPTH,
        GC_CDC_DEPTH          => GC_CDC_DEPTH,
        GC_SYNC_STAGES        => GC_SYNC_STAGES,
        GC_MON_SB_DEPTH       => GC_MON_SB_DEPTH,
        GC_MON_TIME_WIDTH     => GC_MON_TIME_WIDTH
      )
      port map (
        aclk          => aclk,
        mem_aclk      => mem_aclk,
        aresetn       => aresetn,
        s_axi_awaddr  => tester_s_axi_awaddr,
        s_axi_awprot  => tester_s_axi_awprot,
        s_axi_awvalid => tester_s_axi_awvalid,
        s_axi_awready => tester_s_axi_awready,
        s_axi_wdata   => tester_s_axi_wdata,
        s_axi_wstrb   => tester_s_axi_wstrb,
        s_axi_wvalid  => tester_s_axi_wvalid,
        s_axi_wready  => tester_s_axi_wready,
        s_axi_bresp   => tester_s_axi_bresp,
        s_axi_bvalid  => tester_s_axi_bvalid,
        s_axi_bready  => tester_s_axi_bready,
        s_axi_araddr  => tester_s_axi_araddr,
        s_axi_arprot  => tester_s_axi_arprot,
        s_axi_arvalid => tester_s_axi_arvalid,
        s_axi_arready => tester_s_axi_arready,
        s_axi_rdata   => tester_s_axi_rdata,
        s_axi_rresp   => tester_s_axi_rresp,
        s_axi_rvalid  => tester_s_axi_rvalid,
        s_axi_rready  => tester_s_axi_rready,
        pipeline_busy => tester_pipeline_busy,
        led           => tester_led,
        aperture      => aperture,
        stat_rst      => stat_rst,
        err_rst       => err_rst,
        global_time   => global_time,
        ar_id         => ar_id(tester_index),
        ar_addr       => ar_addr(tester_index),
        ar_len        => ar_len(tester_index),
        ar_valid      => ar_valid(tester_index),
        ar_ready      => ar_ready(tester_index),
        r_id          => r_id(tester_index),
        r_data        => r_data(tester_index),
        r_resp        => r_resp(tester_index),
        r_last        => r_last(tester_index),
        r_valid       => r_valid(tester_index),
        r_ready       => r_ready(tester_index)
      );
  end generate gen_tester;
end architecture rtl;
