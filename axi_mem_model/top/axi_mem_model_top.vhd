-----------------------------------------------------------------------
--Filename         : axi_mem_model_top.vhd
--Description      : Synthesis Wrapper and Instantiation Top-Level for
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

entity axi_mem_model_top is
  generic (
    GC_DATA_BYTES    : positive := 64;  -- Bus width in bytes
    GC_ADDR_WIDTH    : positive := 49;  -- Address width
    GC_ID_WIDTH      : positive := 6;   -- ID width
    GC_TIMER_WIDTH   : positive := 16;  -- Latency / gap timer width
    GC_AR_FIFO_DEPTH : positive := 8;   -- AR-side latency FIFO depth
    GC_R_FIFO_DEPTH  : positive := 8    -- R-side beat-gap FIFO depth
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Control
    ar_base_enable   : in std_logic;
    ar_jitter_enable : in std_logic;
    r_base_enable    : in std_logic;
    r_jitter_enable  : in std_logic;
    base_latency     : in std_logic_vector(GC_TIMER_WIDTH-1 downto 0);
    base_beat_gap    : in std_logic_vector(GC_TIMER_WIDTH-1 downto 0);

    -- AXI4 AR channel
    ar_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : in  std_logic_vector(7 downto 0);
    ar_valid : in  std_logic;
    ar_ready : out std_logic;

    -- AXI4 R channel
    r_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : out std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : out std_logic_vector(1 downto 0);
    r_last  : out std_logic;
    r_valid : out std_logic;
    r_ready : in  std_logic
  );
end entity;

architecture rtl of axi_mem_model_top is
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
