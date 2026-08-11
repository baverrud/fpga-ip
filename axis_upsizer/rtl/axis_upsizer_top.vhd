-----------------------------------------------------------------------
--Filename         : axis_upsizer_top.vhd
--Description      : Synthesis wrapper for axis_upsizer, defaulted to the
--                 : 128 -> 512-bit (4:1) configuration.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity axis_upsizer_top is
  generic (
    GC_S_TDATA_WIDTH : positive := 128;  -- narrow input width
    GC_RATIO         : positive := 4;    -- upsize ratio
    GC_ID_WIDTH      : positive := 4     -- AXI R ID width
  );
  port (
    -- Clock / reset
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Slave interface (narrow input, AXI R channel)
    s_axis_tdata  : in  std_logic_vector(GC_S_TDATA_WIDTH-1 downto 0);
    s_axis_tlast  : in  std_logic;
    s_axis_rresp  : in  std_logic_vector(1 downto 0);
    s_axis_rid    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;

    -- Master interface (wide output, AXI R channel)
    m_axis_tdata  : out std_logic_vector((GC_S_TDATA_WIDTH*GC_RATIO)-1 downto 0);
    m_axis_tlast  : out std_logic;
    m_axis_rresp  : out std_logic_vector(1 downto 0);
    m_axis_rid    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic
  );
end entity;

architecture rtl of axis_upsizer_top is
begin

  u_core : entity work.axis_upsizer
    generic map (
      GC_S_TDATA_WIDTH => GC_S_TDATA_WIDTH,
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
