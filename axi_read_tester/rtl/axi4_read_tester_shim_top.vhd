-----------------------------------------------------------------------
--Filename         : axi4_read_tester_shim_top.vhd
--Description      : Synthesis top for axi4_read_tester_shim.
--                   Passes all AXI4 and AXI4-Lite interfaces through
--                   to the entity boundary for connection to AXI
--                   interconnect / PS in a real design.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;
use work.axi4_pkg.all;
use work.axilite_pkg.all;

entity axi4_read_tester_shim_top is
  generic (
    GC_DATA_BYTES     : positive := 16;
    GC_ADDR_WIDTH     : positive := 49;
    GC_ID_WIDTH       : positive := 6;
    GC_TIME_WIDTH     : positive := 48;
    GC_STAT_WIDTH     : positive := 48;
    GC_SB_FIFO_DEPTH  : positive := 256
  );
  port (
    aclk    : in  std_logic;
    aresetn : in  std_logic;

    -- Global time (drive from a free-running counter in the design)
    global_time   : in  std_logic_vector(GC_TIME_WIDTH-1 downto 0);
    enable_global : in  std_logic;
    aperture      : in  std_logic;
    stat_rst      : in  std_logic;
    err_rst       : in  std_logic;

    -- Diagnostic LED
    led : out std_logic;

    -- AXI4-Lite register interface (slave -- connect to PS or AXI interconnect)
    axilite : view slave_axilite of axilite_m40_t;

    -- AXI4 Read-Address channel (master -- connect to AXI interconnect or DUT)
    ar : view master_ar of axi4_hp_ar_t;

    -- AXI4 Read-Data channel (slave -- connect to AXI interconnect or DUT)
    r : view master_r of axi4_hp_r_t
  );
end entity;

architecture rtl of axi4_read_tester_shim_top is
begin

  u_shim : entity work.axi4_read_tester_shim
    generic map (
      GC_DATA_BYTES    => GC_DATA_BYTES,
      GC_ADDR_WIDTH    => GC_ADDR_WIDTH,
      GC_ID_WIDTH      => GC_ID_WIDTH,
      GC_TIME_WIDTH    => GC_TIME_WIDTH,
      GC_STAT_WIDTH    => GC_STAT_WIDTH,
      GC_SB_FIFO_DEPTH => GC_SB_FIFO_DEPTH
    )
    port map (
      aclk           => aclk,
      aresetn        => aresetn,
      global_time    => global_time,
      enable_global  => enable_global,
      aperture       => aperture,
      stat_rst       => stat_rst,
      err_rst        => err_rst,
      axilite        => axilite,
      ar             => ar,
      r              => r,
      led            => led
    );

end architecture;
