-----------------------------------------------------------------------
--Filename         : axis_fifo_top.vhd
--Description      : Synthesis Wrapper and Instantiation Top-Level for axis_fifo.
--                 : Parameterized with generics to dynamically expose port width
--                 : configurations, passing AXI4-Stream payload signals and
--                 : occupancy count metrics directly.
--                 :
--                 : Depends on common/rtl/util_pkg for the log2ceil function
--Author           : Rune Bæverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axis_fifo_top is
  generic (
    GC_TDATA_WIDTH  : positive := 8;
    GC_DATA_DEPTH   : positive := 64
  );
  port (
    aclk            : in  std_logic;
    aresetn         : in  std_logic; -- Synchronous reset, active low
    
    -- Slave Interface (Input transaction ports)
    s_axis_tdata    : in  std_logic_vector (GC_TDATA_WIDTH-1 downto 0);
    s_axis_tvalid   : in  std_logic;
    s_axis_tready   : out std_logic;

    -- Master Interface (Output transaction ports)
    m_axis_tdata    : out std_logic_vector (GC_TDATA_WIDTH-1 downto 0);
    m_axis_tvalid   : out std_logic;
    m_axis_tready   : in  std_logic;

    -- FIFO occupancy level
    fifo_count      : out std_logic_vector (log2ceil(GC_DATA_DEPTH) downto 0)
  );
end entity;

architecture rtl of axis_fifo_top is

  signal fifo_count_i  : unsigned(log2ceil(GC_DATA_DEPTH) downto 0);

begin

  fifo_count <= std_logic_vector(fifo_count_i);

  -- Instantiate the core IP block (supports VHDL or SystemVerilog binding natively inside Vivado/ModelSim)
  dut: entity work.axis_fifo
    generic map (
      GC_TDATA_WIDTH => GC_TDATA_WIDTH,
      GC_DATA_DEPTH  => GC_DATA_DEPTH
    )
    port map (
      aclk           => aclk,
      aresetn        => aresetn,
      s_axis_tdata   => s_axis_tdata,
      s_axis_tvalid  => s_axis_tvalid,
      s_axis_tready  => s_axis_tready,
      m_axis_tdata   => m_axis_tdata,
      m_axis_tvalid  => m_axis_tvalid,
      m_axis_tready  => m_axis_tready,
      fifo_count     => fifo_count_i
    );

end architecture;
