-----------------------------------------------------------------------
--Filename         : axi_mem_image.vhd
--Description      : AXI3/AXI4 read slave backed by a file-loaded image.
--                 :
--                 : The external AXI interface intentionally matches
--                 : axi_mem_model.  Existing bridge and DMA testbenches
--                 : can therefore replace axi_mem_model with this entity
--                 : and add an Intel HEX file without changing their AXI
--                 : wiring.
--                 :
--                 : Internally the wrapper has the same three stages as
--                 : axi_mem_model:
--                 :   1. AR-side axis_latency_gen,
--                 :   2. axi_mem_image_core beat sequencer,
--                 :   3. R-side axis_latency_gen.
--                 :
--                 : mem_image is configured for zero data on an image
--                 : miss.  The core converts that miss into AXI SLVERR,
--                 : allowing a hole inside a valid region to remain OKAY
--                 : while an address outside the image is observable as a
--                 : protocol error.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_mem_image is
  generic (
    -- AXI/model compatibility generics.
    GC_DATA_BYTES    : positive := 64;
    GC_ADDR_WIDTH    : positive := 49;
    GC_ID_WIDTH      : positive := 6;
    GC_TIMER_WIDTH   : positive := 16;
    GC_AR_FIFO_DEPTH : positive := 8;
    GC_R_FIFO_DEPTH  : positive := 8;

    -- Image-specific capacity and file configuration.
    GC_FILE          : string   := "";
    GC_MAX_REGIONS   : positive := 4;
    GC_GAP_BYTES     : natural  := 4096;
    GC_REGION_WORDS  : positive := 16384
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Timing controls, kept identical to axi_mem_model.
    ar_base_enable   : in std_logic;
    ar_jitter_enable : in std_logic;
    r_base_enable    : in std_logic;
    r_jitter_enable  : in std_logic;
    base_latency     : in std_logic_vector(GC_TIMER_WIDTH-1 downto 0);
    base_beat_gap    : in std_logic_vector(GC_TIMER_WIDTH-1 downto 0);

    -- AXI4 read-address channel.
    ar_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : in  std_logic_vector(7 downto 0);
    ar_valid : in  std_logic;
    ar_ready : out std_logic;

    -- AXI4 read-data channel.
    r_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : out std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : out std_logic_vector(1 downto 0);
    r_last  : out std_logic;
    r_valid : out std_logic;
    r_ready : in  std_logic
  );
end entity;

architecture rtl of axi_mem_image is

  constant C_RDATA_WIDTH : positive := 8 * GC_DATA_BYTES;
  constant C_AR_WIDTH    : positive := GC_ID_WIDTH + GC_ADDR_WIDTH + 8;
  constant C_R_WIDTH     : positive := GC_ID_WIDTH + C_RDATA_WIDTH + 2 + 1;

  -- AR-side stream: [ar_id][ar_addr][ar_len].
  signal ar_tf_tdata  : std_logic_vector(C_AR_WIDTH-1 downto 0) := (others => '0');
  signal ar_tf_valid  : std_logic := '0';
  signal ar_tf_ready  : std_logic := '0';
  signal ar_ff_tdata  : std_logic_vector(C_AR_WIDTH-1 downto 0) := (others => '0');
  signal ar_ff_valid  : std_logic := '0';
  signal ar_ff_ready  : std_logic := '0';

  -- R-side stream: [r_id][r_data][r_resp][r_last].
  signal r_tf_tdata   : std_logic_vector(C_R_WIDTH-1 downto 0) := (others => '0');
  signal r_tf_valid   : std_logic := '0';
  signal r_tf_ready   : std_logic := '0';
  signal r_ff_tdata   : std_logic_vector(C_R_WIDTH-1 downto 0) := (others => '0');
  signal r_ff_valid   : std_logic := '0';
  signal r_ff_ready   : std_logic := '0';

  -- Core's unpacked AR and packed R interfaces.
  signal core_ar_id    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal core_ar_addr  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal core_ar_len   : std_logic_vector(7 downto 0);
  signal core_r_id     : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal core_r_data   : std_logic_vector(C_RDATA_WIDTH-1 downto 0);
  signal core_r_resp   : std_logic_vector(1 downto 0);
  signal core_r_last   : std_logic;
  signal core_r_valid  : std_logic;
  signal core_r_ready  : std_logic;

  -- Combinational lookup connection to the file-backed store.
  signal image_fetch_en   : std_logic;
  signal image_fetch_addr : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal image_data       : std_logic_vector(C_RDATA_WIDTH-1 downto 0);
  signal image_hit        : std_logic;
  signal image_ready      : std_logic;

  -- These constants describe the packed R stream and make the bit slicing
  -- below readable.  The layout mirrors axi_mem_model exactly.
  constant C_RLAST_LOW  : natural := 0;
  constant C_RRESP_LOW  : natural := C_RLAST_LOW + 1;
  constant C_RRESP_HIGH : natural := C_RRESP_LOW + 1;
  constant C_RDATA_LOW  : natural := C_RRESP_HIGH + 1;
  constant C_RDATA_HIGH : natural := C_RDATA_LOW + C_RDATA_WIDTH - 1;
  constant C_RID_LOW    : natural := C_RDATA_HIGH + 1;
  constant C_RID_HIGH   : natural := C_RID_LOW + GC_ID_WIDTH - 1;

