-----------------------------------------------------------------------
--Filename         : axi_monitor_reg.vhd
--Description      : AXI4-Lite register wrapper for axi_monitor (passive
--                   AR/R read-transaction monitor) plus axi_ar_gen
--                   (AR traffic generator).
--                   Instantiates axi_monitor + axi_ar_gen + axilite_io
--                   register bank.  The generator drives the AR channel
--                   (out to the DUT), and the monitor taps the same AR
--                   channel plus the R channel (both inputs -- the
--                   monitor never drives the bus).
--
--                   Control signals routed via the register bank:
--                     enable, data_check_en, led            (monitor)
--                     enable, cfg_id, cfg_arlen, cfg_pace, cfg_pace_init,
--                     cfg_base_addr, cfg_addr_range, cfg_addr_mode       (generator)
--                   Signals left as ports (not in the register map):
--                     global_time, aperture, stat_rst, err_rst,
--                     pipeline_busy
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
--
-- =====================================================================
-- Register Map  (axilite_io, 16-bit addr, lower 16 addr bits decoded)
--
-- o_data (writable):
--  [0]   enable         (bit 0) - monitor per-instance enable
--  [1]   data_check_en  (bit 0) - verify r_data vs expected pattern
--  [2]   led            (bit 0) - diagnostic GPIO
--  [3]   gen enable     (bit 0) - generator enable
--  [4]   cfg_id
--  [5]   cfg_arlen              - AXI arlen (beats-1); 0 = 1 beat;
--                                low log2ceil(GC_MAX_BURST) bits used
--  [6]   cfg_pace                   - idle cycles between ARs (0 = every cycle)
--  [7]   cfg_pace_init              - delay before first burst
--  [8]   cfg_base_addr[31:0]
--  [9]   cfg_base_addr[48:32]
--  [10]  cfg_addr_range[31:0]
--  [11]  cfg_addr_range[48:32]
--  [12]  cfg_addr_mode        (bit 0) - '0' linear, '1' random
--
-- i_data (read-only) - GC_STAT_WIDTH <= 63 -> max 2 words per wide signal:
--  [0]  stat_ar_seen
--  [1]  stat_ar_stall
--  [2]  stat_sb_backpressure
--  [3]  stat_xactions
--  [4]  stat_beats
--  [5]  stat_latency_sum (lo)
--  [6]  stat_latency_sum (hi)
--  [7]  stat_latency_min
--  [8]  stat_latency_max
--  [9]  stat_first_latency_sum (lo)
--  [10] stat_first_latency_sum (hi)
--  [11] stat_first_latency_min
--  [12] stat_first_latency_max
--  [13] stat_interbeat_gap_sum (lo)
--  [14] stat_interbeat_gap_sum (hi)
--  [15] stat_interbeat_gap_min
--  [16] stat_interbeat_gap_max
--  [17] stat_burst_len_sum (lo)
--  [18] stat_burst_len_sum (hi)
--  [19] stat_burst_len_min
--  [20] stat_burst_len_max
--  [21] stat_elapsed_cycles
--  [22] stat_r_stall
--  [23] stat_max_outstanding
--  [24] stat_data_errors
--  [25] stat_id_errors
--  [26] stat_rlast_errors
--  [27] stat_resp_errors
--  [28] stat_sb_underflow_errors
--  [29] gen_stat_ar_stall
--  [30] gen_stat_ar_issued
--  [31] gen_stat_cfg_errors
--
-- pipeline_busy is exposed as an output port (not readable via i_data).
-- =====================================================================
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_monitor_reg is
  generic (
    GC_DATA_BYTES    : positive := 64;
    GC_ADDR_WIDTH    : positive := 49;
    GC_ID_WIDTH      : positive := 6;
    GC_TIME_WIDTH    : positive := 48;
    GC_STAT_WIDTH    : positive := 48;   -- matches i_data split below (2 x 32-bit words)
    GC_SB_FIFO_DEPTH : positive := 256;
    GC_MAX_BURST     : positive := 256   -- max beats per burst: 256 (AXI4) / 16 (AXI3)
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Global control (not in the register map)
    global_time : in unsigned(GC_TIME_WIDTH-1 downto 0);
    aperture    : in std_logic;
    stat_rst    : in std_logic;
    err_rst     : in std_logic;

    -- Diagnostic LED output (driven by o_data[2], bit 0)
    led : out std_logic;

    -- Pipeline busy (scoreboard has entries or burst in-flight)
    pipeline_busy : out std_logic;

    -- AXI4-Lite register interface (slave)
    axilite_awaddr  : in  std_logic_vector(39 downto 0);
    axilite_awprot  : in  std_logic_vector(2 downto 0);
    axilite_awvalid : in  std_logic;
    axilite_awready : out std_logic;
    axilite_wdata   : in  std_logic_vector(31 downto 0);
    axilite_wstrb   : in  std_logic_vector(3 downto 0);
    axilite_wvalid  : in  std_logic;
    axilite_wready  : out std_logic;
    axilite_bresp   : out std_logic_vector(1 downto 0);
    axilite_bvalid  : out std_logic;
    axilite_bready  : in  std_logic;
    axilite_araddr  : in  std_logic_vector(39 downto 0);
    axilite_arprot  : in  std_logic_vector(2 downto 0);
    axilite_arvalid : in  std_logic;
    axilite_arready : out std_logic;
    axilite_rdata   : out std_logic_vector(31 downto 0);
    axilite_rresp   : out std_logic_vector(1 downto 0);
    axilite_rvalid  : out std_logic;
    axilite_rready  : in  std_logic;

    -- AXI4 read-address channel (master, driven by axi_ar_gen)
    ar_valid : out std_logic;
    ar_ready : in  std_logic;
    ar_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : out std_logic_vector(7 downto 0);   -- beats-1
    ar_size  : out std_logic_vector(2 downto 0);   -- bytes per beat (log2 of data width)
    ar_burst : out std_logic_vector(1 downto 0);   -- always INCR

    -- R channel taps (inputs -- passive monitor)
    r_valid : in std_logic;
    r_ready : in std_logic;
    r_id    : in std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : in std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : in std_logic_vector(1 downto 0);
    r_last  : in std_logic
  );
