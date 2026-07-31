-----------------------------------------------------------------------
--Filename         : axi4_read_tester_shim.vhd
--Description      : VHDL-2019 AXI4 wrapper for axi_read_tester with
--                   AXI4-Lite register interface via axilite_io_vhd.
--                   Exposes AR and R as VHDL-2019 mode-view AXI4
--                   interfaces.  All stat_* outputs and control inputs
--                   except enable_global/aperture/stat_rst/err_rst
--                   are connected to the axilite register bank.
--Author           : Rune Bæverrud
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
--  [17]  led (bit 0) — diagnostic GPIO
--
-- i_data (read-only) — GC_STAT_WIDTH ≤ 63 → max 2 words per wide signal:
--  [0]  stat_xactions                 
--  [1]  stat_beats                    
--  [2]  stat_latency_sum (lo)         
--  [3]  stat_latency_sum (hi)         
--  [4]  stat_latency_min  (lo)        
--  [5]  stat_latency_min  (hi)        
--  [6]  stat_latency_max  (lo)        
--  [7]  stat_latency_max  (hi)        
--  [8]  stat_first_latency_sum  (lo)  
--  [9]  stat_first_latency_sum  (hi)  
--  [10] stat_first_latency_min  (lo)  
--  [11] stat_first_latency_min  (hi)
--  [12] stat_first_latency_max  (lo)
--  [13] stat_first_latency_max  (hi)
--  [14] stat_interbeat_gap_sum  (lo)
--  [15] stat_interbeat_gap_sum  (hi)
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
--  [26] stat_pipeline_busy
--  [27] stat_max_outstanding
-- =====================================================================
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;
use work.axi4_pkg.all;
use work.axilite_pkg.all;
-- Note: axilite_io_pkg is not imported here — it re-exports util_pkg items
-- (t_slv32_array, log2ceil) which would collide with the direct util_pkg import.
-- The axilite_io_vhd entity is referenced via work.axilite_io_vhd directly.

entity axi4_read_tester_shim is
  generic (
    GC_DATA_BYTES     : positive := 16;   -- matches axi4_hp_r_t (128-bit rdata)
    GC_ADDR_WIDTH     : positive := 49;   -- matches axi4_hp_ar_t (48:0)
    GC_ID_WIDTH       : positive := 6;    -- matches axi4_hp_ar/r_t (5:0)
    GC_TIME_WIDTH     : positive := 48;
    GC_STAT_WIDTH     : positive := 48;   -- matches i_data split below (2 × 32-bit words)
    GC_SB_FIFO_DEPTH  : positive := 256
  );
  port (
    aclk    : in  std_logic;
    aresetn : in  std_logic;

    -- Global across all testers
    global_time   : in  std_logic_vector(GC_TIME_WIDTH-1 downto 0);
    enable_global : in  std_logic;
    aperture      : in  std_logic;
    stat_rst      : in  std_logic;
    err_rst       : in  std_logic;

    -- Diagnostic LED output (driven by o_data[17], bit 0)
    led : out std_logic;

    -- AXI4-Lite register interface (slave)
    -- axilite_m40_t provides 40-bit addresses; only lower 16 bits
    -- are decoded by the internal axilite_io_vhd (16-bit address map).
    axilite : view slave_axilite of axilite_m40_t;

    -- AXI4 Read-Address channel (master) — HP subtype, ID=6, ADDR=49
    ar : view master_ar of axi4_hp_ar_t;

    -- AXI4 Read-Data channel (slave) — HP subtype, ID=6, DATA=128
    -- NOTE: master_r view because the wrapper IS the AXI master on R
    -- (reads data from the downstream DUT/slave).
    r : view master_r of axi4_hp_r_t
  );
end entity;

