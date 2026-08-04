-----------------------------------------------------------------------
--Filename         : axi_read_tester_reg.vhd
--Description      : VHDL-2008 AXI4 wrapper for axi_read_tester with
--                   AXI4-Lite register interface via axilite_io.
--                   Exposes AXI4-Lite, AR, and R buses as individual
--                   signals for broad tool compatibility.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
--
-- =====================================================================
-- Register Map  (axilite_m40_t, decoding lower 16 addr bits only)
--
-- o_data (writable):
--  [0]   enable_local
--  [1]   addr_mode
--  [2]   arid
--  [3]   burst_length
--  [4]   pace
--  [5]   pace_init
--  [6]   base_addr[31:0]
--  [7]   base_addr[48:32]
--  [8]   addr_range[31:0]
--  [9]   addr_range[48:32]
--  [10]  arburst
--  [11]  arlock
--  [12]  arcache
--  [13]  arprot
--  [14]  arqos
--  [15]  arregion
--  [16]  aruser
--  [17]  led (bit 0) - diagnostic GPIO
--
-- i_data (read-only) - GC_STAT_WIDTH <= 63 -> max 2 words per wide signal:
--  [0]  stat_xactions
--  [1]  stat_beats
--  [2]  stat_latency_sum (lo)
--  [3]  stat_latency_sum (hi)
--  [4]  stat_latency_min (lo)
--  [5]  stat_latency_min (hi)
--  [6]  stat_latency_max (lo)
--  [7]  stat_latency_max (hi)
--  [8]  stat_first_latency_sum (lo)
--  [9]  stat_first_latency_sum (hi)
--  [10] stat_first_latency_min (lo)
--  [11] stat_first_latency_min (hi)
--  [12] stat_first_latency_max (lo)
--  [13] stat_first_latency_max (hi)
--  [14] stat_interbeat_gap_sum (lo)
--  [15] stat_interbeat_gap_sum (hi)
--  [16] stat_ar_backpressure
--  [17] stat_sb_backpressure
--  [18] stat_ar_issued
--  [19] stat_cfg_errors
--  [20] stat_elapsed_cycles
--  [21] stat_data_errors
--  [22] stat_id_errors
--  [23] stat_rlast_errors
--  [24] stat_resp_errors
--  [25] stat_sb_underflow_errors
--  [26] stat_max_outstanding
--  [27] stat_interbeat_gap_min
--  [28] stat_interbeat_gap_max
--
-- pipeline_busy is exposed as an output port (not readable via i_data).
-- =====================================================================
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_tester_reg is
  generic (
    GC_DATA_BYTES     : positive := 16;   -- matches axi4_hp_r_t (128-bit rdata)
    GC_ADDR_WIDTH     : positive := 49;   -- matches axi4_hp_ar_t (48:0)
    GC_ID_WIDTH       : positive := 6;    -- matches axi4_hp_ar/r_t (5:0)
    GC_TIME_WIDTH     : positive := 48;
    GC_STAT_WIDTH     : positive := 48;   -- matches i_data split below (2 x 32-bit words)
    GC_SB_FIFO_DEPTH  : positive := 256;
    GC_MAX_BURST      : positive := 256   -- max beats per burst: 256 (AXI4) / 16 (AXI3)
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Global across all testers
    global_time   : in unsigned(GC_TIME_WIDTH-1 downto 0);
    aperture      : in std_logic;
    stat_rst      : in std_logic;
    err_rst       : in std_logic;

    -- Diagnostic LED output (driven by o_data[17], bit 0)
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

    -- AXI4 read-address channel (master)
    ar_id           : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr         : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len          : out std_logic_vector(7 downto 0);
    ar_size         : out std_logic_vector(2 downto 0);
    ar_burst        : out std_logic_vector(1 downto 0);
    ar_lock         : out std_logic;
    ar_cache        : out std_logic_vector(3 downto 0);
    ar_prot         : out std_logic_vector(2 downto 0);
    ar_qos          : out std_logic_vector(3 downto 0);
    ar_region       : out std_logic_vector(3 downto 0);
    ar_user         : out std_logic_vector(0 downto 0);
    ar_valid        : out std_logic;
    ar_ready        : in  std_logic;

    -- AXI4 read-data channel (slave)
    r_id            : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data          : in  std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp          : in  std_logic_vector(1 downto 0);
    r_last          : in  std_logic;
    r_user          : in  std_logic_vector(0 downto 0);
    r_valid         : in  std_logic;
    r_ready         : out std_logic
  );
end entity;

