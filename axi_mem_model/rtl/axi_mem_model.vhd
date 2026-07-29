-----------------------------------------------------------------------
--Filename         : axi_mem_model.vhd
--Description      : AXI4 read-slave with configurable first-beat
--                 : latency and per-beat inter-beat gaps.
--                 :
--                 : Top wrapper that instantiates:
--                 :   1. AR-side  axis_latency_gen  — AR latency + jitter
--                 :   2. axi_mem_model_core         — beat sequencing
--                 :   3. R-side  axis_latency_gen   — beat-gap + jitter
--                 :
--                 : When enable=0 both base delays are zeroed,
--                 : producing near-zero-latency pass-through.
--                 :
--                 : Uses default axis_latency_gen jitter configuration
--                 : (CDF-based, 0-20 cycle spread) suitable for LPDDR4
--                 : modelling.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_mem_model is
  generic (
    GC_DATA_BYTES    : positive := 64; -- Bus width in bytes
    GC_ADDR_WIDTH    : positive := 49; -- Address width
    GC_ID_WIDTH      : positive := 6;  -- ID width
    GC_TIMER_WIDTH   : positive := 16; -- Latency / gap timer width
    GC_AR_FIFO_DEPTH : positive := 8;  -- AR-side latency FIFO depth
    GC_R_FIFO_DEPTH  : positive := 8   -- R-side beat-gap FIFO depth
  );
  port (
    aclk    : in  std_logic;
    aresetn : in  std_logic;

    -- Control
    enable       : in  std_logic;
    base_latency : in  std_logic_vector(GC_TIMER_WIDTH-1 downto 0);
    base_beat_gap: in  std_logic_vector(GC_TIMER_WIDTH-1 downto 0);

    -- AXI4 AR channel (individual ports for portability)
    ar_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : in  std_logic_vector(7 downto 0);
    ar_valid : in  std_logic;
    ar_ready : out std_logic;

    -- AXI4 R channel
    r_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : out std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : out std_logic_vector(1 downto 0);
    r_last  : out std_logic;
    r_valid : out std_logic;
    r_ready : in  std_logic
  );
end entity;

architecture rtl of axi_mem_model is

  constant C_RDATA_WIDTH : positive := 8 * GC_DATA_BYTES;

  -- -----------------------------------------------------------------
  -- AR data width (packed: arid & araddr & arlen)
  -- -----------------------------------------------------------------
  constant C_AR_WIDTH : positive := GC_ID_WIDTH + GC_ADDR_WIDTH + 8;

  -- -----------------------------------------------------------------
  -- Beat-response data width (packed: rid & rdata & rresp & rlast)
  -- -----------------------------------------------------------------
  constant C_R_WIDTH  : positive := GC_ID_WIDTH + C_RDATA_WIDTH + 2 + 1;

  -- -----------------------------------------------------------------
  -- AR-side axis_latency_gen signals (tf_ = to FIFO, ff_ = from FIFO)
  -- -----------------------------------------------------------------
  signal ar_tf_tdata  : std_logic_vector(C_AR_WIDTH-1 downto 0);
  signal ar_tf_valid  : std_logic;
  signal ar_tf_ready  : std_logic;
  signal ar_ff_tdata  : std_logic_vector(C_AR_WIDTH-1 downto 0);
  signal ar_ff_valid  : std_logic;
  signal ar_ff_ready  : std_logic;

  signal ar_delay     : unsigned(GC_TIMER_WIDTH-1 downto 0);

  -- -----------------------------------------------------------------
  -- R-side axis_latency_gen signals (tf_ = to FIFO, ff_ = from FIFO)
  -- -----------------------------------------------------------------
  signal r_tf_tdata   : std_logic_vector(C_R_WIDTH-1 downto 0);
  signal r_tf_valid   : std_logic;
  signal r_tf_ready   : std_logic;
  signal r_ff_tdata   : std_logic_vector(C_R_WIDTH-1 downto 0);
  signal r_ff_valid   : std_logic;
  signal r_ff_ready   : std_logic;

  signal r_delay      : unsigned(GC_TIMER_WIDTH-1 downto 0);

  -- Beat-response field offsets (mirrored from core for unpacking)
  constant C_RLAST_LOW   : natural := 0;
  constant C_RLAST_HIGH  : natural := 0;
  constant C_RRESP_LOW   : natural := C_RLAST_HIGH + 1;
  constant C_RRESP_HIGH  : natural := C_RRESP_LOW + 1;
  constant C_RDATA_LOW   : natural := C_RRESP_HIGH + 1;
  constant C_RDATA_HIGH  : natural := C_RDATA_LOW + C_RDATA_WIDTH - 1;
  constant C_RID_LOW     : natural := C_RDATA_HIGH + 1;
  constant C_RID_HIGH    : natural := C_RID_LOW + GC_ID_WIDTH - 1;