architecture rtl of axi4_read_tester_shim is

  --------------------------------------------------------------------
  -- Helper: extract 32-bit word 'w' from a std_logic_vector.
  -- Word 0 = bits 31:0, word 1 = bits 63:32, etc.
  -- Out-of-range bits return '0'; supports STAT_WIDTH ≤ 63.
  --------------------------------------------------------------------
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

  --------------------------------------------------------------------
  -- Register interface signals
  --------------------------------------------------------------------
  -- Register counts — see header table for full register map.
  constant C_NUM_ODATA : natural := 32;
  constant C_NUM_IDATA : natural := 32;

  signal o_data : t_slv32_array(0 to C_NUM_ODATA-1) := (others => (others => '0'));
  signal i_data : t_slv32_array(0 to C_NUM_IDATA-1) := (others => (others => '0'));

  --------------------------------------------------------------------
  -- Control signals (decoded from o_data registers)
  --------------------------------------------------------------------
  signal enable_local : std_logic;
  signal addr_mode    : std_logic;
  signal arid         : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal burst_length : std_logic_vector(31 downto 0);
  signal pace         : std_logic_vector(31 downto 0);
  signal pace_init    : std_logic_vector(31 downto 0);
  signal base_addr    : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal addr_range   : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);

  -- AR configuration signals (from o_data registers)
  signal ar_burst_reg   : std_logic_vector(1 downto 0);
  signal ar_lock_reg    : std_logic;
  signal ar_cache_reg   : std_logic_vector(3 downto 0);
  signal ar_prot_reg    : std_logic_vector(2 downto 0);
  signal ar_qos_reg     : std_logic_vector(3 downto 0);
  signal ar_region_reg  : std_logic_vector(3 downto 0);
  signal ar_user_reg    : std_logic_vector(0 downto 0);

  --------------------------------------------------------------------
  -- AXI scalar signals (between wrapper and axi_read_tester)
  --------------------------------------------------------------------
  signal ar_valid     : std_logic;
  signal ar_ready     : std_logic;
  signal ar_id        : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal ar_addr      : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal ar_len       : std_logic_vector(7 downto 0);

  signal r_valid      : std_logic;
  signal r_ready      : std_logic;
  signal r_id         : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal r_data       : std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
  signal r_resp       : std_logic_vector(1 downto 0);
  signal r_last       : std_logic;

  --------------------------------------------------------------------
  -- Statistics signals (from axi_read_tester to i_data registers)
  --------------------------------------------------------------------
  signal stat_xactions            : std_logic_vector(31 downto 0);
  signal stat_beats               : std_logic_vector(31 downto 0);
  signal stat_latency_sum         : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_latency_min         : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_latency_max         : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_first_latency_sum   : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_first_latency_min   : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_first_latency_max   : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_interbeat_gap_sum   : std_logic_vector(GC_STAT_WIDTH-1 downto 0);
  signal stat_ar_backpressure     : std_logic_vector(31 downto 0);
  signal stat_sb_backpressure     : std_logic_vector(31 downto 0);
  signal stat_ar_issued           : std_logic_vector(31 downto 0);
  signal stat_cfg_errors          : std_logic_vector(31 downto 0);
  signal stat_elapsed_cycles      : std_logic_vector(31 downto 0);
  signal pipeline_busy       : std_logic;
  signal stat_max_outstanding     : std_logic_vector(31 downto 0);
  signal stat_data_errors         : std_logic_vector(31 downto 0);
  signal stat_id_errors           : std_logic_vector(31 downto 0);
  signal stat_rlast_errors        : std_logic_vector(31 downto 0);
  signal stat_resp_errors         : std_logic_vector(31 downto 0);
  signal stat_sb_underflow_errors : std_logic_vector(31 downto 0);

