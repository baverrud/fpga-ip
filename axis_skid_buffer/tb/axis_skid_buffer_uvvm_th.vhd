-----------------------------------------------------------------------
--Filename         : axis_skid_buffer_uvvm_th.vhd
--Description      : UVVM VVC-based Test Harness for axis_skid_buffer.
--                 : Instantiates the DUT, AXI-Stream VVC master/slave,
--                 : and encapsulates all physical port mapping.
--                 : No test sequencer processes or high-level stimulus
--                 : loops are permitted in this file (structural only).
--Author           : Rune Baeverrud
--Current Revision : 1.0
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library uvvm_util;
use uvvm_util.types_pkg.all;
use uvvm_util.methods_pkg.all;

library bitvis_vip_axistream;
use bitvis_vip_axistream.axistream_bfm_pkg.all;

entity axis_skid_buffer_uvvm_th is
  generic (
    GC_TDATA_WIDTH : positive := 8;    -- Data width
    GC_CLK_PERIOD  : time     := 10 ns -- Clock period
  );
  port (
    aclk               : out std_logic;    -- Exposes internal clock
    aresetn            : in  std_logic;    -- Active-low reset, driven by sequencer
    clock_ena          : in  boolean;      -- Gate to cleanly stop clock
    dbg_s_axis_tready  : out std_logic;    -- DUT handshake observe: slave ready
    dbg_m_axis_tvalid  : out std_logic     -- DUT handshake observe: master valid
  );
end entity axis_skid_buffer_uvvm_th;

architecture struct of axis_skid_buffer_uvvm_th is
  signal clk_i          : std_logic := '0';

  -- DUT flat interface signals
  signal s_axis_tdata   : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal s_axis_tvalid  : std_logic;
  signal s_axis_tready  : std_logic;

  signal m_axis_tdata   : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal m_axis_tvalid  : std_logic;
  signal m_axis_tready  : std_logic;

  -- VVC interface record signals
  signal tx_if : t_axistream_if(
    tdata(GC_TDATA_WIDTH-1 downto 0),
    tkeep(0 downto 0),
    tuser(0 downto 0),
    tstrb(0 downto 0),
    tid(0 downto 0),
    tdest(0 downto 0)
  );

  signal rx_if : t_axistream_if(
    tdata(GC_TDATA_WIDTH-1 downto 0),
    tkeep(0 downto 0),
    tuser(0 downto 0),
    tstrb(0 downto 0),
    tid(0 downto 0),
    tdest(0 downto 0)
  );

begin

  aclk <= clk_i;

  clock_generator(clk_i, clock_ena, GC_CLK_PERIOD, "DUT Clock");

  --------------------------------------------------------------------
  -- Device Under Test (DUT) Instantiation
  --------------------------------------------------------------------
  dut : entity work.axis_skid_buffer
    generic map (
      GC_TDATA_WIDTH => GC_TDATA_WIDTH
    )
    port map (
      aclk           => clk_i,
      aresetn        => aresetn,
      s_axis_tdata   => s_axis_tdata,
      s_axis_tvalid  => s_axis_tvalid,
      s_axis_tready  => s_axis_tready,
      m_axis_tdata   => m_axis_tdata,
      m_axis_tvalid  => m_axis_tvalid,
      m_axis_tready  => m_axis_tready
    );

  --------------------------------------------------------------------
  -- Map VVC signals to DUT ports
  --------------------------------------------------------------------
  -- Master TX (S_AXIS):
  s_axis_tdata  <= tx_if.tdata;
  s_axis_tvalid <= tx_if.tvalid;
  tx_if.tready  <= s_axis_tready;

  -- Slave RX (M_AXIS):
  rx_if.tdata                     <= m_axis_tdata;
  rx_if.tvalid                    <= m_axis_tvalid;

  -- Drive unused sidebands to static defaults
  rx_if.tkeep(rx_if.tkeep'range)  <= (others => '1');
  rx_if.tstrb(rx_if.tstrb'range)  <= (others => '1');
  rx_if.tid(rx_if.tid'range)      <= (others => '0');
  rx_if.tdest(rx_if.tdest'range)  <= (others => '0');
  rx_if.tuser(rx_if.tuser'range)  <= (others => '0');
  rx_if.tlast                     <= '0';

  m_axis_tready <= rx_if.tready;

  -- Lightweight debug/coverage visibility for sequencer checks.
  dbg_s_axis_tready <= s_axis_tready;
  dbg_m_axis_tvalid <= m_axis_tvalid;

  --------------------------------------------------------------------
  -- VVC Master (Instance 0) -- TX side
  --------------------------------------------------------------------
  i_tx_vvc : entity bitvis_vip_axistream.axistream_vvc
    generic map (
      GC_VVC_IS_MASTER => true,
      GC_DATA_WIDTH    => GC_TDATA_WIDTH,
      GC_USER_WIDTH    => 1,
      GC_ID_WIDTH      => 1,
      GC_DEST_WIDTH    => 1,
      GC_INSTANCE_IDX  => 0
    )
    port map (
      clk              => clk_i,
      axistream_vvc_if => tx_if
    );

  --------------------------------------------------------------------
  -- VVC Slave (Instance 1) -- RX side
  --------------------------------------------------------------------
  i_rx_vvc : entity bitvis_vip_axistream.axistream_vvc
    generic map (
      GC_VVC_IS_MASTER => false,
      GC_DATA_WIDTH    => GC_TDATA_WIDTH,
      GC_USER_WIDTH    => 1,
      GC_ID_WIDTH      => 1,
      GC_DEST_WIDTH    => 1,
      GC_INSTANCE_IDX  => 1
    )
    port map (
      clk              => clk_i,
      axistream_vvc_if => rx_if
    );

end architecture struct;
