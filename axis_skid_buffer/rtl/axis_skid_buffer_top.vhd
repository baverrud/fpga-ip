-----------------------------------------------------------------------
--Filename         : axis_skid_buffer_top.vhd
--Description      : Synthesis Wrapper and Instantiation Top-Level for
--                 : axis_skid_buffer.
--                 : Parameterized with GC_TDATA_WIDTH generic to
--                 : dynamically expose port width configurations.
--Author           : Rune Bæverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axis_skid_buffer_top is
  generic (
    GC_TDATA_WIDTH  : positive := 8
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
    m_axis_tready   : in  std_logic
  );
end entity;

architecture rtl of axis_skid_buffer_top is

begin

  -- Instantiate the core IP block (SystemVerilog binding)
  axis_skid_buffer_inst : entity work.axis_skid_buffer
    generic map (
      GC_TDATA_WIDTH  => GC_TDATA_WIDTH
    )
    port map (
      aclk            => aclk,
      aresetn         => aresetn,
      s_axis_tdata    => s_axis_tdata,
      s_axis_tvalid   => s_axis_tvalid,
      s_axis_tready   => s_axis_tready,
      m_axis_tdata    => m_axis_tdata,
      m_axis_tvalid   => m_axis_tvalid,
      m_axis_tready   => m_axis_tready
    );

end architecture;
