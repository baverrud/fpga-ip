-----------------------------------------------------------------------
--Filename         : axi_mem_store.vhd
--Description      : AXI read slave backed by real byte-addressed data.
--                 : The AR side uses axis_latency_gen for request latency.
--                 : The R side also uses axis_latency_gen for per-entry
--                 : response latency and jitter.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_mem_store is
  generic (
    GC_DATA_BYTES     : positive := 64;
    GC_ADDR_WIDTH     : positive := 32;
    GC_ID_WIDTH       : positive := 6;
    GC_TIMER_WIDTH    : positive := 16;
    GC_AR_FIFO_DEPTH  : positive range 2 to positive'high := 8;
    GC_R_FIFO_DEPTH   : positive range 2 to positive'high := 8;
    GC_MEM_SIZE_BYTES : positive := 16384
  );
  port (
    aclk    : in  std_logic;
    aresetn : in  std_logic;

    -- Timing controls.
    ar_base_enable   : in  std_logic;
    ar_jitter_enable : in  std_logic;
    r_base_enable    : in  std_logic;
    r_jitter_enable  : in  std_logic;
    base_latency     : in  std_logic_vector(GC_TIMER_WIDTH-1 downto 0);
    base_beat_gap    : in  std_logic_vector(GC_TIMER_WIDTH-1 downto 0);

    -- Byte population write port.
    mem_wr_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    mem_wr_data  : in  std_logic_vector(7 downto 0);
    mem_wr_valid : in  std_logic;
    mem_wr_ready : out std_logic; -- High when a byte write is accepted.
    mem_wr_error : out std_logic; -- One-clock pulse on an out-of-range write.

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

architecture rtl of axi_mem_store is

  -- The AR and R latency generators use packed AXI-Stream payloads so the
  -- standard stream FIFO can carry all channel fields atomically.
  constant C_RDATA_WIDTH : positive := 8 * GC_DATA_BYTES;
  constant C_AR_WIDTH    : positive := GC_ID_WIDTH + GC_ADDR_WIDTH + 8;
  constant C_R_WIDTH     : positive := GC_ID_WIDTH + C_RDATA_WIDTH + 2 + 1;

  signal ar_tf_tdata : std_logic_vector(C_AR_WIDTH-1 downto 0);
  signal ar_tf_valid : std_logic;
  signal ar_tf_ready : std_logic;
  signal ar_ff_tdata : std_logic_vector(C_AR_WIDTH-1 downto 0);
  signal ar_ff_valid : std_logic;
  signal ar_ff_ready : std_logic;

  signal r_tf_tdata : std_logic_vector(C_R_WIDTH-1 downto 0);
  signal r_tf_valid : std_logic;
  signal r_tf_ready : std_logic;
  signal r_ff_tdata : std_logic_vector(C_R_WIDTH-1 downto 0);
  signal r_ff_valid : std_logic;
  signal r_ff_ready : std_logic;

  signal core_ar_id   : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal core_ar_addr : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal core_ar_len  : std_logic_vector(7 downto 0);
  signal core_r_id    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal core_r_data  : std_logic_vector(C_RDATA_WIDTH-1 downto 0);
  signal core_r_resp  : std_logic_vector(1 downto 0);
  signal core_r_last  : std_logic;
  signal core_r_valid : std_logic;
  signal core_r_ready : std_logic;

  constant C_RLAST_LOW  : natural := 0;
  constant C_RRESP_LOW  : natural := 1;
  constant C_RRESP_HIGH : natural := 2;
  constant C_RDATA_LOW  : natural := 3;
  constant C_RDATA_HIGH : natural := C_RDATA_LOW + C_RDATA_WIDTH - 1;
  constant C_RID_LOW    : natural := C_RDATA_HIGH + 1;
  constant C_RID_HIGH   : natural := C_RID_LOW + GC_ID_WIDTH - 1;

begin

  -- AR payload layout is [ar_id][ar_addr][ar_len], with ar_len in the LSBs.
  ar_tf_tdata <= ar_id & ar_addr & ar_len;
  ar_tf_valid <= ar_valid;
  ar_ready    <= ar_tf_ready;

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

  -- Unpack the delayed AR payload before handing it to the stored-memory core.
  core_ar_id   <= ar_ff_tdata(C_AR_WIDTH-1 downto C_AR_WIDTH-GC_ID_WIDTH);
  core_ar_addr <= ar_ff_tdata(C_AR_WIDTH-GC_ID_WIDTH-1 downto 8);
  core_ar_len  <= ar_ff_tdata(7 downto 0);

  u_core : entity work.axi_mem_store_core
    generic map (
      GC_DATA_BYTES     => GC_DATA_BYTES,
      GC_ADDR_WIDTH     => GC_ADDR_WIDTH,
      GC_ID_WIDTH       => GC_ID_WIDTH,
      GC_MEM_SIZE_BYTES => GC_MEM_SIZE_BYTES
    )
    port map (
      aclk        => aclk,
      aresetn     => aresetn,
      mem_wr_addr => mem_wr_addr,
      mem_wr_data => mem_wr_data,
      mem_wr_valid => mem_wr_valid,
      mem_wr_ready => mem_wr_ready,
      mem_wr_error => mem_wr_error,
      ar_id       => core_ar_id,
      ar_addr     => core_ar_addr,
      ar_len      => core_ar_len,
      ar_valid    => ar_ff_valid,
      ar_ready    => ar_ff_ready,
      r_id        => core_r_id,
      r_data      => core_r_data,
      r_resp      => core_r_resp,
      r_last      => core_r_last,
      r_valid     => core_r_valid,
      r_ready     => core_r_ready
    );

  -- R payload layout is [r_id][r_data][r_resp][r_last], with r_last in the
  -- LSB.  The R generator receives the complete response atomically.
  r_tf_tdata(C_RID_HIGH downto C_RID_LOW)       <= core_r_id;
  r_tf_tdata(C_RDATA_HIGH downto C_RDATA_LOW)   <= core_r_data;
  r_tf_tdata(C_RRESP_HIGH downto C_RRESP_LOW)   <= core_r_resp;
  r_tf_tdata(C_RLAST_LOW)                       <= core_r_last;
  r_tf_valid <= core_r_valid;
  core_r_ready <= r_tf_ready;

  -- The existing generator supplies per-entry response latency and jitter.
  -- Its behavior is intentionally unchanged; see the latency review note for
  -- the distinction between per-entry delay and guaranteed output gaps.
  u_r_latency : entity work.axis_latency_gen
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

  -- The external R handshake controls when the latency FIFO may pop.
  r_ff_ready <= r_ready;

  -- Unpack the delayed response stream back into individual AXI ports.
  r_id    <= r_ff_tdata(C_RID_HIGH downto C_RID_LOW);
  r_data  <= r_ff_tdata(C_RDATA_HIGH downto C_RDATA_LOW);
  r_resp  <= r_ff_tdata(C_RRESP_HIGH downto C_RRESP_LOW);
  r_last  <= r_ff_tdata(C_RLAST_LOW);
  r_valid <= r_ff_valid;

end architecture;
