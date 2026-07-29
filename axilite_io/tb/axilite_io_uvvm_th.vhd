-----------------------------------------------------------------------
--Filename         : axilite_io_uvvm_th.vhd
--Description      : UVVM VVC-based Test Harness for axilite_io.
--                 : Instantiates axilite_io_th (FIFO loopback + status
--                 : i_data) and an AXI4-Lite VVC master, encapsulating
--                 : all physical port mapping.
--Author           : Rune Bæverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library uvvm_util;
use uvvm_util.types_pkg.all;
use uvvm_util.methods_pkg.all;

library bitvis_vip_axilite;
use bitvis_vip_axilite.axilite_bfm_pkg.all;

use work.util_pkg.all;

entity axilite_io_uvvm_th is
  generic (
    GC_NUM_ODATA    : natural := 2;
    GC_NUM_IDATA    : natural := 2;
    GC_NUM_OSTREAM  : natural := 2;
    GC_NUM_ISTREAM  : natural := 2;
    GC_CLK_PERIOD   : time    := 10 ns
  );
  port (
    aclk            : out std_logic;
    aresetn         : in  std_logic;
    clock_ena       : in  boolean;
    -- Debug observe ports
    dbg_o_data      : out t_slv32_array(0 to GC_NUM_ODATA-1);
    dbg_m_axis_tdata  : out std_logic_vector(31 downto 0);
    dbg_m_axis_tvalid : out std_logic_vector(GC_NUM_OSTREAM-1 downto 0);
    dbg_s_axis_tdata  : out t_slv32_array(0 to GC_NUM_ISTREAM-1);
    dbg_s_axis_tready : out std_logic_vector(GC_NUM_ISTREAM-1 downto 0)
  );
end entity axilite_io_uvvm_th;

architecture struct of axilite_io_uvvm_th is

  signal clk_i         : std_logic := '0';

  -- AXI4-Lite internal signals (connect VVC ↔ TH)
  signal s_axi_awaddr  : std_logic_vector(15 downto 0);
  signal s_axi_awprot  : std_logic_vector( 2 downto 0);
  signal s_axi_awvalid : std_logic;
  signal s_axi_awready : std_logic;
  signal s_axi_wdata   : std_logic_vector(31 downto 0);
  signal s_axi_wstrb   : std_logic_vector( 3 downto 0);
  signal s_axi_wvalid  : std_logic;
  signal s_axi_wready  : std_logic;
  signal s_axi_bresp   : std_logic_vector( 1 downto 0);
  signal s_axi_bvalid  : std_logic;
  signal s_axi_bready  : std_logic;
  signal s_axi_araddr  : std_logic_vector(15 downto 0);
  signal s_axi_arprot  : std_logic_vector( 2 downto 0);
  signal s_axi_arvalid : std_logic;
  signal s_axi_arready : std_logic;
  signal s_axi_rdata   : std_logic_vector(31 downto 0);
  signal s_axi_rresp   : std_logic_vector( 1 downto 0);
  signal s_axi_rvalid  : std_logic;
  signal s_axi_rready  : std_logic;

  -- AXI4-Lite VVC interface record (16-bit addr, 32-bit data)
  signal axilite_if : t_axilite_if(
    write_address_channel(
      awaddr(15 downto 0)
    ),
    write_data_channel(
      wdata(31 downto 0),
      wstrb(3 downto 0)
    ),
    read_address_channel(
      araddr(15 downto 0)
    ),
    read_data_channel(
      rdata(31 downto 0)
    )
  ) := init_axilite_if_signals(16, 32);

  -- External i_data (driven from sequencer via TB)
  signal i_data : t_slv32_array(0 to GC_NUM_IDATA-1) := (others => (others => '0'));

begin

  aclk <= clk_i;

  clock_generator(clk_i, clock_ena, GC_CLK_PERIOD, "DUT Clock");

  --------------------------------------------------------------------
  -- Map AXI4-Lite VVC interface record to individual signals
  --------------------------------------------------------------------
  -- VVC → DUT (VVC drives DUT inputs)
  s_axi_awaddr  <= std_logic_vector(axilite_if.write_address_channel.awaddr(15 downto 0));
  s_axi_awprot  <= axilite_if.write_address_channel.awprot;
  s_axi_awvalid <= axilite_if.write_address_channel.awvalid;
  s_axi_wdata   <= std_logic_vector(axilite_if.write_data_channel.wdata(31 downto 0));
  s_axi_wstrb   <= axilite_if.write_data_channel.wstrb;
  s_axi_wvalid  <= axilite_if.write_data_channel.wvalid;
  s_axi_bready  <= axilite_if.write_response_channel.bready;
  s_axi_araddr  <= std_logic_vector(axilite_if.read_address_channel.araddr(15 downto 0));
  s_axi_arprot  <= axilite_if.read_address_channel.arprot;
  s_axi_arvalid <= axilite_if.read_address_channel.arvalid;
  s_axi_rready  <= axilite_if.read_data_channel.rready;

  -- DUT → VVC (DUT drives VVC inputs)
  axilite_if.write_address_channel.awready  <= s_axi_awready;
  axilite_if.write_data_channel.wready      <= s_axi_wready;
  axilite_if.write_response_channel.bresp   <= s_axi_bresp;
  axilite_if.write_response_channel.bvalid  <= s_axi_bvalid;
  axilite_if.read_address_channel.arready   <= s_axi_arready;
  axilite_if.read_data_channel.rdata        <= s_axi_rdata;
  axilite_if.read_data_channel.rresp        <= s_axi_rresp;
  axilite_if.read_data_channel.rvalid       <= s_axi_rvalid;

  --------------------------------------------------------------------
  -- DUT: axilite_io_th (FIFO loopback + status i_data)
  --------------------------------------------------------------------
  th_inst : entity work.axilite_io_th
    generic map (
      GC_NUM_ODATA     => GC_NUM_ODATA,
      GC_NUM_EXT_IDATA => GC_NUM_IDATA,
      GC_NUM_OSTREAM   => GC_NUM_OSTREAM,
      GC_NUM_ISTREAM   => GC_NUM_ISTREAM
    )
    port map (
      aclk          => clk_i,
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
      o_data        => dbg_o_data,
      i_data_ext    => i_data,
      m_axis_tdata  => dbg_m_axis_tdata,
      m_axis_tvalid => dbg_m_axis_tvalid,
      s_axis_tdata  => dbg_s_axis_tdata,
      s_axis_tready => dbg_s_axis_tready
    );

  --------------------------------------------------------------------
  -- AXI4-Lite VVC Master (Instance 1)
  --------------------------------------------------------------------
  i_axilite_vvc : entity bitvis_vip_axilite.axilite_vvc
    generic map (
      GC_ADDR_WIDTH   => 16,
      GC_DATA_WIDTH   => 32,
      GC_INSTANCE_IDX => 1
    )
    port map (
      clk                   => clk_i,
      axilite_vvc_master_if => axilite_if
    );

end architecture struct;