begin

  --------------------------------------------------------------------
  -- Register interface (axilite_io_vhd)
  --------------------------------------------------------------------
  u_axilite : entity work.axilite_io_vhd
    generic map (
      GC_NUM_ODATA   => C_NUM_ODATA,
      GC_NUM_IDATA   => C_NUM_IDATA,
      GC_NUM_OSTREAM => 1,
      GC_NUM_ISTREAM => 1
    )
    port map (
      s_axi_aclk    => aclk,
      s_axi_aresetn => aresetn,

      -- axilite_m40_t uses 40-bit addresses; axilite_io_vhd decodes
      -- only the lower 16 bits (awaddr(15:14) for space select).
      s_axi_awaddr  => axilite.awaddr(15 downto 0),
      s_axi_awprot  => axilite.awprot,
      s_axi_awvalid => axilite.awvalid,
      s_axi_awready => axilite.awready,
      s_axi_wdata   => axilite.wdata,
      s_axi_wstrb   => axilite.wstrb,
      s_axi_wvalid  => axilite.wvalid,
      s_axi_wready  => axilite.wready,
      s_axi_bresp   => axilite.bresp,
      s_axi_bvalid  => axilite.bvalid,
      s_axi_bready  => axilite.bready,
      s_axi_araddr  => axilite.araddr(15 downto 0),
      s_axi_arprot  => axilite.arprot,
      s_axi_arvalid => axilite.arvalid,
      s_axi_arready => axilite.arready,
      s_axi_rdata   => axilite.rdata,
      s_axi_rresp   => axilite.rresp,
      s_axi_rvalid  => axilite.rvalid,
      s_axi_rready  => axilite.rready,

      o_data        => o_data,
      i_data        => i_data,
      m_axis_tdata  => open,
      m_axis_tvalid => open,
      s_axis_tdata  => (others => (others => '0')),
      s_axis_tready => open
    );

  --------------------------------------------------------------------
  -- Register decode — o_data (writable) to control signals
  --------------------------------------------------------------------
  enable_local    <= o_data(0)(0);
  addr_mode       <= o_data(1)(0);
  arid            <= o_data(2)(GC_ID_WIDTH-1 downto 0);
  burst_length    <= o_data(3);
  pace            <= o_data(4);
  pace_init       <= o_data(5);

  -- base_addr (49-bit, assembled from 2 register words)
  base_addr(31 downto 0)  <= o_data(6);
  base_addr(48 downto 32) <= o_data(7)(16 downto 0);

  -- addr_range (49-bit, assembled from 2 register words)
  addr_range(31 downto 0)  <= o_data(8);
  addr_range(48 downto 32) <= o_data(9)(16 downto 0);

  -- AR AXI configuration fields
  -- arsize is not a register — derived from GC_DATA_BYTES in the
  -- AR channel connection block below.
  ar_burst_reg   <= o_data(10)(1 downto 0);
  ar_lock_reg    <= o_data(11)(0);
  ar_cache_reg   <= o_data(12)(3 downto 0);
  ar_prot_reg    <= o_data(13)(2 downto 0);
  ar_qos_reg     <= o_data(14)(3 downto 0);
  ar_region_reg  <= o_data(15)(3 downto 0);
  ar_user_reg(0) <= o_data(16)(0);

  -- Diagnostic LED
  led <= o_data(17)(0);

  --------------------------------------------------------------------
  -- Register decode — stat signals to i_data (read-only)
  --------------------------------------------------------------------
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
  i_data(26) <= (0 => pipeline_busy, others => '0');
  i_data(27) <= stat_max_outstanding;

  --------------------------------------------------------------------
  -- axi_read_tester instantiation
  --------------------------------------------------------------------
  u_tester : entity work.axi_read_tester
    generic map (
      GC_DATA_BYTES    => GC_DATA_BYTES,
      GC_ADDR_WIDTH    => GC_ADDR_WIDTH,
      GC_ID_WIDTH      => GC_ID_WIDTH,
      GC_TIME_WIDTH    => GC_TIME_WIDTH,
      GC_STAT_WIDTH    => GC_STAT_WIDTH,
      GC_SB_FIFO_DEPTH => GC_SB_FIFO_DEPTH
    )
    port map (
      -- Clock / reset
      aclk                    => aclk,
      aresetn                 => aresetn,
      global_time             => global_time,

      -- Tester control (direct top-level pass-through)
      enable_global           => enable_global,
      enable_local            => enable_local,    -- via o_data[0]
      aperture                => aperture,
      stat_rst                => stat_rst,
      err_rst                 => err_rst,

      -- AR generator configuration (all via axilite registers)
      arid                    => arid,            -- o_data[2]
      burst_length            => burst_length,    -- o_data[3]
      pace                    => pace,            -- o_data[4]
      pace_init               => pace_init,       -- o_data[5]
      base_addr               => base_addr,       -- o_data[6..7]
      addr_range              => addr_range,      -- o_data[8..9]
      addr_mode               => addr_mode,       -- o_data[1]

      -- AXI Read-Address channel → DUT
      ar_valid                => ar_valid,
      ar_ready                => ar_ready,
      ar_id                   => ar_id,
      ar_addr                 => ar_addr,
      ar_len                  => ar_len,

      -- AXI Read-Data channel ← DUT
      r_valid                 => r_valid,
      r_ready                 => r_ready,
      r_id                    => r_id,
      r_data                  => r_data,
      r_resp                  => r_resp,
      r_last                  => r_last,

      -- Statistics outputs → i_data (readable via axilite)
      stat_xactions           => stat_xactions,             -- i_data[0]
      stat_beats              => stat_beats,                -- i_data[1]
      stat_latency_sum        => stat_latency_sum,          -- i_data[2..3]
      stat_latency_min        => stat_latency_min,          -- i_data[4..5]
      stat_latency_max        => stat_latency_max,          -- i_data[6..7]
      stat_first_latency_sum  => stat_first_latency_sum,    -- i_data[8..9]
      stat_first_latency_min  => stat_first_latency_min,    -- i_data[10..11]
      stat_first_latency_max  => stat_first_latency_max,    -- i_data[12..13]
      stat_interbeat_gap_sum  => stat_interbeat_gap_sum,    -- i_data[14..15]
      stat_ar_backpressure    => stat_ar_backpressure,      -- i_data[16]
      stat_sb_backpressure    => stat_sb_backpressure,      -- i_data[17]
      stat_ar_issued          => stat_ar_issued,            -- i_data[18]
      stat_cfg_errors         => stat_cfg_errors,           -- i_data[19]
      stat_elapsed_cycles     => stat_elapsed_cycles,       -- i_data[20]
      pipeline_busy      => pipeline_busy,        -- i_data[26]
      stat_max_outstanding    => stat_max_outstanding,      -- i_data[27]
      stat_data_errors        => stat_data_errors,          -- i_data[21]
      stat_id_errors          => stat_id_errors,            -- i_data[22]
      stat_rlast_errors       => stat_rlast_errors,         -- i_data[23]
      stat_resp_errors        => stat_resp_errors,          -- i_data[24]
      stat_sb_underflow_errors => stat_sb_underflow_errors  -- i_data[25]
    );

  --------------------------------------------------------------------
  -- AXI4 AR channel — master-side connections
  --
  -- Driven from tester: arid, araddr, arlen, arvalid.
  -- Driven from axilite registers: arburst, arlock, arcache,
  --   arprot, arqos, arregion, aruser.
  -- Computed from GC_DATA_BYTES: arsize (= log2(bytes)).
  -- Read from slave: arready.
  --------------------------------------------------------------------
  ar.arid     <= ar_id;
  ar.araddr   <= ar_addr;
  ar.arlen    <= ar_len;
  ar.arsize   <= std_logic_vector(to_unsigned(log2ceil(GC_DATA_BYTES), 3));
  ar.arburst  <= ar_burst_reg;
  ar.arlock   <= ar_lock_reg;
  ar.arcache  <= ar_cache_reg;
  ar.arprot   <= ar_prot_reg;
  ar.arqos    <= ar_qos_reg;
  ar.arregion <= ar_region_reg;
  ar.aruser   <= ar_user_reg;
  ar.arvalid  <= ar_valid;
  ar_ready    <= ar.arready;

  --------------------------------------------------------------------
  -- AXI4 R channel — master-side connections (master_r view).
  --
  -- Read from slave: rid, rdata, rresp, rlast, rvalid.
  -- ruser is available but not checked by the tester (undriven input
  -- at the boundary — left unconnected in the architecture).
  -- Driven to slave: rready.
  --------------------------------------------------------------------
  r_valid <= r.rvalid;
  r.rready <= r_ready;
  r_id    <= r.rid;
  r_data  <= r.rdata;
  r_resp  <= r.rresp;
  r_last  <= r.rlast;
  -- r.ruser — not used by this tester

end architecture;
