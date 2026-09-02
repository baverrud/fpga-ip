-----------------------------------------------------------------------
--Filename         : axi_monitor_inst.vhd
--Description      : Instantiation template for axi_monitor_top.
--                   req/rsp channel taps and control/stat ports through
--                   to the entity boundary for connection to a real
--                   client interface in a design.  All req/rsp signals
--                   are inputs -- the monitor is a passive observer.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_monitor_inst is
  generic (
    GC_DATA_BYTES    : positive := 64;
    GC_ADDR_WIDTH    : positive := 49;
    GC_TIME_WIDTH    : positive := 48;
    GC_STAT_WIDTH    : positive := 48;
    GC_SB_FIFO_DEPTH : positive := 256
  );
end entity;

architecture rtl of axi_monitor_inst is
  signal aclk : std_logic;
  signal aresetn : std_logic;
  signal global_time : unsigned(GC_TIME_WIDTH-1 downto 0);
  signal enable : std_logic;
  signal stat_rst : std_logic;
  signal err_rst : std_logic;
  signal data_check_en : std_logic;
  signal req_valid : std_logic;
  signal req_ready : std_logic;
  signal req_addr : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal req_len : std_logic_vector(7 downto 0);
  signal rsp_valid : std_logic;
  signal rsp_ready : std_logic;
  signal rsp_data : std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
  signal rsp_resp : std_logic_vector(1 downto 0);
  signal rsp_last : std_logic;
  signal stat_req_seen : std_logic_vector(31 downto 0);
  signal stat_req_stall : std_logic_vector(31 downto 0);
  signal stat_sb_backpressure : std_logic_vector(31 downto 0);
  signal stat_xactions : std_logic_vector(31 downto 0);
  signal stat_beats : std_logic_vector(31 downto 0);
  signal stat_latency_sum : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_latency_min : std_logic_vector(31 downto 0);
  signal stat_latency_max : std_logic_vector(31 downto 0);
  signal stat_first_latency_sum : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_first_latency_min : std_logic_vector(31 downto 0);
  signal stat_first_latency_max : std_logic_vector(31 downto 0);
  signal stat_interbeat_gap_sum : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_interbeat_gap_min : std_logic_vector(31 downto 0);
  signal stat_interbeat_gap_max : std_logic_vector(31 downto 0);
  signal stat_burst_len_sum : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_burst_len_min : std_logic_vector(31 downto 0);
  signal stat_burst_len_max : std_logic_vector(31 downto 0);
  signal stat_elapsed_cycles : std_logic_vector(31 downto 0);
  signal stat_rsp_stall : std_logic_vector(31 downto 0);
  signal pipeline_busy : std_logic;
  signal stat_max_outstanding : std_logic_vector(31 downto 0);
  signal stat_data_errors : std_logic_vector(31 downto 0);
  signal stat_rlast_errors : std_logic_vector(31 downto 0);
  signal stat_resp_errors : std_logic_vector(31 downto 0);
  signal stat_sb_underflow_errors : std_logic_vector(31 downto 0);

begin

  u_monitor : entity work.axi_monitor
    generic map (
      GC_DATA_BYTES    => GC_DATA_BYTES,
      GC_ADDR_WIDTH    => GC_ADDR_WIDTH,
      GC_TIME_WIDTH    => GC_TIME_WIDTH,
      GC_STAT_WIDTH    => GC_STAT_WIDTH,
      GC_SB_FIFO_DEPTH => GC_SB_FIFO_DEPTH
    )
    port map (
      -- Clock, reset, and timebase
      aclk        => aclk,
      aresetn     => aresetn,
      global_time => global_time,

      -- Control
      enable        => enable,
      stat_rst      => stat_rst,
      err_rst       => err_rst,
      data_check_en => data_check_en,

      -- req channel taps
      req_valid => req_valid,
      req_ready => req_ready,
      req_addr  => req_addr,
      req_len   => req_len,

      -- rsp channel taps
      rsp_valid => rsp_valid,
      rsp_ready => rsp_ready,
      rsp_data  => rsp_data,
      rsp_resp  => rsp_resp,
      rsp_last  => rsp_last,

      -- Statistics and status
      stat_req_seen            => stat_req_seen,
      stat_req_stall           => stat_req_stall,
      stat_sb_backpressure     => stat_sb_backpressure,
      stat_xactions            => stat_xactions,
      stat_beats               => stat_beats,
      stat_latency_sum         => stat_latency_sum,
      stat_latency_min         => stat_latency_min,
      stat_latency_max         => stat_latency_max,
      stat_first_latency_sum   => stat_first_latency_sum,
      stat_first_latency_min   => stat_first_latency_min,
      stat_first_latency_max   => stat_first_latency_max,
      stat_interbeat_gap_sum   => stat_interbeat_gap_sum,
      stat_interbeat_gap_min   => stat_interbeat_gap_min,
      stat_interbeat_gap_max   => stat_interbeat_gap_max,
      stat_burst_len_sum       => stat_burst_len_sum,
      stat_burst_len_min       => stat_burst_len_min,
      stat_burst_len_max       => stat_burst_len_max,
      stat_elapsed_cycles      => stat_elapsed_cycles,
      stat_rsp_stall           => stat_rsp_stall,
      pipeline_busy            => pipeline_busy,
      stat_max_outstanding     => stat_max_outstanding,
      stat_data_errors         => stat_data_errors,
      stat_rlast_errors        => stat_rlast_errors,
      stat_resp_errors         => stat_resp_errors,
      stat_sb_underflow_errors => stat_sb_underflow_errors
    );

end architecture;
