-----------------------------------------------------------------------
--Filename         : axilite_io_inst.vhd
--Description      : Instantiation template for axilite_io_top.
--                 : axilite_io.  Passes the register/stream channel
--                 : counts through as generics and exposes the full
--                 : AXI4-Lite slave and AXI-Stream port set.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axilite_io_inst is
  generic (
    GC_NUM_ODATA   : natural := 2;  -- Number of o_data register outputs
    GC_NUM_IDATA   : natural := 2;  -- Number of i_data inputs
    GC_NUM_OSTREAM : natural := 2;  -- Number of axi-stream outputs
    GC_NUM_ISTREAM : natural := 2   -- Number of axi-stream inputs
  );
end entity;

architecture rtl of axilite_io_inst is
  signal aclk : std_logic;
  signal aresetn : std_logic;
  signal s_axi_awaddr : std_logic_vector(15 downto 0);
  signal s_axi_awprot : std_logic_vector(2 downto 0);
  signal s_axi_awvalid : std_logic;
  signal s_axi_awready : std_logic;
  signal s_axi_wdata : std_logic_vector(31 downto 0);
  signal s_axi_wstrb : std_logic_vector(3 downto 0);
  signal s_axi_wvalid : std_logic;
  signal s_axi_wready : std_logic;
  signal s_axi_bresp : std_logic_vector(1 downto 0);
  signal s_axi_bvalid : std_logic;
  signal s_axi_bready : std_logic;
  signal s_axi_araddr : std_logic_vector(15 downto 0);
  signal s_axi_arprot : std_logic_vector(2 downto 0);
  signal s_axi_arvalid : std_logic;
  signal s_axi_arready : std_logic;
  signal s_axi_rdata : std_logic_vector(31 downto 0);
  signal s_axi_rresp : std_logic_vector(1 downto 0);
  signal s_axi_rvalid : std_logic;
  signal s_axi_rready : std_logic;
  signal o_data : slv32_array_t(0 to GC_NUM_ODATA-1);
  signal i_data : slv32_array_t(0 to GC_NUM_IDATA-1);
  signal m_axis_tdata : std_logic_vector(31 downto 0);
  signal m_axis_tvalid : std_logic_vector(GC_NUM_OSTREAM-1 downto 0);
  signal s_axis_tdata : slv32_array_t(0 to GC_NUM_ISTREAM-1);
  signal s_axis_tready : std_logic_vector(GC_NUM_ISTREAM-1 downto 0);

begin

  u_axilite_io : entity work.axilite_io
    generic map (
      GC_NUM_ODATA   => GC_NUM_ODATA,
      GC_NUM_IDATA   => GC_NUM_IDATA,
      GC_NUM_OSTREAM => GC_NUM_OSTREAM,
      GC_NUM_ISTREAM => GC_NUM_ISTREAM
    )
    port map (
      -- Clock and reset
      aclk    => aclk,
      aresetn => aresetn,

      -- AXI4-Lite slave write address channel
      s_axi_awaddr  => s_axi_awaddr,
      s_axi_awprot  => s_axi_awprot,
      s_axi_awvalid => s_axi_awvalid,
      s_axi_awready => s_axi_awready,

      -- AXI4-Lite slave write data channel
      s_axi_wdata  => s_axi_wdata,
      s_axi_wstrb  => s_axi_wstrb,
      s_axi_wvalid => s_axi_wvalid,
      s_axi_wready => s_axi_wready,

      -- AXI4-Lite slave write response channel
      s_axi_bresp  => s_axi_bresp,
      s_axi_bvalid => s_axi_bvalid,
      s_axi_bready => s_axi_bready,

      -- AXI4-Lite slave read address channel
      s_axi_araddr  => s_axi_araddr,
      s_axi_arprot  => s_axi_arprot,
      s_axi_arvalid => s_axi_arvalid,
      s_axi_arready => s_axi_arready,

      -- AXI4-Lite slave read data channel
      s_axi_rdata  => s_axi_rdata,
      s_axi_rresp  => s_axi_rresp,
      s_axi_rvalid => s_axi_rvalid,
      s_axi_rready => s_axi_rready,

      -- o_data registered outputs and i_data unregistered inputs
      o_data => o_data,
      i_data => i_data,

      -- AXI-Stream outputs
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,

      -- AXI-Stream inputs
      s_axis_tdata  => s_axis_tdata,
      s_axis_tready => s_axis_tready
    );

end architecture;
