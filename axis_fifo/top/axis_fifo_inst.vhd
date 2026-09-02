-----------------------------------------------------------------------
--Filename         : axis_fifo_inst.vhd
--Description      : Instantiation template for axis_fifo_top.
--                 : Parameterized with generics to dynamically expose port width
--                 : configurations, passing AXI4-Stream payload signals and
--                 : occupancy count metrics directly.
--                 :
--                 : Depends on common/rtl/util_pkg for the log2ceil function
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axis_fifo_inst is
  generic (
    -- Data path and storage
    GC_TDATA_WIDTH : positive := 8;
    GC_FIFO_DEPTH  : positive := 64
  );
end entity;

architecture rtl of axis_fifo_inst is

  signal aclk : std_logic;
  signal aresetn : std_logic;
  signal s_axis_tdata : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal s_axis_tvalid : std_logic;
  signal s_axis_tready : std_logic;
  signal m_axis_tdata : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic;
  signal fifo_count : std_logic_vector(log2ceil(GC_FIFO_DEPTH) downto 0);

  signal fifo_count_i : unsigned(log2ceil(GC_FIFO_DEPTH) downto 0);

begin

  fifo_count <= std_logic_vector(fifo_count_i);

  -- Instantiate the core IP block.
  u_axis_fifo : entity work.axis_fifo
    generic map (
      GC_TDATA_WIDTH => GC_TDATA_WIDTH,
      GC_FIFO_DEPTH  => GC_FIFO_DEPTH
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
      m_axis_tready => m_axis_tready,

      -- FIFO occupancy
      fifo_count => fifo_count_i
    );

end architecture;
