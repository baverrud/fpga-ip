-----------------------------------------------------------------------
--Filename         : axi_monitor.vhd
--Description      : Passive client read-transaction monitor for the
--                   req_* / rsp_* interfaces (no ID field).
--                   Non-intrusively taps a client request/response pair
--                   (all req/rsp signals are inputs -- it never drives
--                   them).  Captures every req transaction into a
--                   scoreboard FIFO and validates every rsp beat
--                   against it, accumulating transaction, latency,
--                   burst-length, and protocol-error statistics.
--
--                   Data flow:  req tap -> (sb_tf) -> axis_fifo
--                               -> (sb_ff) -> rsp tap
--                   The scoreboard decouples req capture from rsp
--                   completion.  No backpressure is applied to either
--                   channel, so monitoring is transparent to real
--                   traffic.
--
--                   There is no ID on the client interface, so no ID
--                   check and no ID-related statistics exist.
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
    stat_rst      : in  std_logic;
    err_rst       : in  std_logic;
    data_check_en : in  std_logic;
    pipeline_busy : out std_logic;

    -- req channel taps (inputs -- passive monitor)
    req_valid : in  std_logic;
    req_ready : in  std_logic;
    req_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    req_len   : in  std_logic_vector(7 downto 0);

    -- rsp channel taps (inputs -- passive monitor)
    rsp_valid : in  std_logic;
    rsp_ready : in  std_logic;
    rsp_data  : in  std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    rsp_resp  : in  std_logic_vector(1 downto 0);
    rsp_last  : in  std_logic;

    -- Statistics and status
    stat_req_seen            : out std_logic_vector(31 downto 0);
    stat_req_stall           : out std_logic_vector(31 downto 0);
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
    stat_rsp_stall           : out std_logic_vector(31 downto 0);
    stat_max_outstanding     : out std_logic_vector(31 downto 0);
    stat_data_errors         : out std_logic_vector(31 downto 0);
    stat_rlast_errors        : out std_logic_vector(31 downto 0);
    stat_resp_errors         : out std_logic_vector(31 downto 0);
    stat_sb_underflow_errors : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of axi_monitor is

  constant C_SB_WIDTH : positive := GC_ADDR_WIDTH + GC_TIME_WIDTH + 8;

  -- Scoreboard FIFO signals (tf_ = into FIFO / req side, ff_ = out of FIFO / rsp side)
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
  -- Data flow:  req tap -> (sb_tf) -> axis_fifo -> (sb_ff) -> rsp tap
  --             req tap  --req_valid/req_addr/req_len---> external bus
  --             rsp tap  <---rsp_valid/rsp_data/rsp_last-  external bus
  --
  -- The scoreboard FIFO decouples req capture from rsp completion.
  -- req tap pushes a descriptor per burst; rsp tap pops it when the
  -- first rsp beat arrives.
  ---------------------------------------------------------------------

  -- req monitor -- passive tap, pushes scoreboard descriptor per burst
  u_req : entity work.axi_monitor_req
    generic map (
      GC_ADDR_WIDTH => GC_ADDR_WIDTH,
      GC_TIME_WIDTH => GC_TIME_WIDTH
    )
    port map (
      aclk                => aclk,
      aresetn             => aresetn,
      global_time         => global_time,
      enable              => enable,
      stat_rst            => stat_rst,
      req_valid           => req_valid,
      req_ready           => req_ready,
      req_addr            => req_addr,
      req_len             => req_len,
      sb_tdata            => sb_tf_tdata,
      sb_tvalid           => sb_tf_valid,
      sb_tready           => sb_tf_ready,
      stat_req_seen       => stat_req_seen,
      stat_req_stall      => stat_req_stall,
      stat_sb_backpressure => stat_sb_backpressure
    );

  -- Scoreboard FIFO -- elastic buffer between req tap (producer) and
  -- rsp tap (consumer).  FWFT with registered handshakes.
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

  -- rsp monitor -- validates rsp beats against scoreboard, accumulates stats.
  u_rsp : entity work.axi_monitor_rsp
    generic map (
      GC_DATA_BYTES => GC_DATA_BYTES,
      GC_ADDR_WIDTH => GC_ADDR_WIDTH,
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
      rsp_valid               => rsp_valid,
      rsp_ready               => rsp_ready,
      rsp_data                => rsp_data,
      rsp_resp                => rsp_resp,
      rsp_last                => rsp_last,
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
      stat_rsp_stall          => stat_rsp_stall,
      stat_data_errors        => stat_data_errors,
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