end entity;

architecture rtl of axi_monitor_reg is

  function word32(constant slv : std_logic_vector;
                  constant w   : natural) return std_logic_vector is
    variable v : std_logic_vector(31 downto 0) := (others => '0');
  begin
    for i in 0 to 31 loop
      if w * 32 + i <= slv'high then
        v(i) := slv(w * 32 + i);
      end if;
    end loop;
    return v;
  end function;

  constant C_NUM_ODATA : natural := 13;
  constant C_NUM_IDATA : natural := 32;

  signal o_data : slv32_array_t(0 to C_NUM_ODATA-1) := (others => (others => '0'));
  signal i_data : slv32_array_t(0 to C_NUM_IDATA-1) := (others => (others => '0'));

  -- Monitor control
  signal enable        : std_logic;
  signal data_check_en : std_logic;

  -- Generator control / config
  signal gen_enable   : std_logic;
  signal cfg_id         : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal cfg_arlen    : std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);
  signal cfg_pace         : std_logic_vector(31 downto 0);
  signal cfg_pace_init    : std_logic_vector(31 downto 0);
  signal cfg_base_addr    : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal cfg_addr_range   : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal cfg_addr_mode    : std_logic;

  -- AR channel (generator drives, monitor taps)
  signal ar_valid_i : std_logic;
  signal ar_ready_i : std_logic;
  signal ar_id_i    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal ar_addr_i  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal ar_len_i   : std_logic_vector(7 downto 0);

  -- Monitor statistics
  signal stat_ar_seen             : std_logic_vector(31 downto 0);
  signal stat_ar_stall            : std_logic_vector(31 downto 0);
  signal stat_sb_backpressure     : std_logic_vector(31 downto 0);
  signal stat_xactions            : std_logic_vector(31 downto 0);
  signal stat_beats               : std_logic_vector(31 downto 0);
  signal stat_latency_sum         : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_latency_min         : std_logic_vector(31 downto 0);
  signal stat_latency_max         : std_logic_vector(31 downto 0);
  signal stat_first_latency_sum   : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_first_latency_min   : std_logic_vector(31 downto 0);
  signal stat_first_latency_max   : std_logic_vector(31 downto 0);
  signal stat_interbeat_gap_sum   : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_interbeat_gap_min   : std_logic_vector(31 downto 0);
  signal stat_interbeat_gap_max   : std_logic_vector(31 downto 0);
  signal stat_burst_len_sum       : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_burst_len_min       : std_logic_vector(31 downto 0);
  signal stat_burst_len_max       : std_logic_vector(31 downto 0);
  signal stat_elapsed_cycles      : std_logic_vector(31 downto 0);
  signal stat_r_stall             : std_logic_vector(31 downto 0);
  signal stat_max_outstanding     : std_logic_vector(31 downto 0);
  signal stat_data_errors         : std_logic_vector(31 downto 0);
  signal stat_id_errors           : std_logic_vector(31 downto 0);
  signal stat_rlast_errors        : std_logic_vector(31 downto 0);
  signal stat_resp_errors         : std_logic_vector(31 downto 0);
  signal stat_sb_underflow_errors : std_logic_vector(31 downto 0);

  -- Generator statistics
  signal gen_stat_ar_stall   : std_logic_vector(31 downto 0);
  signal gen_stat_ar_issued  : std_logic_vector(31 downto 0);
  signal gen_stat_cfg_errors : std_logic_vector(31 downto 0);

