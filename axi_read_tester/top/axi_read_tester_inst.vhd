-----------------------------------------------------------------------
--Filename         : axi_read_tester_inst.vhd
--Description      : Instantiation template for axi_read_tester.
--                 : Declares internal signals and instantiates the core.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_tester_inst is
  generic (
    GC_NUM_CLIENTS        : positive := 4;
    GC_ADDR_WIDTH         : positive := 32;
    GC_ID_WIDTH           : positive := 4;
    GC_CLIENT_DATA_BYTES  : positive := 64;
    GC_NATIVE_DATA_BYTES  : positive := 16;
    GC_NATIVE_ARLEN_WIDTH : positive range 2 to 8 := 8;
    GC_MAX_BURST          : positive := 32;
    GC_CLIENT_FIFO_DEPTH  : positive range 2 to positive'high := 32;
    GC_CDC_DEPTH          : positive range 2 to 1024 := 8;
    GC_SYNC_STAGES        : positive range 2 to 4 := 2;
    GC_MON_SB_DEPTH       : positive := 32;
    GC_MON_TIME_WIDTH     : positive := 48
  );
end entity;

architecture rtl of axi_read_tester_inst is
  signal aclk : std_logic;
  signal mem_aclk : std_logic;
  signal aresetn : std_logic;
  signal s_axi_awaddr : slv_array_t(0 to GC_NUM_CLIENTS-1)(15 downto 0);
  signal s_axi_awprot : slv_array_t(0 to GC_NUM_CLIENTS-1)(2 downto 0);
  signal s_axi_awvalid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal s_axi_awready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal s_axi_wdata : slv32_array_t(0 to GC_NUM_CLIENTS-1);
  signal s_axi_wstrb : slv_array_t(0 to GC_NUM_CLIENTS-1)(3 downto 0);
  signal s_axi_wvalid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal s_axi_wready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal s_axi_bresp : slv2_array_t(0 to GC_NUM_CLIENTS-1);
  signal s_axi_bvalid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal s_axi_bready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal s_axi_araddr : slv_array_t(0 to GC_NUM_CLIENTS-1)(15 downto 0);
  signal s_axi_arprot : slv_array_t(0 to GC_NUM_CLIENTS-1)(2 downto 0);
  signal s_axi_arvalid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal s_axi_arready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal s_axi_rdata : slv32_array_t(0 to GC_NUM_CLIENTS-1);
  signal s_axi_rresp : slv2_array_t(0 to GC_NUM_CLIENTS-1);
  signal s_axi_rvalid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal s_axi_rready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal pipeline_busy : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal led : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal aperture : std_logic;
  signal stat_rst : std_logic;
  signal err_rst : std_logic;
  signal global_time : unsigned(GC_MON_TIME_WIDTH-1 downto 0);
  signal ar_id : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal ar_addr : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal ar_len : std_logic_vector(GC_NATIVE_ARLEN_WIDTH-1 downto 0);
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;
  signal r_id : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal r_data : std_logic_vector(8*GC_NATIVE_DATA_BYTES-1 downto 0);
  signal r_resp : std_logic_vector(1 downto 0);
  signal r_last : std_logic;
  signal r_valid : std_logic;
  signal r_ready : std_logic;
begin

  u_axi_read_tester : entity work.axi_read_tester
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
      s_axi_awaddr  => s_axi_awaddr,
      s_axi_awprot  => s_axi_awprot,
      s_axi_awvalid => s_axi_awvalid,
      s_axi_awready => s_axi_awready,
      s_axi_wdata   => s_axi_wdata,
      s_axi_wstrb   => s_axi_wstrb,
      s_axi_wvalid  => s_axi_wvalid,
      s_axi_wready  => s_axi_wready,
      s_axi_bresp   => s_axi_bresp,
      s_axi_bvalid  => s_axi_bvalid,
      s_axi_bready  => s_axi_bready,
      s_axi_araddr  => s_axi_araddr,
      s_axi_arprot  => s_axi_arprot,
      s_axi_arvalid => s_axi_arvalid,
      s_axi_arready => s_axi_arready,
      s_axi_rdata   => s_axi_rdata,
      s_axi_rresp   => s_axi_rresp,
      s_axi_rvalid  => s_axi_rvalid,
      s_axi_rready  => s_axi_rready,
      pipeline_busy => pipeline_busy,
      led           => led,
      aperture      => aperture,
      stat_rst      => stat_rst,
      err_rst       => err_rst,
      global_time   => global_time,
      ar_id         => ar_id,
      ar_addr       => ar_addr,
      ar_len        => ar_len,
      ar_valid      => ar_valid,
      ar_ready      => ar_ready,
      r_id          => r_id,
      r_data        => r_data,
      r_resp        => r_resp,
      r_last        => r_last,
      r_valid       => r_valid,
      r_ready       => r_ready
    );

end architecture;
