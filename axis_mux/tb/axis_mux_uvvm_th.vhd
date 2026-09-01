-----------------------------------------------------------------------
--Filename         : axis_mux_uvvm_th.vhd
--Description      : Structural UVVM harness for axis_mux.
--                 : Instantiates three AXI-Stream master VVCs, one output
--                 : slave VVC, the DUT, and the output-stall override.
--                 : This file contains wiring only; all stimulus belongs in
--                 : axis_mux_uvvm_tb.vhd.
--Author           : Rune Baeverrud
--Current Revision : 1.00
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

entity axis_mux_uvvm_th is
  generic (
    GC_TDATA_WIDTH : positive := 32;
    GC_FIFO_DEPTH  : positive range 2 to positive'high := 4;
    GC_CLK_PERIOD  : time := 10 ns
  );
  port (
    aclk             : out std_logic;
    aresetn          : in  std_logic;
    clock_ena        : in  boolean;
    force_m_stall    : in  std_logic;
    dbg_s_axis_tready : out std_logic_vector(0 to 2);
    dbg_m_axis_tdata  : out std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
    dbg_m_axis_tvalid : out std_logic;
    dbg_m_axis_tready : out std_logic;
    fifo_count        : out unsigned(log2ceil(GC_FIFO_DEPTH) downto 0)
  );
end entity axis_mux_uvvm_th;

architecture struct of axis_mux_uvvm_th is
  constant C_NUM_INPUTS : positive := 3;
  constant C_NUM_BYTES  : positive := (GC_TDATA_WIDTH + 7) / 8;

  signal clk_i : std_logic := '0';

  signal s_axis_tdata  : slv_array_t(0 to C_NUM_INPUTS-1)(GC_TDATA_WIDTH-1 downto 0);
  signal s_axis_tvalid : std_logic_vector(0 to C_NUM_INPUTS-1);
  signal s_axis_tready : std_logic_vector(0 to C_NUM_INPUTS-1);

  signal m_axis_tdata  : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic;
  signal fifo_count_i  : unsigned(log2ceil(GC_FIFO_DEPTH) downto 0);

  signal tx0_if : t_axistream_if(
    tdata(GC_TDATA_WIDTH-1 downto 0),
    tkeep(C_NUM_BYTES-1 downto 0),
    tuser(0 downto 0),
    tstrb(C_NUM_BYTES-1 downto 0),
    tid(0 downto 0),
    tdest(0 downto 0)
  );
  signal tx1_if : t_axistream_if(
    tdata(GC_TDATA_WIDTH-1 downto 0),
    tkeep(C_NUM_BYTES-1 downto 0),
    tuser(0 downto 0),
    tstrb(C_NUM_BYTES-1 downto 0),
    tid(0 downto 0),
    tdest(0 downto 0)
  );
  signal tx2_if : t_axistream_if(
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
    report "axis_mux UVVM harness requires a byte-aligned payload width"
    severity failure;

  aclk <= clk_i;
  fifo_count <= fifo_count_i;
  dbg_s_axis_tready <= s_axis_tready;
  dbg_m_axis_tdata  <= m_axis_tdata;
  dbg_m_axis_tvalid <= m_axis_tvalid;
  dbg_m_axis_tready <= m_axis_tready;

  clock_generator(clk_i, clock_ena, GC_CLK_PERIOD, "axis_mux clock");

  dut : entity work.axis_mux
    generic map (
      GC_NUM_INPUTS  => C_NUM_INPUTS,
      GC_TDATA_WIDTH => GC_TDATA_WIDTH,
      GC_FIFO_DEPTH  => GC_FIFO_DEPTH
    )
    port map (
      aclk          => clk_i,
      aresetn       => aresetn,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,
      fifo_count    => fifo_count_i
    );

  s_axis_tdata(0)  <= tx0_if.tdata;
  s_axis_tvalid(0) <= tx0_if.tvalid;
  tx0_if.tready    <= s_axis_tready(0);

  s_axis_tdata(1)  <= tx1_if.tdata;
  s_axis_tvalid(1) <= tx1_if.tvalid;
  tx1_if.tready    <= s_axis_tready(1);

  s_axis_tdata(2)  <= tx2_if.tdata;
  s_axis_tvalid(2) <= tx2_if.tvalid;
  tx2_if.tready    <= s_axis_tready(2);

  rx_if.tdata  <= m_axis_tdata;
  rx_if.tvalid <= m_axis_tvalid;
  rx_if.tlast  <= '0';
  rx_if.tkeep  <= (others => '1');
  rx_if.tstrb  <= (others => '1');
  rx_if.tuser  <= (others => '0');
  rx_if.tid    <= (others => '0');
  rx_if.tdest  <= (others => '0');

  -- A deterministic stall override is structural, so it is independent of
  -- VVC command scheduling and can hold the output for exact clock windows.
  m_axis_tready <= '0' when force_m_stall = '1' else rx_if.tready;

  i_tx0_vvc : entity bitvis_vip_axistream.axistream_vvc
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
      axistream_vvc_if => tx0_if
    );

  i_tx1_vvc : entity bitvis_vip_axistream.axistream_vvc
    generic map (
      GC_VVC_IS_MASTER => true,
      GC_DATA_WIDTH    => GC_TDATA_WIDTH,
      GC_USER_WIDTH    => 1,
      GC_ID_WIDTH      => 1,
      GC_DEST_WIDTH    => 1,
      GC_INSTANCE_IDX  => 1
    )
    port map (
      clk              => clk_i,
      axistream_vvc_if => tx1_if
    );

  i_tx2_vvc : entity bitvis_vip_axistream.axistream_vvc
    generic map (
      GC_VVC_IS_MASTER => true,
      GC_DATA_WIDTH    => GC_TDATA_WIDTH,
      GC_USER_WIDTH    => 1,
      GC_ID_WIDTH      => 1,
      GC_DEST_WIDTH    => 1,
      GC_INSTANCE_IDX  => 2
    )
    port map (
      clk              => clk_i,
      axistream_vvc_if => tx2_if
    );

  i_rx_vvc : entity bitvis_vip_axistream.axistream_vvc
    generic map (
      GC_VVC_IS_MASTER => false,
      GC_DATA_WIDTH    => GC_TDATA_WIDTH,
      GC_USER_WIDTH    => 1,
      GC_ID_WIDTH      => 1,
      GC_DEST_WIDTH    => 1,
      GC_INSTANCE_IDX  => 3
    )
    port map (
      clk              => clk_i,
      axistream_vvc_if => rx_if
    );

end architecture struct;
