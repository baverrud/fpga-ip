-----------------------------------------------------------------------
--Filename         : axis_mux_top.vhd
--Description      : Synthesis wrapper for the axis_mux IP.
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

entity axis_mux_top is
  generic (
    GC_NUM_INPUTS  : positive := 4;
    GC_TDATA_WIDTH : positive := 32;
    GC_FIFO_DEPTH  : positive range 2 to positive'high := 8
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- One AXI4-Stream beat interface per input source.
    s_axis_tdata  : in slv_array_t(0 to GC_NUM_INPUTS-1)(GC_TDATA_WIDTH-1 downto 0);
    s_axis_tvalid : in std_logic_vector(0 to GC_NUM_INPUTS-1);
    s_axis_tready : out std_logic_vector(0 to GC_NUM_INPUTS-1);

    -- Shared merged AXI4-Stream output.
    m_axis_tdata  : out std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in std_logic;

    -- Output FIFO occupancy, exposed as a vector for generic packaging.
    fifo_count : out std_logic_vector(log2ceil(GC_FIFO_DEPTH) downto 0)
  );
end entity axis_mux_top;

architecture rtl of axis_mux_top is
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