begin

  u_axilite : entity work.axilite_io
    generic map (
      GC_NUM_ODATA   => C_NUM_ODATA,
      GC_NUM_IDATA   => C_NUM_IDATA,
      GC_NUM_OSTREAM => 1,
      GC_NUM_ISTREAM => 1
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axi_awaddr  => axilite_awaddr(15 downto 0),
      s_axi_awprot  => axilite_awprot,
      s_axi_awvalid => axilite_awvalid,
      s_axi_awready => axilite_awready,
      s_axi_wdata   => axilite_wdata,
      s_axi_wstrb   => axilite_wstrb,
      s_axi_wvalid  => axilite_wvalid,
      s_axi_wready  => axilite_wready,
      s_axi_bresp   => axilite_bresp,
      s_axi_bvalid  => axilite_bvalid,
      s_axi_bready  => axilite_bready,
      s_axi_araddr  => axilite_araddr(15 downto 0),
      s_axi_arprot  => axilite_arprot,
      s_axi_arvalid => axilite_arvalid,
      s_axi_arready => axilite_arready,
      s_axi_rdata   => axilite_rdata,
      s_axi_rresp   => axilite_rresp,
      s_axi_rvalid  => axilite_rvalid,
      s_axi_rready  => axilite_rready,
      o_data        => o_data,
      i_data        => i_data,
      m_axis_tdata  => open,
      m_axis_tvalid => open,
      s_axis_tdata  => (others => (others => '0')),
      s_axis_tready => open
    );

  -- Output registers -> monitor control / GPIO
  enable        <= o_data(0)(0);
  data_check_en <= o_data(1)(0);
  led           <= o_data(2)(0);

  -- Output registers -> generator control / config
  gen_enable <= o_data(3)(0);
  cfg_id       <= o_data(4)(GC_ID_WIDTH-1 downto 0);
  cfg_arlen  <= o_data(5)(log2ceil(GC_MAX_BURST)-1 downto 0);
  cfg_pace       <= o_data(6);
  cfg_pace_init  <= o_data(7);
  cfg_base_addr(31 downto 0)  <= o_data(8);
  cfg_base_addr(48 downto 32) <= o_data(9)(16 downto 0);
  cfg_addr_range(31 downto 0)  <= o_data(10);
  cfg_addr_range(48 downto 32) <= o_data(11)(16 downto 0);
  cfg_addr_mode  <= o_data(12)(0);

  -- Read-only statistics -> i_data
  i_data(0)  <= stat_ar_seen;
  i_data(1)  <= stat_ar_stall;
  i_data(2)  <= stat_sb_backpressure;
  i_data(3)  <= stat_xactions;
  i_data(4)  <= stat_beats;
  i_data(5)  <= stat_latency_sum(31 downto 0);
  i_data(6)  <= word32(stat_latency_sum, 1);
  i_data(7)  <= stat_latency_min;
  i_data(8)  <= stat_latency_max;
  i_data(9)  <= stat_first_latency_sum(31 downto 0);
  i_data(10) <= word32(stat_first_latency_sum, 1);
  i_data(11) <= stat_first_latency_min;
  i_data(12) <= stat_first_latency_max;
  i_data(13) <= stat_interbeat_gap_sum(31 downto 0);
  i_data(14) <= word32(stat_interbeat_gap_sum, 1);
  i_data(15) <= stat_interbeat_gap_min;
  i_data(16) <= stat_interbeat_gap_max;
  i_data(17) <= stat_burst_len_sum(31 downto 0);
  i_data(18) <= word32(stat_burst_len_sum, 1);
  i_data(19) <= stat_burst_len_min;
  i_data(20) <= stat_burst_len_max;
  i_data(21) <= stat_elapsed_cycles;
  i_data(22) <= stat_r_stall;
  i_data(23) <= stat_max_outstanding;
  i_data(24) <= stat_data_errors;
  i_data(25) <= stat_id_errors;
  i_data(26) <= stat_rlast_errors;
  i_data(27) <= stat_resp_errors;
  i_data(28) <= stat_sb_underflow_errors;
  i_data(29) <= gen_stat_ar_stall;
  i_data(30) <= gen_stat_ar_issued;
  i_data(31) <= gen_stat_cfg_errors;

  -- AR channel:  generator drives, monitor taps, wrapper exposes.
  ar_valid   <= ar_valid_i;
  ar_id      <= ar_id_i;
  ar_addr    <= ar_addr_i;
  ar_len     <= ar_len_i;
  ar_ready_i <= ar_ready;

  u_gen : entity work.axi_ar_gen
    generic map (
      GC_DATA_BYTES => GC_DATA_BYTES,
      GC_ADDR_WIDTH => GC_ADDR_WIDTH,
      GC_ID_WIDTH   => GC_ID_WIDTH,
      GC_MAX_BURST  => GC_MAX_BURST
    )
    port map (
      aclk        => aclk,
      aresetn     => aresetn,
      enable      => gen_enable,
      aperture    => aperture,
      stat_rst    => stat_rst,
      cfg_id        => cfg_id,
      cfg_arlen   => cfg_arlen,
      cfg_pace        => cfg_pace,
      cfg_pace_init   => cfg_pace_init,
      cfg_base_addr   => cfg_base_addr,
      cfg_addr_range  => cfg_addr_range,
      cfg_addr_mode   => cfg_addr_mode,
      ar_valid    => ar_valid_i,
      ar_ready    => ar_ready_i,
      ar_id       => ar_id_i,
      ar_addr     => ar_addr_i,
      ar_len      => ar_len_i,
      ar_size     => ar_size,
      ar_burst    => ar_burst,
      stat_ar_stall   => gen_stat_ar_stall,
      stat_ar_issued  => gen_stat_ar_issued,
      stat_cfg_errors => gen_stat_cfg_errors
    );

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
      stat_rst                => stat_rst,
      err_rst                 => err_rst,
      data_check_en           => data_check_en,
      pipeline_busy           => pipeline_busy,
      ar_valid                => ar_valid_i,
      ar_ready                => ar_ready_i,
      ar_id                   => ar_id_i,
      ar_addr                 => ar_addr_i,
      ar_len                  => ar_len_i,
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
      stat_max_outstanding    => stat_max_outstanding,
      stat_data_errors        => stat_data_errors,
      stat_id_errors          => stat_id_errors,
      stat_rlast_errors       => stat_rlast_errors,
      stat_resp_errors        => stat_resp_errors,
      stat_sb_underflow_errors => stat_sb_underflow_errors
    );

end architecture;
