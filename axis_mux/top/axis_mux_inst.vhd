-----------------------------------------------------------------------
--Filename         : axis_mux_inst.vhd
--Description      : Instantiation template for axis_mux_top.
--                 : Exposes the parameterized multi-input AXI-Stream
--                 : interface and converts the FIFO occupancy monitor to
--                 : a plain std_logic_vector for packaging tools.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axis_mux_inst is
  generic (
    GC_NUM_INPUTS  : positive := 4;
    GC_TDATA_WIDTH : positive := 32;
    GC_FIFO_DEPTH  : positive range 2 to positive'high := 8
  );
end entity axis_mux_inst;

architecture rtl of axis_mux_inst is
  signal aclk : std_logic;
  signal aresetn : std_logic;
  signal s_axis_tdata : slv_array_t(0 to GC_NUM_INPUTS-1)(GC_TDATA_WIDTH-1 downto 0);
  signal s_axis_tvalid : std_logic_vector(0 to GC_NUM_INPUTS-1);
  signal s_axis_tready : std_logic_vector(0 to GC_NUM_INPUTS-1);
  signal m_axis_tdata : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic;
  signal fifo_count : std_logic_vector(log2ceil(GC_FIFO_DEPTH) downto 0);

  signal fifo_count_i : unsigned(log2ceil(GC_FIFO_DEPTH) downto 0);
begin

  fifo_count <= std_logic_vector(fifo_count_i);

  u_axis_mux : entity work.axis_mux
    generic map (
      GC_NUM_INPUTS  => GC_NUM_INPUTS,
      GC_TDATA_WIDTH => GC_TDATA_WIDTH,
      GC_FIFO_DEPTH  => GC_FIFO_DEPTH
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,
      fifo_count    => fifo_count_i
    );

end architecture rtl;
