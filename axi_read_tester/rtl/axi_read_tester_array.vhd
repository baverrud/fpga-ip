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
    GC_ADDR_WIDTH         : positive := 49;
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
  gen_tester : for t in 0 to GC_NUM_TESTERS-1 generate
    signal tw_awaddr  : slv_array_t(0 to GC_NUM_CLIENTS-1)(15 downto 0);
    signal tw_awprot  : slv_array_t(0 to GC_NUM_CLIENTS-1)(2 downto 0);
    signal tw_awvalid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tw_awready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tw_wdata   : slv32_array_t(0 to GC_NUM_CLIENTS-1);
    signal tw_wstrb   : slv_array_t(0 to GC_NUM_CLIENTS-1)(3 downto 0);
    signal tw_wvalid  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tw_wready  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tw_bresp   : slv2_array_t(0 to GC_NUM_CLIENTS-1);
    signal tw_bvalid  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tw_bready  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tw_araddr  : slv_array_t(0 to GC_NUM_CLIENTS-1)(15 downto 0);
    signal tw_arprot  : slv_array_t(0 to GC_NUM_CLIENTS-1)(2 downto 0);
    signal tw_arvalid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tw_arready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tw_rdata   : slv32_array_t(0 to GC_NUM_CLIENTS-1);
    signal tw_rresp   : slv2_array_t(0 to GC_NUM_CLIENTS-1);
    signal tw_rvalid  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tw_rready  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tw_busy    : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    signal tw_led     : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  begin
    gen_client : for c in 0 to GC_NUM_CLIENTS-1 generate
      constant C_IDX : natural := t * GC_NUM_CLIENTS + c;
    begin
      tw_awaddr(c)  <= s_axi_awaddr(C_IDX);
      tw_awprot(c)  <= s_axi_awprot(C_IDX);
      tw_awvalid(c) <= s_axi_awvalid(C_IDX);
      s_axi_awready(C_IDX) <= tw_awready(c);
      tw_wdata(c)   <= s_axi_wdata(C_IDX);
      tw_wstrb(c)   <= s_axi_wstrb(C_IDX);
      tw_wvalid(c)  <= s_axi_wvalid(C_IDX);
      s_axi_wready(C_IDX) <= tw_wready(c);
      s_axi_bresp(C_IDX)  <= tw_bresp(c);
      s_axi_bvalid(C_IDX) <= tw_bvalid(c);
      tw_bready(c) <= s_axi_bready(C_IDX);
      tw_araddr(c)  <= s_axi_araddr(C_IDX);
      tw_arprot(c)  <= s_axi_arprot(C_IDX);
      tw_arvalid(c) <= s_axi_arvalid(C_IDX);
      s_axi_arready(C_IDX) <= tw_arready(c);
      s_axi_rdata(C_IDX)  <= tw_rdata(c);
      s_axi_rresp(C_IDX)  <= tw_rresp(c);
      s_axi_rvalid(C_IDX) <= tw_rvalid(c);
      tw_rready(c) <= s_axi_rready(C_IDX);
      pipeline_busy(C_IDX) <= tw_busy(c);
      led(C_IDX) <= tw_led(c);
    end generate;

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
        s_axi_awaddr  => tw_awaddr,
        s_axi_awprot  => tw_awprot,
        s_axi_awvalid => tw_awvalid,
        s_axi_awready => tw_awready,
        s_axi_wdata   => tw_wdata,
        s_axi_wstrb   => tw_wstrb,
        s_axi_wvalid  => tw_wvalid,
        s_axi_wready  => tw_wready,
        s_axi_bresp   => tw_bresp,
        s_axi_bvalid  => tw_bvalid,
        s_axi_bready  => tw_bready,
        s_axi_araddr  => tw_araddr,
        s_axi_arprot  => tw_arprot,
        s_axi_arvalid => tw_arvalid,
        s_axi_arready => tw_arready,
        s_axi_rdata   => tw_rdata,
        s_axi_rresp   => tw_rresp,
        s_axi_rvalid  => tw_rvalid,
        s_axi_rready  => tw_rready,
        pipeline_busy => tw_busy,
        led           => tw_led,
        aperture      => aperture,
        stat_rst      => stat_rst,
        err_rst       => err_rst,
        global_time   => global_time,
        ar_id         => ar_id(t),
        ar_addr       => ar_addr(t),
        ar_len        => ar_len(t),
        ar_size       => ar_size(t),
        ar_valid      => ar_valid(t),
        ar_ready      => ar_ready(t),
        r_id          => r_id(t),
        r_data        => r_data(t),
        r_resp        => r_resp(t),
        r_last        => r_last(t),
        r_valid       => r_valid(t),
        r_ready       => r_ready(t)
      );
  end generate;
end architecture rtl;
