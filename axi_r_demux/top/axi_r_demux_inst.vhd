-----------------------------------------------------------------------
--Filename         : axi_r_demux_inst.vhd
--Description      : Instantiation template for axi_r_demux_top.
--                 : 4-client, 32-bit, 4-bit-ID, depth-32 configuration.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.util_pkg.all;  -- slv_array_t, slv2_array_t

entity axi_r_demux_inst is
  generic (
    GC_NUM_CLIENTS : positive := 4;                           -- number of clients
    GC_DATA_BYTES  : positive := 4;                           -- data width in bytes
    GC_ID_WIDTH    : positive := 4;                           -- R ID width
    GC_FIFO_DEPTH  : positive range 2 to positive'high := 32  -- per-client FIFO depth
  );
end entity axi_r_demux_inst;

architecture rtl of axi_r_demux_inst is
  signal aclk : std_logic;
  signal aresetn : std_logic;
  signal r_id : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal r_data : std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
  signal r_resp : std_logic_vector(1 downto 0);
  signal r_last : std_logic;
  signal r_valid : std_logic;
  signal r_ready : std_logic;
  signal rsp_data : slv_array_t(0 to GC_NUM_CLIENTS-1)(8*GC_DATA_BYTES-1 downto 0);
  signal rsp_resp : slv2_array_t(0 to GC_NUM_CLIENTS-1);
  signal rsp_last : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal rsp_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal rsp_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal r_pop : std_logic_vector(0 to GC_NUM_CLIENTS-1);

begin

  u_core : entity work.axi_r_demux
    generic map (
      GC_NUM_CLIENTS => GC_NUM_CLIENTS,
      GC_DATA_BYTES  => GC_DATA_BYTES,
      GC_ID_WIDTH    => GC_ID_WIDTH,
      GC_FIFO_DEPTH  => GC_FIFO_DEPTH
    )
    port map (
      aclk      => aclk,
      aresetn   => aresetn,
      r_id      => r_id,
      r_data    => r_data,
      r_resp    => r_resp,
      r_last    => r_last,
      r_valid   => r_valid,
      r_ready   => r_ready,
      rsp_data  => rsp_data,
      rsp_resp  => rsp_resp,
      rsp_last  => rsp_last,
      rsp_valid => rsp_valid,
      rsp_ready => rsp_ready,
      r_pop     => r_pop
    );

end architecture;
