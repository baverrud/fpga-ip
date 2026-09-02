-----------------------------------------------------------------------
--Filename         : axi_req_gen_top.vhd
--Description      : Synthesis Wrapper and Instantiation Top-Level for
--                 : axi_req_gen.  Passes the configuration generics
--                 : through and exposes the req channel plus runtime
--                 : configuration and statistics ports.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_req_gen_top is
  generic (
    GC_DATA_BYTES : positive := 64;
    GC_ADDR_WIDTH : positive := 32;
    GC_MAX_BURST  : positive := 32   -- max beats per burst (credit-limited)
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Control
    enable   : in std_logic;  -- per-instance enable
    aperture : in std_logic;  -- measurement window
    stat_rst : in std_logic;  -- clears statistic counters

    -- Runtime configuration
    cfg_req_len    : in std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);  -- beats-1; 0 = 1 beat
    cfg_len_mode   : in std_logic;                                            -- '0' = fixed, '1' = random length
    cfg_max_len    : in std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);  -- random length upper bound (beats-1)
    cfg_pace       : in std_logic_vector(31 downto 0);                        -- idle cycles between reqs
    cfg_pace_init  : in std_logic_vector(31 downto 0);                        -- delay before first burst
    cfg_base_addr  : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    cfg_addr_range : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    cfg_addr_mode  : in std_logic;                                            -- '0' = linear sweep, '1' = pseudo-random

    -- Client request channel (master -> consumer)
    req_valid : out std_logic;
    req_ready : in  std_logic;
    req_addr  : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    req_len   : out std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);  -- beats-1

    -- Statistics (plain register reads, no pipeline latency)
    stat_req_stall  : out std_logic_vector(31 downto 0);
    stat_req_issued : out std_logic_vector(31 downto 0);
    stat_cfg_errors : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of axi_req_gen_top is
begin

  u_axi_req_gen : entity work.axi_req_gen
    generic map (
      GC_DATA_BYTES => GC_DATA_BYTES,
      GC_ADDR_WIDTH => GC_ADDR_WIDTH,
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
      cfg_req_len    => cfg_req_len,
      cfg_len_mode   => cfg_len_mode,
      cfg_max_len    => cfg_max_len,
      cfg_pace       => cfg_pace,
      cfg_pace_init  => cfg_pace_init,
      cfg_base_addr  => cfg_base_addr,
      cfg_addr_range => cfg_addr_range,
      cfg_addr_mode  => cfg_addr_mode,

      -- Client request channel
      req_valid => req_valid,
      req_ready => req_ready,
      req_addr  => req_addr,
      req_len   => req_len,

      -- Statistics
      stat_req_stall  => stat_req_stall,
      stat_req_issued => stat_req_issued,
      stat_cfg_errors => stat_cfg_errors
    );

end architecture;
