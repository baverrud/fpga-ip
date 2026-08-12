-----------------------------------------------------------------------
--Filename         : axi_r_demux_top.vhd
--Description      : Synthesis wrapper for axi_r_demux, defaulted to the
--                 : 4-client, 32-bit, 4-bit-ID, depth-32 configuration.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.util_pkg.all;  -- slv_array_t, slv2_array_t

entity axi_r_demux_top is
  generic (
    GC_NUM_CLIENTS : positive := 4;                           -- number of clients
    GC_DATA_BYTES  : positive := 4;                           -- data width in bytes
    GC_ID_WIDTH    : positive := 4;                           -- R ID width
    GC_FIFO_DEPTH  : positive range 2 to positive'high := 32  -- per-client FIFO depth
  );
  port (
    -- Clock / reset
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- AXI Read Data Channel
    r_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : in  std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : in  std_logic_vector(1 downto 0);
    r_last  : in  std_logic;
    r_valid : in  std_logic;
    r_ready : out std_logic;

    -- Demuxed client response interfaces
    rsp_data  : out slv_array_t(0 to GC_NUM_CLIENTS-1)(8*GC_DATA_BYTES-1 downto 0);
    rsp_resp  : out slv2_array_t(0 to GC_NUM_CLIENTS-1);
    rsp_last  : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    rsp_valid : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    rsp_ready : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- Credit return pulses
    r_pop : out std_logic_vector(0 to GC_NUM_CLIENTS-1)
  );
end entity axi_r_demux_top;

architecture rtl of axi_r_demux_top is
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
