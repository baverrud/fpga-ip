-----------------------------------------------------------------------
--Filename         : axi4_read_tester_multi.vhd
--Description      : Multiple AXI4 read tester shims instantiated via
--                   VHDL-2019 generate with individual scalar mode-view
--                   ports per instance. An extra axilite_ctrl port
--                   drives an axilite_io register bank for multi-
--                   level control (aperture, stat_rst, err_rst).
--                   Some simulators do not support mode views on array
--                   types, so each instance gets dedicated ports.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;
use work.axi4_pkg.all;
use work.axilite_pkg.all;

entity axi4_read_tester_multi is
  generic (
    GC_DATA_BYTES     : positive := 16;
    GC_ADDR_WIDTH     : positive := 49;
    GC_ID_WIDTH       : positive := 6;
    GC_TIME_WIDTH     : positive := 48;
    GC_STAT_WIDTH     : positive := 48;
    GC_SB_FIFO_DEPTH  : positive := 256;
    GC_MAX_BURST      : positive := 256   -- max beats per burst: 256 (AXI4) / 16 (AXI3)
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- AXI4-Lite register interfaces (slave) -- one per shim instance
 -- Original intent (array mode views are not supported by all simulators):
 -- axilite   : view (slave) of axilite_m40_array_t(0 to GC_NUM_INSTANCES-1);
    axilite_0 : view slave_axilite of axilite_m40_t;
    axilite_1 : view slave_axilite of axilite_m40_t;
    axilite_2 : view slave_axilite of axilite_m40_t;
    axilite_3 : view slave_axilite of axilite_m40_t;

    -- AXI4 Read-Address channels (master) -- one per shim instance
 -- Original intent:
 -- ar : view (master) of axi4_hp_ar_array_t(0 to GC_NUM_INSTANCES-1);
    ar_0 : view master_ar of axi4_hp_ar_t;
    ar_1 : view master_ar of axi4_hp_ar_t;
    ar_2 : view master_ar of axi4_hp_ar_t;
    ar_3 : view master_ar of axi4_hp_ar_t;

    -- AXI4 Read-Data channels (master) -- one per shim instance
 -- Original intent:
 -- r   : view (master) of axi4_hp_r_array_t(0 to GC_NUM_INSTANCES-1);
    r_0 : view master_r of axi4_hp_r_t;
    r_1 : view master_r of axi4_hp_r_t;
    r_2 : view master_r of axi4_hp_r_t;
    r_3 : view master_r of axi4_hp_r_t;

    -- Extra AXI4-Lite register interface for multi-level control
    -- (drives aperture, stat_rst, err_rst)
    axilite_ctrl : view slave_axilite of axilite_m40_t;

    -- Diagnostic LED outputs
    --   led(3:0) = per-shim-instance LEDs
    --   led(4)   = software-controlled via o_data(3)(0)
    led : out std_logic_vector(4 downto 0);

    -- Pipeline busy outputs -- one per shim instance
    pipeline_busy : out std_logic_vector(0 to 3)
  );
end entity;

architecture rtl of axi4_read_tester_multi is

  constant C_NUM_INSTANCES : natural := 4;
  constant C_NUM_ODATA     : natural := 4;   -- o_data[0..3]: one function per register
  constant C_NUM_IDATA     : natural := 2;   -- i_data[0..1] for status readback

  signal global_time   : unsigned(GC_TIME_WIDTH-1 downto 0) := (others => '0');
  signal aperture      : std_logic;
  signal stat_rst      : std_logic;
  signal err_rst       : std_logic;

  signal o_data : t_slv32_array(0 to C_NUM_ODATA-1);
  signal i_data : t_slv32_array(0 to C_NUM_IDATA-1) := (others => (others => '0'));

  signal led_int : std_logic_vector(0 to C_NUM_INSTANCES-1);
  signal pipeline_busy_int : std_logic_vector(0 to C_NUM_INSTANCES-1);

  -- AXI bus arrays for internal generate wiring
  signal axilite : axilite_m40_array_t(0 to C_NUM_INSTANCES-1);
  signal ar      : axi4_hp_ar_array_t(0 to C_NUM_INSTANCES-1);
  signal r       : axi4_hp_r_array_t(0 to C_NUM_INSTANCES-1);

