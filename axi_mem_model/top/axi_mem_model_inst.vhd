-----------------------------------------------------------------------
--Filename         : axi_mem_model_inst.vhd
--Description      : Instantiation template for axi_mem_model_top.
--                 : axi_mem_model.  Passes the AXI configuration and
--                 : latency-timer widths through as generics and
--                 : exposes the AR/R channels plus runtime controls.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_mem_model_inst is
  generic (
    GC_DATA_BYTES    : positive := 64;  -- Bus width in bytes
    GC_ADDR_WIDTH    : positive := 49;  -- Address width
    GC_ID_WIDTH      : positive := 6;   -- ID width
    GC_TIMER_WIDTH   : positive := 16;  -- Latency / gap timer width
    GC_AR_FIFO_DEPTH : positive := 8;   -- AR-side latency FIFO depth
    GC_R_FIFO_DEPTH  : positive := 8    -- R-side beat-gap FIFO depth
  );
end entity;

architecture rtl of axi_mem_model_inst is
  signal aclk : std_logic;
  signal aresetn : std_logic;
  signal ar_base_enable : std_logic;
  signal ar_jitter_enable : std_logic;
  signal r_base_enable : std_logic;
  signal r_jitter_enable : std_logic;
  signal base_latency : std_logic_vector(GC_TIMER_WIDTH-1 downto 0);
  signal base_beat_gap : std_logic_vector(GC_TIMER_WIDTH-1 downto 0);
  signal ar_id : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal ar_addr : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal ar_len : std_logic_vector(7 downto 0);
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;
  signal r_id : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal r_data : std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
  signal r_resp : std_logic_vector(1 downto 0);
  signal r_last : std_logic;
  signal r_valid : std_logic;
  signal r_ready : std_logic;

begin

  u_axi_mem_model : entity work.axi_mem_model
    generic map (
      GC_DATA_BYTES    => GC_DATA_BYTES,
      GC_ADDR_WIDTH    => GC_ADDR_WIDTH,
      GC_ID_WIDTH      => GC_ID_WIDTH,
      GC_TIMER_WIDTH   => GC_TIMER_WIDTH,
      GC_AR_FIFO_DEPTH => GC_AR_FIFO_DEPTH,
      GC_R_FIFO_DEPTH  => GC_R_FIFO_DEPTH
    )
    port map (
      -- Clock and reset
      aclk    => aclk,
      aresetn => aresetn,

      -- Control
      ar_base_enable   => ar_base_enable,
      ar_jitter_enable => ar_jitter_enable,
      r_base_enable    => r_base_enable,
      r_jitter_enable  => r_jitter_enable,
      base_latency     => base_latency,
      base_beat_gap    => base_beat_gap,

      -- AXI4 AR channel
      ar_id    => ar_id,
      ar_addr  => ar_addr,
      ar_len   => ar_len,
      ar_valid => ar_valid,
      ar_ready => ar_ready,

      -- AXI4 R channel
      r_id    => r_id,
      r_data  => r_data,
      r_resp  => r_resp,
      r_last  => r_last,
      r_valid => r_valid,
      r_ready => r_ready
    );

end architecture;
