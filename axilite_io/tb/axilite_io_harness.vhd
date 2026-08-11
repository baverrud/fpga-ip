-----------------------------------------------------------------------
--Filename         : axilite_io_harness.vhd
--Description      : Array-port wrapper for axilite_io (slv32_array_t <->
--                 : flattened conversion).
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
--                 : Permission to use, copy, modify, and/or distribute this
--                 : software for any purpose with or without fee is hereby granted.
-----------------------------------------------------------------------
-- =====================================================================
-- axilite_io_harness.vhd -- Array-port wrapper
-- =====================================================================
-- WHY THIS EXISTS
-- ---------------
-- axilite_io_wrap (VHDL or SV) normalises multi-slot data ports to
-- flattened std_logic_vector.  This wrapper converts back to the
-- original slv32_array_t interface (matching axilite_io_vhd's ports).
--
-- Instantiation chain:
--   axilite_io_harness         (ports: slv32_array_t)
--     +-- axilite_io_wrap      (ports: flattened slv -- VHDL or SV)
--           +-- axilite_io_vhd or axilite_io.sv  (actual DUT)
--
-- FIFO loopback is in axilite_io_th, one level above this wrapper.
-- =====================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axilite_io_harness is
  generic (
    GC_NUM_ODATA   : natural := 2;
    GC_NUM_IDATA   : natural := 2;
    GC_NUM_OSTREAM : natural := 2;
    GC_NUM_ISTREAM : natural := 2
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

    -- Array-type data ports (match axilite_io_vhd exactly)
    o_data        : out slv32_array_t(0 to GC_NUM_ODATA-1);
    i_data        : in  slv32_array_t(0 to GC_NUM_IDATA-1);

    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tvalid : out std_logic_vector(GC_NUM_OSTREAM-1 downto 0);

    s_axis_tdata  : in  slv32_array_t(0 to GC_NUM_ISTREAM-1);
    s_axis_tready : out std_logic_vector(GC_NUM_ISTREAM-1 downto 0)
  );
end entity;

architecture rtl of axilite_io_harness is

  -- Flattened intermediate signals
  signal o_data_flat  : std_logic_vector(GC_NUM_ODATA*32-1 downto 0);
  signal i_data_flat  : std_logic_vector(GC_NUM_IDATA*32-1 downto 0);

  signal m_axis_tdata_int  : std_logic_vector(31 downto 0);
  signal m_axis_tvalid_int : std_logic_vector(GC_NUM_OSTREAM-1 downto 0);
  signal s_axis_tdata_int  : std_logic_vector(GC_NUM_ISTREAM*32-1 downto 0);
  signal s_axis_tready_int : std_logic_vector(GC_NUM_ISTREAM-1 downto 0);

begin

  -- Inner wrapper
  inner : entity work.axilite_io_wrap
    generic map (
      NUM_ODATA   => GC_NUM_ODATA,
      NUM_IDATA   => GC_NUM_IDATA,
      NUM_OSTREAM => GC_NUM_OSTREAM,
      NUM_ISTREAM => GC_NUM_ISTREAM
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
      o_data        => o_data_flat,
      i_data        => i_data_flat,
      m_axis_tdata  => m_axis_tdata_int,
      m_axis_tvalid => m_axis_tvalid_int,
      s_axis_tdata  => s_axis_tdata_int,
      s_axis_tready => s_axis_tready_int
    );

  -- o_data: flattened -> array
  gen_o : for i in 0 to GC_NUM_ODATA-1 generate
    o_data(i) <= o_data_flat((i+1)*32-1 downto i*32);
  end generate;

  -- i_data: array -> flattened
  gen_i : for i in 0 to GC_NUM_IDATA-1 generate
    i_data_flat((i+1)*32-1 downto i*32) <= i_data(i);
  end generate;

  -- Stream ports: direct pass-through
  m_axis_tdata  <= m_axis_tdata_int;
  m_axis_tvalid <= m_axis_tvalid_int;
  -- s_axis_tdata: array -> flattened
  gen_s : for i in 0 to GC_NUM_ISTREAM-1 generate
    s_axis_tdata_int((i+1)*32-1 downto i*32) <= s_axis_tdata(i);
  end generate;

  -- s_axis_tready: flattened -> array (pass-through)
  gen_srdy : for i in 0 to GC_NUM_ISTREAM-1 generate
    s_axis_tready(i) <= s_axis_tready_int(i);
  end generate;

end architecture;
