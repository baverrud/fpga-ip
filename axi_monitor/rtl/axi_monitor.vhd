-----------------------------------------------------------------------
--Filename         : axi_monitor.vhd
--Description      : Passive AXI4 Read Transaction Monitor.
--                   Non-intrusively taps the AR and R channels of a
--                   bus (all AR/R signals are inputs -- it never
--                   drives them).  Captures every AR transaction into
--                   a scoreboard FIFO and validates every R beat
--                   against it, accumulating transaction, latency,
--                   burst-length, and protocol-error statistics.
--
--                   Data flow:  ar tap -> (sb_tf) -> axis_fifo
--                               -> (sb_ff) -> r tap
--                   The scoreboard decouples AR capture from R
--                   completion.  No backpressure is applied to either
--                   channel, so monitoring is transparent to real
--                   traffic.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_monitor is
  generic (
    GC_DATA_BYTES    : positive := 64;
    GC_ADDR_WIDTH    : positive := 49;
    GC_ID_WIDTH      : positive := 6;
    GC_TIME_WIDTH    : positive := 48;
    GC_STAT_WIDTH    : positive := 48;
    GC_SB_FIFO_DEPTH : positive := 256
  );
  port (
    aclk        : in  std_logic;
    aresetn     : in  std_logic;
    global_time : in  unsigned(GC_TIME_WIDTH-1 downto 0);

    -- Control
    enable        : in  std_logic;   -- per-instance enable (0 = monitor inert)
    aperture      : in  std_logic;   -- measurement window
    stat_rst      : in  std_logic;
    err_rst       : in  std_logic;
    data_check_en : in  std_logic;
    pipeline_busy : out std_logic;

    -- AR channel taps (inputs -- passive monitor)
    ar_valid : in  std_logic;
    ar_ready : in  std_logic;
    ar_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : in  std_logic_vector(7 downto 0);

    -- R channel taps (inputs -- passive monitor)
    r_valid : in  std_logic;
    r_ready : in  std_logic;
    r_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : in  std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : in  std_logic_vector(1 downto 0);
    r_last  : in  std_logic;

    -- Statistics and status
    stat_ar_seen             : out std_logic_vector(31 downto 0);
    stat_ar_stall            : out std_logic_vector(31 downto 0);
    stat_sb_backpressure     : out std_logic_vector(31 downto 0);
    stat_xactions            : out std_logic_vector(31 downto 0);
    stat_beats               : out std_logic_vector(31 downto 0);
    stat_latency_sum         : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_latency_min         : out std_logic_vector(31 downto 0);
    stat_latency_max         : out std_logic_vector(31 downto 0);
    stat_first_latency_sum   : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_first_latency_min   : out std_logic_vector(31 downto 0);
    stat_first_latency_max   : out std_logic_vector(31 downto 0);
    stat_interbeat_gap_sum   : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_interbeat_gap_min   : out std_logic_vector(31 downto 0);
    stat_interbeat_gap_max   : out std_logic_vector(31 downto 0);
    stat_burst_len_sum       : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_burst_len_min       : out std_logic_vector(31 downto 0);
    stat_burst_len_max       : out std_logic_vector(31 downto 0);
    stat_elapsed_cycles      : out std_logic_vector(31 downto 0);
    stat_r_stall             : out std_logic_vector(31 downto 0);
    stat_max_outstanding     : out std_logic_vector(31 downto 0);
    stat_data_errors         : out std_logic_vector(31 downto 0);
    stat_id_errors           : out std_logic_vector(31 downto 0);
    stat_rlast_errors        : out std_logic_vector(31 downto 0);
    stat_resp_errors         : out std_logic_vector(31 downto 0);
    stat_sb_underflow_errors : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of axi_monitor is

  constant C_SB_WIDTH : positive := GC_ADDR_WIDTH + GC_ID_WIDTH + GC_TIME_WIDTH + 8;

  -- Scoreboard FIFO signals (tf_ = into FIFO / ar side, ff_ = out of FIFO / r side)
  signal sb_tf_tdata   : std_logic_vector(C_SB_WIDTH-1 downto 0);
  signal sb_tf_valid   : std_logic;
  signal sb_tf_ready   : std_logic;
  signal sb_ff_tdata   : std_logic_vector(C_SB_WIDTH-1 downto 0);
  signal sb_ff_valid   : std_logic;
  signal sb_ff_ready   : std_logic;
  signal sb_fifo_count : unsigned(log2ceil(GC_SB_FIFO_DEPTH) downto 0);

  -- Max-outstanding tracking
  signal max_out_r    : unsigned(sb_fifo_count'range);
  signal max_out_in   : unsigned(sb_fifo_count'range);

begin

  ---------------------------------------------------------------------
  -- Data flow:  AR tap -> (sb_tf) -> axis_fifo -> (sb_ff) -> R tap
  --             AR tap  --ar_valid/ar_addr/ar_len---> external bus
  --             R tap   <---r_valid/r_data/r_last---  external bus
  --
  -- The scoreboard FIFO decouples AR capture from R completion.
  -- AR tap pushes a descriptor per burst; R tap pops it when the
  -- first R beat arrives.
  ---------------------------------------------------------------------

  -- AR monitor -- passive tap, pushes scoreboard descriptor per AR burst
  u_ar : entity work.axi_monitor_ar
    generic map (
      GC_ADDR_WIDTH => GC_ADDR_WIDTH,
      GC_ID_WIDTH   => GC_ID_WIDTH,
      GC_TIME_WIDTH => GC_TIME_WIDTH
    )
    port map (
      aclk                => aclk,
      aresetn             => aresetn,
      global_time         => global_time,
      enable              => enable,
      aperture            => aperture,
      stat_rst            => stat_rst,
      ar_valid            => ar_valid,
      ar_ready            => ar_ready,
      ar_id               => ar_id,
      ar_addr             => ar_addr,
      ar_len              => ar_len,
      sb_tdata            => sb_tf_tdata,
      sb_tvalid           => sb_tf_valid,
      sb_tready           => sb_tf_ready,
      stat_ar_seen        => stat_ar_seen,
      stat_ar_stall       => stat_ar_stall,
      stat_sb_backpressure => stat_sb_backpressure
    );

  -- Scoreboard FIFO -- elastic buffer between AR tap (producer) and
  -- R tap (consumer).  FWFT with registered handshakes.
  u_sb_fifo : entity work.axis_fifo
    generic map (
      GC_TDATA_WIDTH => C_SB_WIDTH,
      GC_FIFO_DEPTH  => GC_SB_FIFO_DEPTH
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => sb_tf_tdata,
      s_axis_tvalid => sb_tf_valid,
      s_axis_tready => sb_tf_ready,
      m_axis_tdata  => sb_ff_tdata,
      m_axis_tvalid => sb_ff_valid,
      m_axis_tready => sb_ff_ready,
      fifo_count    => sb_fifo_count
    );

  -- R monitor -- validates R beats against scoreboard, accumulates stats.
  u_r : entity work.axi_monitor_r
    generic map (
      GC_DATA_BYTES => GC_DATA_BYTES,
      GC_ADDR_WIDTH => GC_ADDR_WIDTH,
      GC_ID_WIDTH   => GC_ID_WIDTH,
      GC_TIME_WIDTH => GC_TIME_WIDTH,
      GC_STAT_WIDTH => GC_STAT_WIDTH
    )
    port map (
      aclk                    => aclk,
      aresetn                 => aresetn,
      global_time             => global_time,
      enable                  => enable,
      stat_rst                => stat_rst,
      err_rst                 => err_rst,
      data_check_en           => data_check_en,
      pipeline_busy           => pipeline_busy,
      r_valid                 => r_valid,
      r_ready                 => r_ready,
      r_id                    => r_id,
      r_data                  => r_data,
      r_resp                  => r_resp,
      r_last                  => r_last,
      sb_tdata                => sb_ff_tdata,
      sb_tvalid               => sb_ff_valid,
      sb_tready               => sb_ff_ready,
      stat_xactions           => stat_xactions,
      stat_beats              => stat_beats,
      stat_latency_sum        => stat_latency_sum,
      stat_latency_min        => stat_latency_min,
      stat_latency_max        => stat_latency_max,
      stat_first_latency_sum  => stat_first_latency_sum,
      stat_first_latency_min  => stat_first_latency_min,
      stat_first_latency_max  => stat_first_latency_max,
      stat_interbeat_gap_sum  => stat_interbeat_gap_sum,
      stat_interbeat_gap_min  => stat_interbeat_gap_min,
      stat_interbeat_gap_max  => stat_interbeat_gap_max,
      stat_burst_len_sum      => stat_burst_len_sum,
      stat_burst_len_min      => stat_burst_len_min,
      stat_burst_len_max      => stat_burst_len_max,
      stat_elapsed_cycles     => stat_elapsed_cycles,
      stat_r_stall            => stat_r_stall,
      stat_data_errors        => stat_data_errors,
      stat_id_errors          => stat_id_errors,
      stat_rlast_errors       => stat_rlast_errors,
      stat_resp_errors        => stat_resp_errors,
      stat_sb_underflow_errors => stat_sb_underflow_errors
    );

  ---------------------------------------------------------------------
  -- Max-outstanding tracker -- records peak fifo_count across stat
  -- measurement windows.  Cleared by aresetn and stat_rst.
  ---------------------------------------------------------------------
  max_out_in <= sb_fifo_count when sb_fifo_count > max_out_r else max_out_r;

  p_max_out : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' or stat_rst = '1' then
        max_out_r <= (others => '0');
      else
        max_out_r <= max_out_in;
      end if;
    end if;
  end process;

  stat_max_outstanding <= std_logic_vector(resize(max_out_r, 32));

end architecture;
