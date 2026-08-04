-----------------------------------------------------------------------
--Filename         : axi_monitor_top.vhd
--Description      : Synthesis wrapper for axi_monitor.  Passes all AR/R
--                   channel taps and control/stat ports through to the
--                   entity boundary for connection to a real AXI
--                   interconnect in a design.  All AR/R signals are
--                   inputs -- the monitor is a passive observer.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_monitor_top is
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

    enable        : in  std_logic;
    aperture      : in  std_logic;
    stat_rst      : in  std_logic;
    err_rst       : in  std_logic;
    data_check_en : in  std_logic;

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
    pipeline_busy            : out std_logic;
    stat_max_outstanding     : out std_logic_vector(31 downto 0);
    stat_data_errors         : out std_logic_vector(31 downto 0);
    stat_id_errors           : out std_logic_vector(31 downto 0);
    stat_rlast_errors        : out std_logic_vector(31 downto 0);
    stat_resp_errors         : out std_logic_vector(31 downto 0);
    stat_sb_underflow_errors : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of axi_monitor_top is
begin

  u_monitor : entity work.axi_monitor
    generic map (
      GC_DATA_BYTES    => GC_DATA_BYTES,
      GC_ADDR_WIDTH    => GC_ADDR_WIDTH,
      GC_ID_WIDTH      => GC_ID_WIDTH,
      GC_TIME_WIDTH    => GC_TIME_WIDTH,
      GC_STAT_WIDTH    => GC_STAT_WIDTH,
      GC_SB_FIFO_DEPTH => GC_SB_FIFO_DEPTH
    )
    port map (
      aclk                    => aclk,
      aresetn                 => aresetn,
      global_time             => global_time,
      enable                  => enable,
      aperture                => aperture,
      stat_rst                => stat_rst,
      err_rst                 => err_rst,
      data_check_en           => data_check_en,
      ar_valid                => ar_valid,
      ar_ready                => ar_ready,
      ar_id                   => ar_id,
      ar_addr                 => ar_addr,
      ar_len                  => ar_len,
      r_valid                 => r_valid,
      r_ready                 => r_ready,
      r_id                    => r_id,
      r_data                  => r_data,
      r_resp                  => r_resp,
      r_last                  => r_last,
      stat_ar_seen            => stat_ar_seen,
      stat_ar_stall           => stat_ar_stall,
      stat_sb_backpressure    => stat_sb_backpressure,
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
      pipeline_busy           => pipeline_busy,
      stat_max_outstanding    => stat_max_outstanding,
      stat_data_errors        => stat_data_errors,
      stat_id_errors          => stat_id_errors,
      stat_rlast_errors       => stat_rlast_errors,
      stat_resp_errors        => stat_resp_errors,
      stat_sb_underflow_errors => stat_sb_underflow_errors
    );

end architecture;
