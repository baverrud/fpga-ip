-----------------------------------------------------------------------
--Filename         : axi_read_bridge_inst.vhd
--Description      : Instantiation template for axi_read_bridge_top.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_bridge_inst is
  generic (
    GC_NUM_CLIENTS        : positive := 4;
    GC_ADDR_WIDTH         : positive := 32;
    GC_ID_WIDTH           : positive := 4;
    GC_CLIENT_DATA_BYTES  : positive := 64;
    GC_NATIVE_DATA_BYTES  : positive := 16;
    GC_NATIVE_ARLEN_WIDTH : positive range 2 to 8 := 8;
    GC_CLIENT_FIFO_DEPTH  : positive range 2 to positive'high := 32;
    GC_CDC_DEPTH          : positive range 2 to 1024 := 8;
    GC_SYNC_STAGES        : positive range 2 to 4 := 2
  );
end entity axi_read_bridge_inst;

architecture rtl of axi_read_bridge_inst is
  signal aclk : std_logic;
  signal mem_aclk : std_logic;
  signal aresetn : std_logic;
  signal req_addr : slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);
  signal req_len : slv_array_t(0 to GC_NUM_CLIENTS-1)( GC_NATIVE_ARLEN_WIDTH - log2ceil(GC_CLIENT_DATA_BYTES / GC_NATIVE_DATA_BYTES) - 1 downto 0);
  signal req_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal req_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal rsp_data : slv_array_t(0 to GC_NUM_CLIENTS-1)(8*GC_CLIENT_DATA_BYTES-1 downto 0);
  signal rsp_resp : slv2_array_t(0 to GC_NUM_CLIENTS-1);
  signal rsp_last : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal rsp_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal rsp_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal ar_id : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal ar_addr : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal ar_len : std_logic_vector(GC_NATIVE_ARLEN_WIDTH-1 downto 0);
  signal ar_size : std_logic_vector(2 downto 0);
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;
  signal r_id : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal r_data : std_logic_vector(8*GC_NATIVE_DATA_BYTES-1 downto 0);
  signal r_resp : std_logic_vector(1 downto 0);
  signal r_last : std_logic;
  signal r_valid : std_logic;
  signal r_ready : std_logic;

begin
  u_core : entity work.axi_read_bridge
    generic map (
      GC_NUM_CLIENTS        => GC_NUM_CLIENTS,
      GC_ADDR_WIDTH         => GC_ADDR_WIDTH,
      GC_ID_WIDTH           => GC_ID_WIDTH,
      GC_CLIENT_DATA_BYTES  => GC_CLIENT_DATA_BYTES,
      GC_NATIVE_DATA_BYTES  => GC_NATIVE_DATA_BYTES,
      GC_NATIVE_ARLEN_WIDTH => GC_NATIVE_ARLEN_WIDTH,
      GC_CLIENT_FIFO_DEPTH  => GC_CLIENT_FIFO_DEPTH,
      GC_CDC_DEPTH          => GC_CDC_DEPTH,
      GC_SYNC_STAGES        => GC_SYNC_STAGES
    )
    port map (
      aclk => aclk,
      mem_aclk    => mem_aclk,
      aresetn     => aresetn,
      req_addr    => req_addr,
      req_len     => req_len,
      req_valid   => req_valid,
      req_ready   => req_ready,
      rsp_data    => rsp_data,
      rsp_resp    => rsp_resp,
      rsp_last    => rsp_last,
      rsp_valid   => rsp_valid,
      rsp_ready   => rsp_ready,
      ar_id       => ar_id,
      ar_addr     => ar_addr,
      ar_len      => ar_len,
      ar_valid    => ar_valid,
      ar_ready    => ar_ready,
      r_id        => r_id,
      r_data      => r_data,
      r_resp      => r_resp,
      r_last      => r_last,
      r_valid     => r_valid,
      r_ready     => r_ready
    );

  ar_size <= std_logic_vector(to_unsigned(log2ceil(GC_NATIVE_DATA_BYTES), 3));
end architecture rtl;