begin

  -- The store is combinational after its time-zero load.  "zero" is used
  -- here because the core needs to inspect hit and generate SLVERR itself;
  -- a "fail" policy would fire during speculative beat lookups.
  u_image : entity work.mem_image
    generic map (
      GC_DATA_BYTES   => GC_DATA_BYTES,
      GC_ADDR_WIDTH   => GC_ADDR_WIDTH,
      GC_FILE         => GC_FILE,
      GC_MAX_REGIONS  => GC_MAX_REGIONS,
      GC_GAP_BYTES    => GC_GAP_BYTES,
      GC_REGION_WORDS => GC_REGION_WORDS,
      GC_OUTSIDE      => "zero"
    )
    port map (
      read_en => image_fetch_en,
      addr    => image_fetch_addr,
      data    => image_data,
      hit     => image_hit,
      ready   => image_ready
    );

  -- ================================================================
  -- AR latency stage
  -- ================================================================
  -- Do not accept an AR before the file has finished loading.  Gating both
  -- valid directions keeps the latency FIFO from consuming a request while
  -- the external ready output is low.
  ar_tf_tdata <= ar_id & ar_addr & ar_len;
  ar_tf_valid <= ar_valid and image_ready;
  ar_ready <= ar_tf_ready and image_ready;

  u_ar_latency : entity work.axis_latency_gen
    generic map (
      GC_DATA_WIDTH  => C_AR_WIDTH,
      GC_FIFO_DEPTH  => GC_AR_FIFO_DEPTH,
      GC_TIMER_WIDTH => GC_TIMER_WIDTH
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      s_axis_tdata      => ar_tf_tdata,
      s_axis_tvalid     => ar_tf_valid,
      s_axis_tready     => ar_tf_ready,
      m_axis_tdata      => ar_ff_tdata,
      m_axis_tvalid     => ar_ff_valid,
      m_axis_tready     => ar_ff_ready,
      base_delay        => unsigned(base_latency),
      enable_base_delay => ar_base_enable,
      enable_jitter     => ar_jitter_enable,
      fifo_count        => open
    );

  -- The AR packed layout is MSB-first, matching axi_mem_model.
  core_ar_id   <= ar_ff_tdata(C_AR_WIDTH-1 downto C_AR_WIDTH-GC_ID_WIDTH);
  core_ar_addr <= ar_ff_tdata(C_AR_WIDTH-GC_ID_WIDTH-1 downto 8);
  core_ar_len  <= ar_ff_tdata(7 downto 0);

  -- ================================================================
  -- Image-backed beat sequencer
  -- ================================================================
  u_core : entity work.axi_mem_image_core
    generic map (
      GC_DATA_BYTES => GC_DATA_BYTES,
      GC_ADDR_WIDTH => GC_ADDR_WIDTH,
      GC_ID_WIDTH   => GC_ID_WIDTH
    )
    port map (
      aclk       => aclk,
      aresetn    => aresetn,
      ar_id      => core_ar_id,
      ar_addr    => core_ar_addr,
      ar_len     => core_ar_len,
      ar_valid   => ar_ff_valid,
      ar_ready   => ar_ff_ready,
      r_id       => core_r_id,
      r_data     => core_r_data,
      r_resp     => core_r_resp,
      r_last     => core_r_last,
      r_valid    => core_r_valid,
      r_ready    => core_r_ready,
      fetch_en   => image_fetch_en,
      fetch_addr => image_fetch_addr,
      fetch_data => image_data,
      fetch_hit  => image_hit
    );

  -- ================================================================
  -- R beat-gap latency stage
  -- ================================================================
  r_tf_tdata(C_RID_HIGH downto C_RID_LOW)     <= core_r_id;
  r_tf_tdata(C_RDATA_HIGH downto C_RDATA_LOW) <= core_r_data;
  r_tf_tdata(C_RRESP_HIGH downto C_RRESP_LOW) <= core_r_resp;
  r_tf_tdata(C_RLAST_LOW)                     <= core_r_last;
  r_tf_valid <= core_r_valid;
  core_r_ready <= r_tf_ready;

  u_beat_gap : entity work.axis_latency_gen
    generic map (
      GC_DATA_WIDTH  => C_R_WIDTH,
      GC_FIFO_DEPTH  => GC_R_FIFO_DEPTH,
      GC_TIMER_WIDTH => GC_TIMER_WIDTH
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      s_axis_tdata      => r_tf_tdata,
      s_axis_tvalid     => r_tf_valid,
      s_axis_tready     => r_tf_ready,
      m_axis_tdata      => r_ff_tdata,
      m_axis_tvalid     => r_ff_valid,
      m_axis_tready     => r_ff_ready,
      base_delay        => unsigned(base_beat_gap),
      enable_base_delay => r_base_enable,
      enable_jitter     => r_jitter_enable,
      fifo_count        => open
    );

  -- Unpack the delayed R stream back to the public AXI ports.
  r_ff_ready <= r_ready;
  r_id        <= r_ff_tdata(C_RID_HIGH downto C_RID_LOW);
  r_data      <= r_ff_tdata(C_RDATA_HIGH downto C_RDATA_LOW);
  r_resp      <= r_ff_tdata(C_RRESP_HIGH downto C_RRESP_LOW);
  r_last      <= r_ff_tdata(C_RLAST_LOW);
  r_valid     <= r_ff_valid;

end architecture;