begin

  -- ================================================================
  -- Delay MUX: enable=0 → zero delay, enable=1 → configured delay
  -- ================================================================
  ar_delay <= (others => '0') when enable = '0' else unsigned(base_latency);
  r_delay  <= (others => '0') when enable = '0' else unsigned(base_beat_gap);

  -- ================================================================
  -- AR-side axis_latency_gen
  -- ================================================================
  ar_tf_tdata <= ar_id & ar_addr & ar_len;
  ar_tf_valid <= ar_valid;

  u_ar_latency : entity work.axis_latency_gen
    generic map (
      GC_DATA_WIDTH  => C_AR_WIDTH,
      GC_FIFO_DEPTH  => GC_AR_FIFO_DEPTH,
      GC_TIMER_WIDTH => GC_TIMER_WIDTH
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => ar_tf_tdata,
      s_axis_tvalid => ar_tf_valid,
      s_axis_tready => ar_tf_ready,
      m_axis_tdata  => ar_ff_tdata,
      m_axis_tvalid => ar_ff_valid,
      m_axis_tready => ar_ff_ready,
      base_delay    => ar_delay
    );

  ar_ready <= ar_tf_ready;

  -- ================================================================
  -- Core beat sequencer
  -- ================================================================
  u_core : entity work.axi_mem_model_core
    generic map (
      GC_DATA_BYTES => GC_DATA_BYTES,
      GC_ADDR_WIDTH => GC_ADDR_WIDTH,
      GC_ID_WIDTH   => GC_ID_WIDTH
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => ar_ff_tdata,
      s_axis_tvalid => ar_ff_valid,
      s_axis_tready => ar_ff_ready,
      m_axis_tdata  => r_tf_tdata,
      m_axis_tvalid => r_tf_valid,
      m_axis_tready => r_tf_ready
    );

  -- ================================================================
  -- R-side axis_latency_gen (FIFO depth is a generic; gen's timer
  -- provides the inter-beat spacing)
  -- ================================================================
  u_beat_gap : entity work.axis_latency_gen
    generic map (
      GC_DATA_WIDTH  => C_R_WIDTH,
      GC_FIFO_DEPTH  => GC_R_FIFO_DEPTH,
      GC_TIMER_WIDTH => GC_TIMER_WIDTH
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => r_tf_tdata,
      s_axis_tvalid => r_tf_valid,
      s_axis_tready => r_tf_ready,
      m_axis_tdata  => r_ff_tdata,
      m_axis_tvalid => r_ff_valid,
      m_axis_tready => r_ff_ready,
      base_delay    => r_delay
    );

  -- ================================================================
  -- Unpack R-side axis_latency_gen output to AXI4 R channel
  -- ================================================================
  r_ff_ready <= r_ready;

  r_id    <= r_ff_tdata(C_RID_HIGH   downto C_RID_LOW);
  r_data  <= r_ff_tdata(C_RDATA_HIGH downto C_RDATA_LOW);
  r_resp  <= r_ff_tdata(C_RRESP_HIGH downto C_RRESP_LOW);
  r_last  <= r_ff_tdata(C_RLAST_LOW);
  r_valid <= r_ff_valid;

end architecture;