architecture rtl of axi_read_tester_reg is

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

  constant C_NUM_ODATA : natural := 32;
  constant C_NUM_IDATA : natural := 29;

  signal o_data : t_slv32_array(0 to C_NUM_ODATA-1) := (others => (others => '0'));
  signal i_data : t_slv32_array(0 to C_NUM_IDATA-1) := (others => (others => '0'));

  signal enable_local     : std_logic;
  signal addr_mode        : std_logic;
  signal arid             : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal burst_length     : std_logic_vector(31 downto 0);
  signal pace              : std_logic_vector(31 downto 0);
  signal pace_init         : std_logic_vector(31 downto 0);
  signal base_addr        : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal addr_range       : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);

  signal ar_burst_reg     : std_logic_vector(1 downto 0);
  signal ar_lock_reg      : std_logic;
  signal ar_cache_reg     : std_logic_vector(3 downto 0);
  signal ar_prot_reg      : std_logic_vector(2 downto 0);
  signal ar_qos_reg       : std_logic_vector(3 downto 0);
  signal ar_region_reg    : std_logic_vector(3 downto 0);
  signal ar_user_reg      : std_logic_vector(0 downto 0);

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
  signal stat_ar_backpressure     : std_logic_vector(31 downto 0);
  signal stat_sb_backpressure     : std_logic_vector(31 downto 0);
  signal stat_ar_issued           : std_logic_vector(31 downto 0);
  signal stat_cfg_errors           : std_logic_vector(31 downto 0);
  signal stat_elapsed_cycles      : std_logic_vector(31 downto 0);
  signal stat_max_outstanding     : std_logic_vector(31 downto 0);
  signal stat_data_errors         : std_logic_vector(31 downto 0);
  signal stat_id_errors           : std_logic_vector(31 downto 0);
  signal stat_rlast_errors        : std_logic_vector(31 downto 0);
  signal stat_resp_errors         : std_logic_vector(31 downto 0);
  signal stat_sb_underflow_errors : std_logic_vector(31 downto 0);

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

  enable_local    <= o_data(0)(0);
  addr_mode       <= o_data(1)(0);
  arid            <= o_data(2)(GC_ID_WIDTH-1 downto 0);
  burst_length    <= o_data(3);
  pace            <= o_data(4);
  pace_init       <= o_data(5);

  base_addr(31 downto 0)  <= o_data(6);
  base_addr(48 downto 32) <= o_data(7)(16 downto 0);

  addr_range(31 downto 0)  <= o_data(8);
  addr_range(48 downto 32) <= o_data(9)(16 downto 0);

  ar_burst_reg   <= o_data(10)(1 downto 0);
  ar_lock_reg    <= o_data(11)(0);
  ar_cache_reg   <= o_data(12)(3 downto 0);
  ar_prot_reg    <= o_data(13)(2 downto 0);
  ar_qos_reg     <= o_data(14)(3 downto 0);
  ar_region_reg  <= o_data(15)(3 downto 0);
  ar_user_reg(0) <= o_data(16)(0);

  led <= o_data(17)(0);

  i_data(0)  <= stat_xactions;
  i_data(1)  <= stat_beats;
  i_data(2)  <= stat_latency_sum(31 downto 0);
  i_data(3)  <= word32(stat_latency_sum, 1);
  i_data(4)  <= stat_latency_min(31 downto 0);
  i_data(5)  <= word32(stat_latency_min, 1);
  i_data(6)  <= stat_latency_max(31 downto 0);
  i_data(7)  <= word32(stat_latency_max, 1);
  i_data(8)  <= stat_first_latency_sum(31 downto 0);
  i_data(9)  <= word32(stat_first_latency_sum, 1);
  i_data(10) <= stat_first_latency_min(31 downto 0);
  i_data(11) <= word32(stat_first_latency_min, 1);
  i_data(12) <= stat_first_latency_max(31 downto 0);
  i_data(13) <= word32(stat_first_latency_max, 1);
  i_data(14) <= stat_interbeat_gap_sum(31 downto 0);
  i_data(15) <= word32(stat_interbeat_gap_sum, 1);
  i_data(16) <= stat_ar_backpressure;
  i_data(17) <= stat_sb_backpressure;
  i_data(18) <= stat_ar_issued;
  i_data(19) <= stat_cfg_errors;
  i_data(20) <= stat_elapsed_cycles;
  i_data(21) <= stat_data_errors;
  i_data(22) <= stat_id_errors;
  i_data(23) <= stat_rlast_errors;
  i_data(24) <= stat_resp_errors;
  i_data(25) <= stat_sb_underflow_errors;
  i_data(26) <= stat_max_outstanding;
  i_data(27) <= stat_interbeat_gap_min;
  i_data(28) <= stat_interbeat_gap_max;

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
      aclk                    => aclk,
      aresetn                 => aresetn,
      global_time             => global_time,
      enable_local            => enable_local,
      aperture                => aperture,
      stat_rst                => stat_rst,
      err_rst                 => err_rst,
      arid                    => arid,
      burst_length            => burst_length,
      pace                    => pace,
      pace_init               => pace_init,
      base_addr               => base_addr,
      addr_range              => addr_range,
      addr_mode               => addr_mode,
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
      stat_ar_backpressure    => stat_ar_backpressure,
      stat_sb_backpressure    => stat_sb_backpressure,
      stat_ar_issued          => stat_ar_issued,
      stat_cfg_errors          => stat_cfg_errors,
      stat_elapsed_cycles      => stat_elapsed_cycles,
      pipeline_busy            => pipeline_busy,
      stat_max_outstanding     => stat_max_outstanding,
      stat_data_errors         => stat_data_errors,
      stat_id_errors           => stat_id_errors,
      stat_rlast_errors        => stat_rlast_errors,
      stat_resp_errors         => stat_resp_errors,
      stat_sb_underflow_errors => stat_sb_underflow_errors
    );

  ar_size   <= std_logic_vector(to_unsigned(log2ceil(GC_DATA_BYTES), 3));
  ar_burst  <= ar_burst_reg;
  ar_lock   <= ar_lock_reg;
  ar_cache  <= ar_cache_reg;
  ar_prot   <= ar_prot_reg;
  ar_qos    <= ar_qos_reg;
  ar_region <= ar_region_reg;
  ar_user   <= ar_user_reg;

end architecture;
