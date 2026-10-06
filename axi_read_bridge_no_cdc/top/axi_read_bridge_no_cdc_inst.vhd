-----------------------------------------------------------------------
--Filename         : axi_read_bridge_no_cdc_inst.vhd
--Description      : VHDL instantiation template for axi_read_bridge_no_cdc_top.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use work.util_pkg.all;

entity axi_read_bridge_no_cdc_inst is
end entity;

architecture example of axi_read_bridge_no_cdc_inst is
  constant C_NUM_CLIENTS : positive := 4;
  constant C_ADDR_WIDTH  : positive := 32;
  constant C_ID_WIDTH    : positive := 4;

  signal aclk      : std_logic;
  signal aresetn   : std_logic;
  signal req_addr  : slv_array_t(0 to C_NUM_CLIENTS-1)(C_ADDR_WIDTH-1 downto 0);
  signal req_len   : slv8_array_t(0 to C_NUM_CLIENTS-1);
  signal req_valid : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal req_ready : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal rsp_data  : slv_array_t(0 to C_NUM_CLIENTS-1)(511 downto 0);
  signal rsp_resp  : slv2_array_t(0 to C_NUM_CLIENTS-1);
  signal rsp_last  : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal rsp_valid : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal rsp_ready : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal ar_id     : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr   : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len    : std_logic_vector(7 downto 0);
  signal ar_size   : std_logic_vector(2 downto 0);
  signal ar_valid  : std_logic;
  signal ar_ready  : std_logic;
  signal r_id      : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data    : std_logic_vector(511 downto 0);
  signal r_resp    : std_logic_vector(1 downto 0);
  signal r_last    : std_logic;
  signal r_valid   : std_logic;
  signal r_ready   : std_logic;
begin
  u_dut : entity work.axi_read_bridge_no_cdc_top
    port map (
      aclk      => aclk,
      aresetn   => aresetn,
      req_addr  => req_addr,
      req_len   => req_len,
      req_valid => req_valid,
      req_ready => req_ready,
      rsp_data  => rsp_data,
      rsp_resp  => rsp_resp,
      rsp_last  => rsp_last,
      rsp_valid => rsp_valid,
      rsp_ready => rsp_ready,
      ar_id     => ar_id,
      ar_addr   => ar_addr,
      ar_len    => ar_len,
      ar_size   => ar_size,
      ar_valid  => ar_valid,
      ar_ready  => ar_ready,
      r_id      => r_id,
      r_data    => r_data,
      r_resp    => r_resp,
      r_last    => r_last,
      r_valid   => r_valid,
      r_ready   => r_ready
    );
end architecture example;