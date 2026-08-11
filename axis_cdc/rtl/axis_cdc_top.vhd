-----------------------------------------------------------------------
--Filename         : axis_cdc_top.vhd
--Description      : Synthesis wrapper for axis_cdc.
--                 : Passes the data-width and synchronizer-stage generics
--                 : through to the core.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity axis_cdc_top is
  generic (
    -- Width of the AXI-Stream payload word being crossed.
    GC_TDATA_WIDTH : positive := 32;
    -- Internal FIFO depth (power of two).
    GC_CDC_DEPTH : positive range 2 to 1024 := 8;
    -- Number of flip-flops in each synchronizer chain (2..4).
    GC_SYNC_STAGES : positive range 2 to 4 := 2
  );
  port (
    -- Source domain
    s_axis_aclk   : in  std_logic;
    aresetn       : in  std_logic;
    s_axis_tdata  : in  std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;

    -- Destination domain
    m_axis_aclk   : in  std_logic;
    m_axis_tdata  : out std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic
  );
end entity;

architecture rtl of axis_cdc_top is
begin

  u_core : entity work.axis_cdc
    generic map (
      GC_TDATA_WIDTH => GC_TDATA_WIDTH,
      GC_CDC_DEPTH   => GC_CDC_DEPTH,
      GC_SYNC_STAGES => GC_SYNC_STAGES
    )
    port map (
      -- Source domain
      s_axis_aclk   => s_axis_aclk,
      aresetn       => aresetn,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,

      -- Destination domain
      m_axis_aclk   => m_axis_aclk,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready
    );

end architecture;
