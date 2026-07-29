-----------------------------------------------------------------------
--Filename         : axilite_io_th.vhd
--Description      : Test harness with stream loopback FIFOs and
--                 : FIFO-status i_data.
--Author           : Rune Bæverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
--                 : Permission to use, copy, modify, and/or distribute this
--                 : software for any purpose with or without fee is hereby granted.
-----------------------------------------------------------------------
-- =====================================================================
-- axilite_io_th.vhd — Test harness with stream loopback FIFOs
-- =====================================================================
-- Wraps axilite_io_harness and adds AXI-Stream loopback FIFOs
-- between the DUT's stream outputs and inputs.  FIFO status is
-- readable via dedicated i_data slots (one signal per slot):
--   slot GC_NUM_EXT_IDATA + ch*2 + 0 = FIFO s_axis_tready (bit 0)
--   slot GC_NUM_EXT_IDATA + ch*2 + 1 = FIFO m_axis_tvalid (bit 0)
--
-- Ports are t_slv32_array; i_data_ext is the external i_data input
-- (2 slots); s_axis_tdata is an output (driven by FIFO read data).
--
-- Instantiation chain:
--   axilite_io_th               (ports: t_slv32_array)
--     ├── axis_fifo [0..N-1]    (m_axis → s_axis loopback)
--     └── axilite_io_harness    (ports: t_slv32_array)
--           └── axilite_io_wrap  (ports: flattened slv)
--                 └── axilite_io_vhd or axilite_io.sv
-- =====================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axilite_io_th is
  generic (
    GC_NUM_ODATA     : natural := 2;
    GC_NUM_EXT_IDATA : natural := 2;
    GC_NUM_OSTREAM   : natural := 2;
    GC_NUM_ISTREAM   : natural := 2;
    GC_FIFO_DEPTH    : positive := 16
  );
  port (
    aclk          : in  std_logic;
    aresetn       : in  std_logic;

    s_axi_awaddr  : in  std_logic_vector(15 downto 0);
    s_axi_awprot  : in  std_logic_vector( 2 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;

    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector( 3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;

    s_axi_bresp   : out std_logic_vector( 1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;

    s_axi_araddr  : in  std_logic_vector(15 downto 0);
    s_axi_arprot  : in  std_logic_vector( 2 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;

    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector( 1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    -- Array-type data ports (match axilite_io_vhd)
    o_data        : out t_slv32_array(0 to GC_NUM_ODATA-1);
    i_data_ext    : in  t_slv32_array(0 to GC_NUM_EXT_IDATA-1);

    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tvalid : out std_logic_vector(GC_NUM_OSTREAM-1 downto 0);

    -- s_axis_tdata is an output: driven by FIFO loopback read data
    s_axis_tdata  : out t_slv32_array(0 to GC_NUM_ISTREAM-1);
    s_axis_tready : out std_logic_vector(GC_NUM_ISTREAM-1 downto 0)
  );
end entity;

architecture rtl of axilite_io_th is

  -- (no intermediate stream signals — harness ports connect directly to TH ports)

  -- Extended i_data: external + FIFO status slots (4 slots = 2 FIFOs × 2 signals)
  signal i_data      : t_slv32_array(0 to GC_NUM_EXT_IDATA + 4 - 1);

  -- FIFO control
  signal tf_ready    : std_logic_vector(1 downto 0);
  signal ff_valid    : std_logic_vector(1 downto 0);


begin

  -- i_data layout: [0..1] = external i_data, [2..5] = FIFO status (one per signal)
  i_data(0) <= i_data_ext(0);
  i_data(1) <= i_data_ext(1);
  i_data(2) <= 31b"0" & tf_ready(0);
  i_data(3) <= 31b"0" & ff_valid(0);
  i_data(4) <= 31b"0" & tf_ready(1);
  i_data(5) <= 31b"0" & ff_valid(1);

  -- Harness: array-port wrapper around the DUT
  harness : entity work.axilite_io_harness
    generic map (
      GC_NUM_ODATA   => GC_NUM_ODATA,
      GC_NUM_IDATA   => GC_NUM_EXT_IDATA + 4,
      GC_NUM_OSTREAM => GC_NUM_OSTREAM,
      GC_NUM_ISTREAM => GC_NUM_ISTREAM
    )
    port map (
      aclk          => aclk,
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
      o_data        => o_data,
      i_data        => i_data,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tready => s_axis_tready
    );

  -- Stream inputs: FIFO loopback feeds the DUT's s_axis (via harness) and TH output.

  -- ================================================================
  --  AXI-Stream loopback FIFOs: DUT m_axis → FIFO → DUT s_axis
  -- ================================================================
  -- FIFO 0: m_axis[0] -> s_axis[0] loopback
  fifo_0 : entity work.axis_fifo
    generic map (GC_TDATA_WIDTH => 32, GC_FIFO_DEPTH => GC_FIFO_DEPTH)
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => m_axis_tdata,
      s_axis_tvalid => m_axis_tvalid(0),
      s_axis_tready => tf_ready(0),
      m_axis_tdata  => s_axis_tdata(0),
      m_axis_tvalid => ff_valid(0),
      m_axis_tready => s_axis_tready(0),
      fifo_count    => open
    );

  -- FIFO 1: m_axis[1] -> s_axis[1] loopback
  fifo_1 : entity work.axis_fifo
    generic map (GC_TDATA_WIDTH => 32, GC_FIFO_DEPTH => GC_FIFO_DEPTH)
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => m_axis_tdata,
      s_axis_tvalid => m_axis_tvalid(1),
      s_axis_tready => tf_ready(1),
      m_axis_tdata  => s_axis_tdata(1),
      m_axis_tvalid => ff_valid(1),
      m_axis_tready => s_axis_tready(1),
      fifo_count    => open
    );

end architecture;
