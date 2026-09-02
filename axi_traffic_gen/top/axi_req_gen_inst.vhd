-----------------------------------------------------------------------
--Filename         : axi_req_gen_inst.vhd
--Description      : Instantiation template for axi_req_gen_top.
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

entity axi_req_gen_inst is
  generic (
    GC_DATA_BYTES : positive := 64;
    GC_ADDR_WIDTH : positive := 32;
    GC_MAX_BURST  : positive := 32   -- max beats per burst (credit-limited)
  );
end entity;

architecture rtl of axi_req_gen_inst is
  signal aclk : std_logic;
  signal aresetn : std_logic;
  signal enable : std_logic;
  signal aperture : std_logic;
  signal stat_rst : std_logic;
  signal cfg_req_len : std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);
  signal cfg_len_mode : std_logic;
  signal cfg_max_len : std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);
  signal cfg_pace : std_logic_vector(31 downto 0);
  signal cfg_pace_init : std_logic_vector(31 downto 0);
  signal cfg_base_addr : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal cfg_addr_range : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal cfg_addr_mode : std_logic;
  signal req_valid : std_logic;
  signal req_ready : std_logic;
  signal req_addr : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal req_len : std_logic_vector(log2ceil(GC_MAX_BURST)-1 downto 0);
  signal stat_req_stall : std_logic_vector(31 downto 0);
  signal stat_req_issued : std_logic_vector(31 downto 0);
  signal stat_cfg_errors : std_logic_vector(31 downto 0);

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
