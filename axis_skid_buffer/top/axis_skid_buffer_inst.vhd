-----------------------------------------------------------------------
--Filename         : axis_skid_buffer_inst.vhd
--Description      : Instantiation template for axis_skid_buffer_top.
--                 : axis_skid_buffer.
--                 : Parameterized with GC_TDATA_WIDTH generic to
--                 : dynamically expose port width configurations.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axis_skid_buffer_inst is
  generic (
    -- Data path
    GC_TDATA_WIDTH : positive := 8
  );
end entity;

architecture rtl of axis_skid_buffer_inst is

  signal aclk : std_logic;
  signal aresetn : std_logic;
  signal s_axis_tdata : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal s_axis_tvalid : std_logic;
  signal s_axis_tready : std_logic;
  signal m_axis_tdata : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic;

begin

  -- Instantiate the core IP block.
  u_axis_skid_buffer : entity work.axis_skid_buffer
    generic map (
      GC_TDATA_WIDTH => GC_TDATA_WIDTH
    )
    port map (
      -- Clock and reset
      aclk    => aclk,
      aresetn => aresetn,

      -- Slave AXI4-Stream interface
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,

      -- Master AXI4-Stream interface
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready
    );

end architecture;
