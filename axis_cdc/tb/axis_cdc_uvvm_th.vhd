-----------------------------------------------------------------------
--Filename         : axis_cdc_uvvm_th.vhd
--Description      : Structural UVVM test harness for axis_cdc.
--                 : Instantiates the DUT, independent source/destination
--                 : clocks, and AXI-Stream master/slave VVCs.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

library uvvm_util;
use uvvm_util.types_pkg.all;
use uvvm_util.methods_pkg.all;

library bitvis_vip_axistream;
use bitvis_vip_axistream.axistream_bfm_pkg.all;

entity axis_cdc_uvvm_th is
  generic (
    GC_TDATA_WIDTH : positive := 32;
    GC_CDC_DEPTH   : positive := 8;
    GC_SYNC_STAGES : positive := 2;
    GC_S_CLK_PERIOD : time := 10 ns;
    GC_M_CLK_PERIOD : time := 13.2 ns
  );
  port (
    s_axis_aclk : out std_logic;
    m_axis_aclk : out std_logic;
    aresetn     : in  std_logic;
    s_clock_ena : in  boolean;
    m_clock_ena : in  boolean;
    force_m_stall : in std_logic;

    dbg_s_axis_tdata  : out std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
    dbg_s_axis_tvalid : out std_logic;
    dbg_s_axis_tready : out std_logic;
    dbg_m_axis_tdata  : out std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
    dbg_m_axis_tvalid : out std_logic;
    dbg_m_axis_tready : out std_logic
  );
end entity axis_cdc_uvvm_th;

architecture struct of axis_cdc_uvvm_th is
  constant C_NUM_BYTES : positive := (GC_TDATA_WIDTH + 7) / 8;

  signal s_clk : std_logic := '0';
  signal m_clk : std_logic := '0';

  signal s_axis_tdata  : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal s_axis_tvalid : std_logic;
  signal s_axis_tready : std_logic;
  signal m_axis_tdata  : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic;

  signal tx_if : t_axistream_if(
    tdata(GC_TDATA_WIDTH-1 downto 0),
    tkeep(C_NUM_BYTES-1 downto 0),
    tuser(0 downto 0),
    tstrb(C_NUM_BYTES-1 downto 0),
    tid(0 downto 0),
    tdest(0 downto 0)
  );

  signal rx_if : t_axistream_if(
    tdata(GC_TDATA_WIDTH-1 downto 0),
    tkeep(C_NUM_BYTES-1 downto 0),
    tuser(0 downto 0),
    tstrb(C_NUM_BYTES-1 downto 0),
    tid(0 downto 0),
    tdest(0 downto 0)
  );
begin
  assert (GC_TDATA_WIDTH mod 8) = 0
    report "axis_cdc UVVM harness requires a byte-aligned payload width"
    severity failure;

  s_axis_aclk <= s_clk;
  m_axis_aclk <= m_clk;

  clock_generator(s_clk, s_clock_ena, GC_S_CLK_PERIOD, "Source clock");
  clock_generator(m_clk, m_clock_ena, GC_M_CLK_PERIOD, "Destination clock");

  dut : entity work.axis_cdc
    generic map (
      GC_TDATA_WIDTH => GC_TDATA_WIDTH,
      GC_CDC_DEPTH   => GC_CDC_DEPTH,
      GC_SYNC_STAGES => GC_SYNC_STAGES
    )
    port map (
      s_axis_aclk   => s_clk,
      aresetn       => aresetn,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      m_axis_aclk   => m_clk,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready
    );

  s_axis_tdata  <= tx_if.tdata;
  s_axis_tvalid <= tx_if.tvalid;
  tx_if.tready  <= s_axis_tready;

  rx_if.tdata  <= m_axis_tdata;
  rx_if.tvalid <= m_axis_tvalid;
  rx_if.tkeep  <= (others => '1');
  rx_if.tstrb  <= (others => '1');
  rx_if.tid    <= (others => '0');
  rx_if.tdest  <= (others => '0');
  rx_if.tuser  <= (others => '0');
  rx_if.tlast  <= '0';
  m_axis_tready <= '0' when force_m_stall = '1' else rx_if.tready;

  dbg_s_axis_tdata  <= s_axis_tdata;
  dbg_s_axis_tvalid <= s_axis_tvalid;
  dbg_s_axis_tready <= s_axis_tready;
  dbg_m_axis_tdata  <= m_axis_tdata;
  dbg_m_axis_tvalid <= m_axis_tvalid;
  dbg_m_axis_tready <= m_axis_tready;

  tx_vvc : entity bitvis_vip_axistream.axistream_vvc
    generic map (
      GC_VVC_IS_MASTER => true,
      GC_DATA_WIDTH    => GC_TDATA_WIDTH,
      GC_USER_WIDTH    => 1,
      GC_ID_WIDTH      => 1,
      GC_DEST_WIDTH    => 1,
      GC_INSTANCE_IDX  => 0
    )
    port map (
      clk              => s_clk,
      axistream_vvc_if => tx_if
    );

  rx_vvc : entity bitvis_vip_axistream.axistream_vvc
    generic map (
      GC_VVC_IS_MASTER => false,
      GC_DATA_WIDTH    => GC_TDATA_WIDTH,
      GC_USER_WIDTH    => 1,
      GC_ID_WIDTH      => 1,
      GC_DEST_WIDTH    => 1,
      GC_INSTANCE_IDX  => 1
    )
    port map (
      clk              => m_clk,
      axistream_vvc_if => rx_if
    );
end architecture struct;
