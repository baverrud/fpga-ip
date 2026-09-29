-----------------------------------------------------------------------
--Filename         : axi_mem_store_top.vhd
--Description      : VHDL synthesis wrapper for axi_mem_store.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity axi_mem_store_top is
  generic (
    GC_DATA_BYTES     : positive := 64;
    GC_ADDR_WIDTH     : positive := 32;
    GC_ID_WIDTH       : positive := 6;
    GC_TIMER_WIDTH    : positive := 16;
    GC_AR_FIFO_DEPTH  : positive range 2 to positive'high := 8;
    GC_R_FIFO_DEPTH   : positive range 2 to positive'high := 8;
    GC_MEM_SIZE_BYTES : positive := 16384
  );
  port (
    -- Clock and synchronous active-low reset.
    aclk    : in  std_logic;
    aresetn : in  std_logic;
    -- Runtime request and response timing controls.
    ar_base_enable   : in  std_logic;
    ar_jitter_enable : in  std_logic;
    r_base_enable    : in  std_logic;
    r_jitter_enable  : in  std_logic;
    base_latency     : in  std_logic_vector(GC_TIMER_WIDTH-1 downto 0);
    base_beat_gap    : in  std_logic_vector(GC_TIMER_WIDTH-1 downto 0);
    -- One-byte memory population interface.
    mem_wr_addr      : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    mem_wr_data      : in  std_logic_vector(7 downto 0);
    mem_wr_valid     : in  std_logic;
    mem_wr_ready     : out std_logic;
    mem_wr_error     : out std_logic; -- One-clock pulse on an invalid write.
    -- AXI4 read-address channel.
    ar_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : in  std_logic_vector(7 downto 0);
    ar_valid : in  std_logic;
    ar_ready : out std_logic;
    -- AXI4 read-data channel.
    r_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : out std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : out std_logic_vector(1 downto 0);
    r_last  : out std_logic;
    r_valid : out std_logic;
    r_ready : in  std_logic
  );
end entity;

architecture rtl of axi_mem_store_top is
begin

  -- Thin pass-through wrapper. The memory array, AXI sequencer and latency
  -- stages are implemented by axi_mem_store.
  u_axi_mem_store : entity work.axi_mem_store
    generic map (
      GC_DATA_BYTES     => GC_DATA_BYTES,
      GC_ADDR_WIDTH     => GC_ADDR_WIDTH,
      GC_ID_WIDTH       => GC_ID_WIDTH,
      GC_TIMER_WIDTH    => GC_TIMER_WIDTH,
      GC_AR_FIFO_DEPTH  => GC_AR_FIFO_DEPTH,
      GC_R_FIFO_DEPTH   => GC_R_FIFO_DEPTH,
      GC_MEM_SIZE_BYTES => GC_MEM_SIZE_BYTES
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      ar_base_enable    => ar_base_enable,
      ar_jitter_enable  => ar_jitter_enable,
      r_base_enable     => r_base_enable,
      r_jitter_enable   => r_jitter_enable,
      base_latency      => base_latency,
      base_beat_gap     => base_beat_gap,
      mem_wr_addr       => mem_wr_addr,
      mem_wr_data       => mem_wr_data,
      mem_wr_valid      => mem_wr_valid,
      mem_wr_ready      => mem_wr_ready,
      mem_wr_error      => mem_wr_error,
      ar_id             => ar_id,
      ar_addr           => ar_addr,
      ar_len            => ar_len,
      ar_valid          => ar_valid,
      ar_ready          => ar_ready,
      r_id              => r_id,
      r_data            => r_data,
      r_resp            => r_resp,
      r_last            => r_last,
      r_valid           => r_valid,
      r_ready           => r_ready
    );

end architecture;
