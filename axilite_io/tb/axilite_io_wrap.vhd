-----------------------------------------------------------------------
--Filename         : axilite_io_wrap.vhd
--Description      : VHDL flattened-port wrapper for axilite_io.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
--                 : Permission to use, copy, modify, and/or distribute this
--                 : software for any purpose with or without fee is hereby granted.
-----------------------------------------------------------------------
-- =====================================================================
-- axilite_io_wrap.vhd -- VHDL wrapper with flattened ports
-- =====================================================================
-- WHY THIS WRAPPER EXISTS
-- ------------------------
-- The VHDL DUT (axilite_io.vhd) uses t_slv32_array (an unconstrained
-- array of 32-bit std_logic_vectors) for its multi-slot data ports --
-- e.g. `o_data : out t_slv32_array(0 to GC_NUM_ODATA-1)`.  The SV DUT
-- (axilite_io.sv) uses packed 2D arrays `[N-1:0][31:0]` for the same
-- ports.  Neither representation can be directly instantiated from the
-- other language.
--
-- Each wrapper (one per language) normalises these to a common
-- flattened std_logic_vector interface.  The axilite_io_harness
-- instantiates axilite_io_wrap by entity, testing one DUT per run.
-- =====================================================================
library ieee;
use ieee.std_logic_1164.all;
use work.util_pkg.all;

entity axilite_io_wrap is
  generic (
    NUM_ODATA   : natural := 2;
    NUM_IDATA   : natural := 2;
    NUM_OSTREAM : natural := 2;
    NUM_ISTREAM : natural := 2
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
    -- Flattened arrays
    o_data        : out std_logic_vector(NUM_ODATA*32-1 downto 0);
    i_data        : in  std_logic_vector(NUM_IDATA*32-1 downto 0);
    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tvalid : out std_logic_vector(NUM_OSTREAM-1 downto 0);
    s_axis_tdata  : in  std_logic_vector(NUM_ISTREAM*32-1 downto 0);
    s_axis_tready : out std_logic_vector(NUM_ISTREAM-1 downto 0)
  );
end entity;

architecture wrap of axilite_io_wrap is

  -- Internal array-form signals
  signal o_data_arr  : t_slv32_array(0 to NUM_ODATA-1);
  signal i_data_arr  : t_slv32_array(0 to NUM_IDATA-1);
  signal s_tdata_arr : t_slv32_array(0 to NUM_ISTREAM-1);

begin

  -- Instantiate the VHDL DUT
  dut : entity work.axilite_io(rtl)
    generic map (
      GC_NUM_ODATA   => NUM_ODATA,
      GC_NUM_IDATA   => NUM_IDATA,
      GC_NUM_OSTREAM => NUM_OSTREAM,
      GC_NUM_ISTREAM => NUM_ISTREAM
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
      o_data        => o_data_arr,
      i_data        => i_data_arr,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      s_axis_tdata  => s_tdata_arr,
      s_axis_tready => s_axis_tready
    );

  -- Array <-> flattened conversion
  gen_o : for i in 0 to NUM_ODATA-1 generate
    o_data((i+1)*32-1 downto i*32) <= o_data_arr(i);
  end generate;

  gen_i : for i in 0 to NUM_IDATA-1 generate
    i_data_arr(i) <= i_data((i+1)*32-1 downto i*32);
  end generate;

  gen_s : for i in 0 to NUM_ISTREAM-1 generate
    s_tdata_arr(i) <= s_axis_tdata((i+1)*32-1 downto i*32);
  end generate;

end architecture;
