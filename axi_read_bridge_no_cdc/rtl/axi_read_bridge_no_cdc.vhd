-----------------------------------------------------------------------
--Filename         : axi_read_bridge_no_cdc.vhd
--Description      : Single-clock, direct 512-bit multi-client AXI read bridge.
--                 : Merges requests with axi_ar_mux and routes native R
--                 : beats with axi_r_demux. No CDC or width conversion.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_bridge_no_cdc is
  generic (
    GC_NUM_CLIENTS       : positive := 4;
    GC_ADDR_WIDTH        : positive := 32;
    GC_ID_WIDTH          : positive := 4;
    GC_CLIENT_FIFO_DEPTH : positive range 2 to positive'high := 32
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;  -- Synchronous, active low

    req_addr  : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);
    req_len   : in  slv8_array_t(0 to GC_NUM_CLIENTS-1);  -- 512-bit beats minus 1
    req_valid : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);
    req_ready : out std_logic_vector(0 to GC_NUM_CLIENTS-1);

    rsp_data  : out slv_array_t(0 to GC_NUM_CLIENTS-1)(511 downto 0);
    rsp_resp  : out slv2_array_t(0 to GC_NUM_CLIENTS-1);
    rsp_last  : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    rsp_valid : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    rsp_ready : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);

    ar_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : out std_logic_vector(7 downto 0);
    ar_valid : out std_logic;
    ar_ready : in  std_logic;

    r_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : in  std_logic_vector(511 downto 0);
    r_resp  : in  std_logic_vector(1 downto 0);
    r_last  : in  std_logic;
    r_valid : in  std_logic;
    r_ready : out std_logic
  );
end entity axi_read_bridge_no_cdc;

architecture rtl of axi_read_bridge_no_cdc is
  constant C_PAGE_BITS : positive := minimum(12, GC_ADDR_WIDTH);

  signal core_r_pop : std_logic_vector(0 to GC_NUM_CLIENTS-1);
begin
  assert GC_ID_WIDTH >= log2ceil(GC_NUM_CLIENTS)
    report "axi_read_bridge_no_cdc: GC_ID_WIDTH cannot encode all clients"
    severity failure;

  -- synthesis translate_off
  p_req_check : process(aclk)
    variable v_offset : natural;
    variable v_bytes  : natural;
  begin
    if rising_edge(aclk) and aresetn = '1' then
      for i in 0 to GC_NUM_CLIENTS-1 loop
        if req_valid(i) = '1' and req_ready(i) = '1' then
          v_offset := to_integer(unsigned(req_addr(i)(C_PAGE_BITS-1 downto 0)));
          v_bytes  := (to_integer(unsigned(req_len(i))) + 1) * 64;
          assert v_offset mod 64 = 0
            report "axi_read_bridge_no_cdc: request address must be 64-byte aligned"
            severity failure;
          assert v_offset + v_bytes <= 4096
            report "axi_read_bridge_no_cdc: request crosses a 4 KiB page"
            severity failure;
        end if;
      end loop;
    end if;
  end process;
  -- synthesis translate_on

  u_ar_mux : entity work.axi_ar_mux
    generic map (
      GC_NUM_CLIENTS     => GC_NUM_CLIENTS,
      GC_ADDR_WIDTH      => GC_ADDR_WIDTH,
      GC_ID_WIDTH        => GC_ID_WIDTH,
      GC_FIFO_DEPTH      => GC_CLIENT_FIFO_DEPTH,
      GC_R_BEATS_PER_POP => 1
    )
    port map (
      aclk      => aclk,
      aresetn   => aresetn,
      req_addr  => req_addr,
      req_len   => req_len,
      req_valid => req_valid,
      req_ready => req_ready,
      r_pop     => core_r_pop,
      ar_id     => ar_id,
      ar_addr   => ar_addr,
      ar_len    => ar_len,
      ar_valid  => ar_valid,
      ar_ready  => ar_ready
    );

  u_r_demux : entity work.axi_r_demux
    generic map (
      GC_NUM_CLIENTS => GC_NUM_CLIENTS,
      GC_DATA_BYTES  => 64,
      GC_ID_WIDTH    => GC_ID_WIDTH,
      GC_FIFO_DEPTH  => GC_CLIENT_FIFO_DEPTH
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
      r_pop     => core_r_pop
    );
end architecture rtl;