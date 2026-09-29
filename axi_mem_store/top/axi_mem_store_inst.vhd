-----------------------------------------------------------------------
--Filename         : axi_mem_store_inst.vhd
--Description      : VHDL instantiation template for axi_mem_store_top.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity axi_mem_store_inst is
  generic (
    GC_DATA_BYTES     : positive := 64;
    GC_ADDR_WIDTH     : positive := 32;
    GC_ID_WIDTH       : positive := 6;
    GC_TIMER_WIDTH    : positive := 16;
    GC_AR_FIFO_DEPTH  : positive range 2 to positive'high := 8;
    GC_R_FIFO_DEPTH   : positive range 2 to positive'high := 8;
    GC_MEM_SIZE_BYTES : positive := 16384
  );
end entity;

architecture rtl of axi_mem_store_inst is
  -- Replace these internal signals with the real signals in the design that
  -- instantiates this template.  The template is intentionally self-contained
  -- so it can be copied without reconstructing the port list.
  signal aclk, aresetn : std_logic;
  -- Runtime timing controls.
  signal ar_base_enable, ar_jitter_enable : std_logic;
  signal r_base_enable, r_jitter_enable : std_logic;
  -- Byte population write interface.
  signal mem_wr_valid, mem_wr_ready, mem_wr_error : std_logic;
  -- AXI read channels.
  signal ar_valid, ar_ready : std_logic;
  signal r_valid, r_ready : std_logic;
  signal base_latency, base_beat_gap : std_logic_vector(GC_TIMER_WIDTH-1 downto 0);
  signal mem_wr_addr : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal mem_wr_data : std_logic_vector(7 downto 0);
  signal ar_id : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal ar_addr : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal ar_len : std_logic_vector(7 downto 0);
  signal r_id : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal r_data : std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
  signal r_resp : std_logic_vector(1 downto 0);
  signal r_last : std_logic;
begin

  -- Connect this template to the design under test or replace it with the
  -- corresponding axi_mem_store_top instance in the surrounding hierarchy.
  u_axi_mem_store : entity work.axi_mem_store_top
    generic map (
      GC_DATA_BYTES => GC_DATA_BYTES, GC_ADDR_WIDTH => GC_ADDR_WIDTH,
      GC_ID_WIDTH => GC_ID_WIDTH, GC_TIMER_WIDTH => GC_TIMER_WIDTH,
      GC_AR_FIFO_DEPTH => GC_AR_FIFO_DEPTH, GC_R_FIFO_DEPTH => GC_R_FIFO_DEPTH,
      GC_MEM_SIZE_BYTES => GC_MEM_SIZE_BYTES
    )
    port map (
      aclk => aclk, aresetn => aresetn,
      ar_base_enable => ar_base_enable, ar_jitter_enable => ar_jitter_enable,
      r_base_enable => r_base_enable, r_jitter_enable => r_jitter_enable,
      base_latency => base_latency, base_beat_gap => base_beat_gap,
      mem_wr_addr => mem_wr_addr, mem_wr_data => mem_wr_data,
      mem_wr_valid => mem_wr_valid, mem_wr_ready => mem_wr_ready,
      mem_wr_error => mem_wr_error,
      ar_id => ar_id, ar_addr => ar_addr, ar_len => ar_len,
      ar_valid => ar_valid, ar_ready => ar_ready,
      r_id => r_id, r_data => r_data, r_resp => r_resp,
      r_last => r_last, r_valid => r_valid, r_ready => r_ready
    );

end architecture;
