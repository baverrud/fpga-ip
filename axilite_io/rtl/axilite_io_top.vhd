-----------------------------------------------------------------------
--Filename         : axilite_io_top.vhd
--Description      : Synthesis Wrapper and Instantiation Top-Level for
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

entity axilite_io_top is
  generic (
    GC_NUM_ODATA   : natural := 2;  -- Number of o_data register outputs
    GC_NUM_IDATA   : natural := 2;  -- Number of i_data inputs
    GC_NUM_OSTREAM : natural := 2;  -- Number of axi-stream outputs
    GC_NUM_ISTREAM : natural := 2   -- Number of axi-stream inputs
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- AXI4-Lite slave write address channel
    s_axi_awaddr  : in  std_logic_vector(15 downto 0);
    s_axi_awprot  : in  std_logic_vector(2 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;

    -- AXI4-Lite slave write data channel
    s_axi_wdata  : in  std_logic_vector(31 downto 0);
    s_axi_wstrb  : in  std_logic_vector(3 downto 0);
    s_axi_wvalid : in  std_logic;
    s_axi_wready : out std_logic;

    -- AXI4-Lite slave write response channel
    s_axi_bresp  : out std_logic_vector(1 downto 0);
    s_axi_bvalid : out std_logic;
    s_axi_bready : in  std_logic;

    -- AXI4-Lite slave read address channel
    s_axi_araddr  : in  std_logic_vector(15 downto 0);
    s_axi_arprot  : in  std_logic_vector(2 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;

    -- AXI4-Lite slave read data channel
    s_axi_rdata  : out std_logic_vector(31 downto 0);
    s_axi_rresp  : out std_logic_vector(1 downto 0);
    s_axi_rvalid : out std_logic;
    s_axi_rready : in  std_logic;

    -- o_data registered outputs and i_data unregistered inputs
    o_data : out slv32_array_t(0 to GC_NUM_ODATA-1);
    i_data : in  slv32_array_t(0 to GC_NUM_IDATA-1);

    -- AXI-Stream outputs
    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tvalid : out std_logic_vector(GC_NUM_OSTREAM-1 downto 0);

    -- AXI-Stream inputs
    s_axis_tdata  : in  slv32_array_t(0 to GC_NUM_ISTREAM-1);
    s_axis_tready : out std_logic_vector(GC_NUM_ISTREAM-1 downto 0)
  );
end entity;

architecture rtl of axilite_io_top is
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
