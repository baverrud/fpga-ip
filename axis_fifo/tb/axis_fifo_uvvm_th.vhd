-----------------------------------------------------------------------
--Filename         : axis_fifo_uvvm_th.vhd
--Description      : UVVM VVC-based Test Harness for axis_fifo.
--                 : Instantiates the DUT, AXI-Stream VVC master/slave,
--                 : and encapsulates all physical port mapping.
--                 : NOTE: In UVVM, the Test Harness (TH) is strictly
--                 : static/structural. It is responsible ONLY for wiring
--                 : the DUT, the VVC wrappers, and managing physical
--                 : clocks/resets. No test sequencer processes or
--                 : high-level stimulus loops are permitted in this file.
--Author           : Rune Bæverrud
--Current Revision : 1.0
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

library uvvm_util;
use uvvm_util.types_pkg.all;
use uvvm_util.methods_pkg.all;

library bitvis_vip_axistream;
use bitvis_vip_axistream.axistream_bfm_pkg.all;

entity axis_fifo_uvvm_th is
  generic (
    GC_DATA_WIDTH : positive := 8;    -- Data byte width configurations
    GC_FIFO_DEPTH : positive := 4;    -- Queue capacity constraints of the target FIFO
    GC_CLK_PERIOD : time     := 10 ns -- Baseline toggle period for the clock generator
  );
  port (
    aclk          : out std_logic;    -- Exposes internal clock to the sequencer process
    aresetn       : in  std_logic;    -- Active-low synchronous reset Driven by sequencer
    clock_ena     : in  boolean;      -- Gate block enabling clean simulator shutdowns
    
    -- Monitor outputs for the sequencer if needed
    fifo_count    : out unsigned;
    dbg_m_tvalid  : out std_logic;
    dbg_m_tready  : out std_logic;
    dbg_m_tdata   : out std_logic_vector(GC_DATA_WIDTH-1 downto 0)
  );
end entity axis_fifo_uvvm_th;

architecture struct of axis_fifo_uvvm_th is
  signal clk_i          : std_logic := '0';
  
  -- DUT flat interface signals
  signal s_axis_tdata   : std_logic_vector(GC_DATA_WIDTH-1 downto 0);
  signal s_axis_tvalid  : std_logic;
  signal s_axis_tready  : std_logic;

  signal m_axis_tdata   : std_logic_vector(GC_DATA_WIDTH-1 downto 0);
  signal m_axis_tvalid  : std_logic;
  signal m_axis_tready  : std_logic;

  -- Local VVC interface record signals.
  -- These records store composite transaction frames passed within the UVVM environments.
  signal tx_if : t_axistream_if(
    tdata(GC_DATA_WIDTH-1 downto 0),
    tkeep(0 downto 0),
    tuser(0 downto 0),
    tstrb(0 downto 0),
    tid(0 downto 0),
    tdest(0 downto 0)
  );

  signal rx_if : t_axistream_if(
    tdata(GC_DATA_WIDTH-1 downto 0),
    tkeep(0 downto 0),
    tuser(0 downto 0),
    tstrb(0 downto 0),
    tid(0 downto 0),
    tdest(0 downto 0)
  );

begin

  -- Expose clock 
  aclk <= clk_i;

  -- UVVM Built-In Clock Generator Helper.
  -- Replaces process loops with a structured procedural framework that logs details centrally.
  clock_generator(clk_i, clock_ena, GC_CLK_PERIOD, "DUT Clock");

  ----------------------------------------------------------------
  -- Device Under Test (DUT) Instantiation
  ----------------------------------------------------------------
  dut : entity work.axis_fifo
    generic map (
      GC_TDATA_WIDTH => GC_DATA_WIDTH,
      GC_FIFO_DEPTH  => GC_FIFO_DEPTH
    )
    port map (
      aclk           => clk_i,
      aresetn        => aresetn,
      s_axis_tdata   => s_axis_tdata,
      s_axis_tvalid  => s_axis_tvalid,
      s_axis_tready  => s_axis_tready,
      m_axis_tdata   => m_axis_tdata,
      m_axis_tvalid  => m_axis_tvalid,
      m_axis_tready  => m_axis_tready,
      fifo_count     => fifo_count
    );

  ----------------------------------------------------------------
  -- Map VVC signals to DUT/External Ports
  ----------------------------------------------------------------
  -- Master TX (S_AXIS):
  s_axis_tdata  <= tx_if.tdata;
  s_axis_tvalid <= tx_if.tvalid;
  tx_if.tready  <= s_axis_tready;

  -- Slave RX (M_AXIS):
  rx_if.tdata                     <= m_axis_tdata;
  rx_if.tvalid                    <= m_axis_tvalid;
  
  -- Drive unused sidebands to static high/low defaults inside the harness to avoid 
  -- undefined 'U' (or conflicting unit) states during VVC evaluations
  rx_if.tkeep(rx_if.tkeep'range)  <= (others => '1');   
  rx_if.tstrb(rx_if.tstrb'range)  <= (others => '1');
  rx_if.tid(rx_if.tid'range)      <= (others => '0');
  rx_if.tdest(rx_if.tdest'range)  <= (others => '0');
  rx_if.tuser(rx_if.tuser'range)  <= (others => '0');
  rx_if.tlast                     <= '0'; -- Pure streaming: tlast is not evaluated here
  
  m_axis_tready <= rx_if.tready;

  -- Lightweight debug visibility for sequencer checks.
  dbg_m_tvalid <= m_axis_tvalid;
  dbg_m_tready <= m_axis_tready;
  dbg_m_tdata  <= m_axis_tdata;

  ----------------------------------------------------------------
  -- Instantiate VVC master (Instance 0)
  -- Receives and executes transactional send directives sent from the sequencer.
  ----------------------------------------------------------------
  i_tx_vvc : entity bitvis_vip_axistream.axistream_vvc
    generic map (
      GC_VVC_IS_MASTER => true,       -- Generates data transactions onto the bus
      GC_DATA_WIDTH    => GC_DATA_WIDTH,
      GC_USER_WIDTH    => 1,
      GC_ID_WIDTH      => 1,
      GC_DEST_WIDTH    => 1,
      GC_INSTANCE_IDX  => 0           -- Managed index mapped to transmitter operations
    )
    port map (
      clk              => clk_i,
      axistream_vvc_if => tx_if
    );

  ----------------------------------------------------------------
  -- Instantiate VVC slave (Instance 1)
  -- Monitors protocol handshakes and asserts verify results on arrival.
  ----------------------------------------------------------------
  i_rx_vvc : entity bitvis_vip_axistream.axistream_vvc
    generic map (
      GC_VVC_IS_MASTER => false,      -- Generates backpressure handshakes (M_AXIS_TREADY)
      GC_DATA_WIDTH    => GC_DATA_WIDTH,
      GC_USER_WIDTH    => 1,
      GC_ID_WIDTH      => 1,
      GC_DEST_WIDTH    => 1,
      GC_INSTANCE_IDX  => 1           -- Managed index mapped to receiver checks
    )
    port map (
      clk              => clk_i,
      axistream_vvc_if => rx_if
    );

end architecture struct;