begin

  --------------------------------------------------------------------
  -- Multi-level control: axilite_io register bank on axilite_ctrl
  --
  -- Register map (one function per register):
  --   o_data[0]  : aperture
  --   o_data[1]  : stat_rst
  --   o_data[2]  : err_rst
  --   o_data[3]  : extra LED (led(4))
  --   i_data[0]  : global_time[31:0]
  --   i_data[1]  : global_time[47:32]
  --------------------------------------------------------------------
  aperture      <= o_data(0)(0);
  stat_rst      <= o_data(1)(0);
  err_rst       <= o_data(2)(0);

  i_data(0) <= std_logic_vector(global_time(31 downto 0));
  i_data(1) <= std_logic_vector(resize(global_time(47 downto 32), 32));

  u_ctrl_io : entity work.axilite_io
    generic map (
      GC_NUM_ODATA   => C_NUM_ODATA,
      GC_NUM_IDATA   => C_NUM_IDATA,
      GC_NUM_OSTREAM => 1,
      GC_NUM_ISTREAM => 1
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axi_awaddr  => axilite_ctrl.awaddr(15 downto 0),
      s_axi_awprot  => axilite_ctrl.awprot,
      s_axi_awvalid => axilite_ctrl.awvalid,
      s_axi_awready => axilite_ctrl.awready,
      s_axi_wdata   => axilite_ctrl.wdata,
      s_axi_wstrb   => axilite_ctrl.wstrb,
      s_axi_wvalid  => axilite_ctrl.wvalid,
      s_axi_wready  => axilite_ctrl.wready,
      s_axi_bresp   => axilite_ctrl.bresp,
      s_axi_bvalid  => axilite_ctrl.bvalid,
      s_axi_bready  => axilite_ctrl.bready,
      s_axi_araddr  => axilite_ctrl.araddr(15 downto 0),
      s_axi_arprot  => axilite_ctrl.arprot,
      s_axi_arvalid => axilite_ctrl.arvalid,
      s_axi_arready => axilite_ctrl.arready,
      s_axi_rdata   => axilite_ctrl.rdata,
      s_axi_rresp   => axilite_ctrl.rresp,
      s_axi_rvalid  => axilite_ctrl.rvalid,
      s_axi_rready  => axilite_ctrl.rready,
      o_data        => o_data,
      i_data        => i_data,
      m_axis_tdata  => open,
      m_axis_tvalid => open,
      s_axis_tdata  => (others => (others => '0')),
      s_axis_tready => open
    );

  --------------------------------------------------------------------
  -- Map individual mode-view ports to internal record arrays
  --------------------------------------------------------------------
  axilite(0) <= axilite_0;
  axilite(1) <= axilite_1;
  axilite(2) <= axilite_2;
  axilite(3) <= axilite_3;

  ar(0) <= ar_0;
  ar(1) <= ar_1;
  ar(2) <= ar_2;
  ar(3) <= ar_3;

  r(0) <= r_0;
  r(1) <= r_1;
  r(2) <= r_2;
  r(3) <= r_3;

  --------------------------------------------------------------------
  -- LED output mapping
  --   led(4)   = software-controlled via o_data(3)(0)
  --   led(3:0) = per-shim-instance diagnostic LEDs
  --------------------------------------------------------------------
  led <= o_data(3)(0) & led_int;

  pipeline_busy <= pipeline_busy_int;

  --------------------------------------------------------------------
  -- Global time counter
  --------------------------------------------------------------------
  p_global_time : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        global_time <= (others => '0');
      else
        global_time <= global_time + 1;
      end if;
    end if;
  end process;

  --------------------------------------------------------------------
  -- Shim array
  --------------------------------------------------------------------
  g_shims : for i in 0 to C_NUM_INSTANCES-1 generate
  begin

    u_shim : entity work.axi4_read_tester_shim
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
        aclk           => aclk,
        aresetn        => aresetn,
        global_time    => global_time,
        aperture       => aperture,
        stat_rst       => stat_rst,
        err_rst        => err_rst,
        axilite        => axilite(i),
        ar             => ar(i),
        r              => r(i),
        led            => led_int(i),
        pipeline_busy  => pipeline_busy_int(i)
      );

  end generate;

end architecture;
