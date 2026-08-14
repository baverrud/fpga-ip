-----------------------------------------------------------------------
--Filename         : axi_read_bridge_top.vhd
--Description      : Synthesis wrapper for axi_read_bridge.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use work.util_pkg.all;

entity axi_read_bridge_top is
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
  port (
    aclk : in std_logic;
    mem_aclk    : in std_logic;
    aresetn     : in std_logic;

    req_addr  : in slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);
    req_len   : in slv_array_t(0 to GC_NUM_CLIENTS-1)(
      GC_NATIVE_ARLEN_WIDTH - log2ceil(GC_CLIENT_DATA_BYTES / GC_NATIVE_DATA_BYTES) - 1 downto 0);
    req_valid : in std_logic_vector(0 to GC_NUM_CLIENTS-1);
    req_ready : out std_logic_vector(0 to GC_NUM_CLIENTS-1);

    rsp_data  : out slv_array_t(0 to GC_NUM_CLIENTS-1)(8*GC_CLIENT_DATA_BYTES-1 downto 0);
    rsp_resp  : out slv2_array_t(0 to GC_NUM_CLIENTS-1);
    rsp_last  : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    rsp_valid : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    rsp_ready : in std_logic_vector(0 to GC_NUM_CLIENTS-1);

    ar_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : out std_logic_vector(GC_NATIVE_ARLEN_WIDTH-1 downto 0);
    ar_size  : out std_logic_vector(2 downto 0);
    ar_valid : out std_logic;
    ar_ready : in std_logic;

    r_id    : in std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : in std_logic_vector(8*GC_NATIVE_DATA_BYTES-1 downto 0);
    r_resp  : in std_logic_vector(1 downto 0);
    r_last  : in std_logic;
    r_valid : in std_logic;
    r_ready : out std_logic
  );
end entity axi_read_bridge_top;

architecture rtl of axi_read_bridge_top is
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
      ar_size     => ar_size,
      ar_valid    => ar_valid,
      ar_ready    => ar_ready,
      r_id        => r_id,
      r_data      => r_data,
      r_resp      => r_resp,
      r_last      => r_last,
      r_valid     => r_valid,
      r_ready     => r_ready
    );
end architecture rtl;
