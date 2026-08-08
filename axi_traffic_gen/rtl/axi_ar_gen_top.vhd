-----------------------------------------------------------------------
--Filename         : axi_ar_gen_top.vhd
--Description      : Synthesis Wrapper and Instantiation Top-Level for
--                 : axi_ar_gen.  Passes the AXI configuration generics
--                 : through and exposes the AR channel plus runtime
--                 : configuration and statistics ports.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_ar_gen_top is
  generic (
    GC_DATA_BYTES : positive := 16;
    GC_ADDR_WIDTH : positive := 49;
    GC_ID_WIDTH   : positive := 6;
    GC_MAX_BURST  : positive := 256  -- max beats per burst: 256 (AXI4) / 16 (AXI3)
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Control
    enable   : in std_logic;  -- per-instance enable
    aperture : in std_logic;  -- measurement window
    stat_rst : in std_logic;  -- clears statistic counters

    -- Runtime configuration
    cfg_id         : in std_logic_vector(GC_ID_WIDTH-1 downto 0);
    cfg_arlen      : in std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);  -- AXI arlen (beats-1); 0 = 1 beat
    cfg_pace       : in std_logic_vector(31 downto 0);                        -- idle cycles between ARs
    cfg_pace_init  : in std_logic_vector(31 downto 0);                        -- delay before first burst
    cfg_base_addr  : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    cfg_addr_range : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    cfg_addr_mode  : in std_logic;                                            -- '0' = linear sweep, '1' = pseudo-random

    -- AXI Read-Address Channel (master -> DUT)
    ar_valid : out std_logic;
    ar_ready : in  std_logic;
    ar_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : out std_logic_vector(7 downto 0);                -- beats-1
    ar_size  : out std_logic_vector(2 downto 0);                -- bytes per beat
    ar_burst : out std_logic_vector(1 downto 0);                -- always INCR

    -- Statistics (plain register reads, no pipeline latency)
    stat_ar_stall   : out std_logic_vector(31 downto 0);
    stat_ar_issued  : out std_logic_vector(31 downto 0);
    stat_cfg_errors : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of axi_ar_gen_top is
begin

  u_axi_ar_gen : entity work.axi_ar_gen
    generic map (
      GC_DATA_BYTES => GC_DATA_BYTES,
      GC_ADDR_WIDTH => GC_ADDR_WIDTH,
      GC_ID_WIDTH   => GC_ID_WIDTH,
      GC_MAX_BURST  => GC_MAX_BURST
    )
    port map (
      -- Clock and reset
      aclk    => aclk,
      aresetn => aresetn,

      -- Control
      enable   => enable,
      aperture => aperture,
      stat_rst => stat_rst,

      -- Runtime configuration
      cfg_id         => cfg_id,
      cfg_arlen      => cfg_arlen,
      cfg_pace       => cfg_pace,
      cfg_pace_init  => cfg_pace_init,
      cfg_base_addr  => cfg_base_addr,
      cfg_addr_range => cfg_addr_range,
      cfg_addr_mode  => cfg_addr_mode,

      -- AXI Read-Address Channel
      ar_valid => ar_valid,
      ar_ready => ar_ready,
      ar_id    => ar_id,
      ar_addr  => ar_addr,
      ar_len   => ar_len,
      ar_size  => ar_size,
      ar_burst => ar_burst,

      -- Statistics
      stat_ar_stall   => stat_ar_stall,
      stat_ar_issued  => stat_ar_issued,
      stat_cfg_errors => stat_cfg_errors
    );

end architecture;
