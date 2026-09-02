-----------------------------------------------------------------------
--Filename         : axis_downsizer_inst.vhd
--Description      : Instantiation template for axis_downsizer_top.
--                 : 512 -> 128-bit (4:1) configuration.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity axis_downsizer_inst is
  generic (
    GC_M_TDATA_WIDTH : positive := 128;  -- narrow output width
    GC_RATIO         : positive := 4;    -- downsize ratio
    GC_ID_WIDTH      : positive := 4     -- AXI R ID width
  );
end entity;

architecture rtl of axis_downsizer_inst is
  signal aclk : std_logic;
  signal aresetn : std_logic;
  signal s_axis_tdata : std_logic_vector((GC_M_TDATA_WIDTH*GC_RATIO)-1 downto 0);
  signal s_axis_tlast : std_logic;
  signal s_axis_rresp : std_logic_vector(1 downto 0);
  signal s_axis_rid : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal s_axis_tvalid : std_logic;
  signal s_axis_tready : std_logic;
  signal m_axis_tdata : std_logic_vector(GC_M_TDATA_WIDTH-1 downto 0);
  signal m_axis_tlast : std_logic;
  signal m_axis_rresp : std_logic_vector(1 downto 0);
  signal m_axis_rid : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic;

begin

  u_core : entity work.axis_downsizer
    generic map (
      GC_M_TDATA_WIDTH => GC_M_TDATA_WIDTH,
      GC_RATIO         => GC_RATIO,
      GC_ID_WIDTH      => GC_ID_WIDTH
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tlast  => s_axis_tlast,
      s_axis_rresp  => s_axis_rresp,
      s_axis_rid    => s_axis_rid,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tlast  => m_axis_tlast,
      m_axis_rresp  => m_axis_rresp,
      m_axis_rid    => m_axis_rid,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready
    );

end architecture;
