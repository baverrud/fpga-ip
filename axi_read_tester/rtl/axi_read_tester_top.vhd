-----------------------------------------------------------------------
--Filename         : axi_read_tester_top.vhd
--Description      : Synthesis wrapper for axi_read_tester.
--                   Passes all AR/R bus and control ports through
--                   to the entity boundary for connection to AXI
--                   interconnect / DUT in a real design.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_tester_top is
  generic (
    GC_DATA_BYTES     : positive := 64;
    GC_ADDR_WIDTH     : positive := 49;
    GC_ID_WIDTH       : positive := 6;
    GC_TIME_WIDTH     : positive := 48;
    GC_STAT_WIDTH     : positive := 48;
    GC_SB_FIFO_DEPTH  : positive := 256;
    GC_MAX_BURST      : positive := 256
  );
  port (
    aclk    : in  std_logic;
    aresetn : in  std_logic;

    global_time : in  std_logic_vector(GC_TIME_WIDTH-1 downto 0);

    enable_global : in  std_logic;
    enable_local  : in  std_logic;
    aperture      : in  std_logic;
    stat_rst      : in  std_logic;
    err_rst       : in  std_logic;

    arid         : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    burst_length : in  std_logic_vector(31 downto 0);
    pace         : in  std_logic_vector(31 downto 0);
    pace_init    : in  std_logic_vector(31 downto 0);
    base_addr    : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    addr_range   : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    addr_mode    : in  std_logic;

    -- AXI Read-Address Channel (master → DUT)
    ar_valid : out std_logic;
    ar_ready : in  std_logic;
    ar_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : out std_logic_vector(7 downto 0);

    -- AXI Read-Data Channel (DUT → monitor)
    r_valid : in  std_logic;
    r_ready : out std_logic;
    r_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : in  std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : in  std_logic_vector(1 downto 0);
    r_last  : in  std_logic;

    -- Statistics and status
    stat_xactions             : out std_logic_vector(31 downto 0);
    stat_beats                : out std_logic_vector(31 downto 0);
    stat_latency_sum          : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_latency_min          : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_latency_max          : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_first_latency_sum    : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_first_latency_min    : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_first_latency_max    : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_interbeat_gap_sum    : out std_logic_vector(GC_STAT_WIDTH-1 downto 0);
    stat_ar_backpressure      : out std_logic_vector(31 downto 0);
    stat_sb_backpressure      : out std_logic_vector(31 downto 0);
    stat_ar_issued            : out std_logic_vector(31 downto 0);
    stat_cfg_errors           : out std_logic_vector(31 downto 0);
    stat_elapsed_cycles       : out std_logic_vector(31 downto 0);
    pipeline_busy             : out std_logic;
    stat_max_outstanding      : out std_logic_vector(31 downto 0);
    stat_data_errors          : out std_logic_vector(31 downto 0);
    stat_id_errors            : out std_logic_vector(31 downto 0);
    stat_rlast_errors         : out std_logic_vector(31 downto 0);
    stat_resp_errors          : out std_logic_vector(31 downto 0);
    stat_sb_underflow_errors  : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of axi_read_tester_top is
begin

  u_tester : entity work.axi_read_tester
    generic map (
      GC_DATA_BYTES    => GC_DATA_BYTES,
      GC_ADDR_WIDTH    => GC_ADDR_WIDTH,
      GC_ID_WIDTH      => GC_ID_WIDTH,
      GC_TIME_WIDTH    => GC_TIME_WIDTH,
      GC_STAT_WIDTH    => GC_STAT_WIDTH,
      GC_SB_FIFO_DEPTH => GC_SB_FIFO_DEPTH,
      GC_MAX_BURST     => GC_MAX_BURST
    )
    port map (
      aclk                      => aclk,
      aresetn                   => aresetn,
      global_time               => global_time,

      enable_global             => enable_global,
      enable_local              => enable_local,
      aperture                  => aperture,
      stat_rst                  => stat_rst,
      err_rst                   => err_rst,

      arid                      => arid,
      burst_length              => burst_length,
      pace                      => pace,
      pace_init                 => pace_init,
      base_addr                 => base_addr,
      addr_range                => addr_range,
      addr_mode                 => addr_mode,

      ar_valid                  => ar_valid,
      ar_ready                  => ar_ready,
      ar_id                     => ar_id,
      ar_addr                   => ar_addr,
      ar_len                    => ar_len,

      r_valid                   => r_valid,
      r_ready                   => r_ready,
      r_id                      => r_id,
      r_data                    => r_data,
      r_resp                    => r_resp,
      r_last                    => r_last,

      stat_xactions             => stat_xactions,
      stat_beats                => stat_beats,
      stat_latency_sum          => stat_latency_sum,
      stat_latency_min          => stat_latency_min,
      stat_latency_max          => stat_latency_max,
      stat_first_latency_sum    => stat_first_latency_sum,
      stat_first_latency_min    => stat_first_latency_min,
      stat_first_latency_max    => stat_first_latency_max,
      stat_interbeat_gap_sum    => stat_interbeat_gap_sum,
      stat_ar_backpressure      => stat_ar_backpressure,
      stat_sb_backpressure      => stat_sb_backpressure,
      stat_ar_issued            => stat_ar_issued,
      stat_cfg_errors           => stat_cfg_errors,
      stat_elapsed_cycles       => stat_elapsed_cycles,
      pipeline_busy             => pipeline_busy,
      stat_max_outstanding      => stat_max_outstanding,
      stat_data_errors          => stat_data_errors,
      stat_id_errors            => stat_id_errors,
      stat_rlast_errors         => stat_rlast_errors,
      stat_resp_errors          => stat_resp_errors,
      stat_sb_underflow_errors  => stat_sb_underflow_errors
    );

end architecture;
