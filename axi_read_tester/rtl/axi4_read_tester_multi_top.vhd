-----------------------------------------------------------------------
--Filename         : axi4_read_tester_multi_top.vhd
--Description      : Synthesis top for axi4_read_tester_multi.
--                   Passes all AXI4 and AXI4-Lite interfaces through
--                   to the entity boundary for connection to AXI
--                   interconnect / PS in a real design.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;
use work.axi4_pkg.all;
use work.axilite_pkg.all;

entity axi4_read_tester_multi_top is
  generic (
    GC_DATA_BYTES     : positive := 16;
    GC_ADDR_WIDTH     : positive := 49;
    GC_ID_WIDTH       : positive := 6;
    GC_TIME_WIDTH     : positive := 48;
    GC_STAT_WIDTH     : positive := 48;
    GC_SB_FIFO_DEPTH  : positive := 256
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- AXI4-Lite register interfaces (slave) — one per shim instance
    axilite_0 : view slave_axilite of axilite_m40_t;
    axilite_1 : view slave_axilite of axilite_m40_t;
    axilite_2 : view slave_axilite of axilite_m40_t;
    axilite_3 : view slave_axilite of axilite_m40_t;

    -- AXI4 Read-Address channels (master) — one per shim instance
    ar_0 : view master_ar of axi4_hp_ar_t;
    ar_1 : view master_ar of axi4_hp_ar_t;
    ar_2 : view master_ar of axi4_hp_ar_t;
    ar_3 : view master_ar of axi4_hp_ar_t;

    -- AXI4 Read-Data channels (master) — one per shim instance
    r_0 : view master_r of axi4_hp_r_t;
    r_1 : view master_r of axi4_hp_r_t;
    r_2 : view master_r of axi4_hp_r_t;
    r_3 : view master_r of axi4_hp_r_t;

    -- Extra AXI4-Lite register interface for multi-level control
    axilite_ctrl : view slave_axilite of axilite_m40_t;

    -- Diagnostic LED outputs
    led : out std_logic_vector(4 downto 0)
  );
end entity;

architecture rtl of axi4_read_tester_multi_top is
begin

  u_multi : entity work.axi4_read_tester_multi
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
      axilite_0      => axilite_0,
      axilite_1      => axilite_1,
      axilite_2      => axilite_2,
      axilite_3      => axilite_3,
      ar_0           => ar_0,
      ar_1           => ar_1,
      ar_2           => ar_2,
      ar_3           => ar_3,
      r_0            => r_0,
      r_1            => r_1,
      r_2            => r_2,
      r_3            => r_3,
      axilite_ctrl   => axilite_ctrl,
      led            => led
    );

end architecture;
