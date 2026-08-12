-----------------------------------------------------------------------
--Filename         : axi_read_bridge.vhd
--Description      : Client/native AXI read bridge:
--                 :  - Merges client read requests with axi_ar_mux.
--                 :  - Crosses AR from the client clock to the native clock.
--                 :  - Expands client-domain burst length to native beats.
--                 :  - Upsizes native R data before crossing back.
--                 :  - Demultiplexes 512-bit client responses with axi_r_demux.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_bridge is
  generic (
    GC_NUM_CLIENTS       : positive := 4;
    GC_ADDR_WIDTH        : positive := 32;
    GC_ID_WIDTH          : positive := 4;
    GC_CLIENT_DATA_BYTES : positive := 64;
    GC_NATIVE_DATA_BYTES : positive := 16;
    GC_NATIVE_ARLEN_WIDTH : positive range 2 to 8 := 8;
    GC_CLIENT_FIFO_DEPTH : positive range 2 to positive'high := 32;
    GC_CDC_DEPTH         : positive range 2 to 1024 := 8;
    GC_SYNC_STAGES       : positive range 2 to 4 := 2
  );
  port (
    client_aclk : in std_logic;
    mem_aclk    : in std_logic;
    aresetn     : in std_logic;

    -- Client request interface. req_len is client beats minus 1.
    req_addr  : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);
    req_len   : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(
      GC_NATIVE_ARLEN_WIDTH - log2ceil(GC_CLIENT_DATA_BYTES / GC_NATIVE_DATA_BYTES) - 1 downto 0);
    req_valid : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);
    req_ready : out std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- Client response interface. One beat is GC_CLIENT_DATA_BYTES wide.
    rsp_data  : out slv_array_t(0 to GC_NUM_CLIENTS-1)(8*GC_CLIENT_DATA_BYTES-1 downto 0);
    rsp_resp  : out slv2_array_t(0 to GC_NUM_CLIENTS-1);
    rsp_last  : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    rsp_valid : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    rsp_ready : in std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- Native AXI read-address channel. ar_size is exposed because it is
    -- derived from GC_NATIVE_DATA_BYTES (config-dependent). ar_burst and the
    -- AXI sidebands (lock/cache/prot/qos/region/user) are constants tied by
    -- the consumer (always INCR), matching a real AXI_HP port.
    ar_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : out std_logic_vector(GC_NATIVE_ARLEN_WIDTH-1 downto 0);
    ar_size  : out std_logic_vector(2 downto 0);
    ar_valid : out std_logic;
    ar_ready : in std_logic;

    -- Native AXI read-data channel.
    r_id    : in std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : in std_logic_vector(8*GC_NATIVE_DATA_BYTES-1 downto 0);
    r_resp  : in std_logic_vector(1 downto 0);
    r_last  : in std_logic;
    r_valid : in std_logic;
    r_ready : out std_logic
  );
end entity axi_read_bridge;

architecture rtl of axi_read_bridge is
  constant C_CLIENT_DATA_WIDTH : positive := 8 * GC_CLIENT_DATA_BYTES;
  constant C_NATIVE_DATA_WIDTH : positive := 8 * GC_NATIVE_DATA_BYTES;
  constant C_RATIO             : positive := GC_CLIENT_DATA_BYTES / GC_NATIVE_DATA_BYTES;
  constant C_RATIO_LOG2        : natural := log2ceil(C_RATIO);
  constant C_CLIENT_ARLEN_WIDTH : positive := GC_NATIVE_ARLEN_WIDTH - C_RATIO_LOG2;
  constant C_CLIENT_SIZE       : natural := log2ceil(GC_CLIENT_DATA_BYTES);
  constant C_NATIVE_SIZE       : natural := log2ceil(GC_NATIVE_DATA_BYTES);
  constant C_AR_PAYLOAD_WIDTH  : positive := GC_ID_WIDTH + GC_ADDR_WIDTH + 8;
  constant C_R_PAYLOAD_WIDTH   : positive := GC_ID_WIDTH + C_CLIENT_DATA_WIDTH + 3;

  signal core_req_len   : slv8_array_t(0 to GC_NUM_CLIENTS-1);
  signal core_req_size  : slv_array_t(0 to GC_NUM_CLIENTS-1)(2 downto 0);
  signal core_req_burst : slv_array_t(0 to GC_NUM_CLIENTS-1)(1 downto 0);
  signal core_r_pop     : std_logic_vector(0 to GC_NUM_CLIENTS-1);

  signal mux_ar_id    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal mux_ar_addr  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal mux_ar_len   : std_logic_vector(7 downto 0);
  signal mux_ar_valid : std_logic;
  signal mux_ar_ready : std_logic;

  signal ar_cdc_s_data  : std_logic_vector(C_AR_PAYLOAD_WIDTH-1 downto 0);
  signal ar_cdc_s_valid : std_logic;
  signal ar_cdc_s_ready : std_logic;
  signal ar_cdc_m_data  : std_logic_vector(C_AR_PAYLOAD_WIDTH-1 downto 0);
  signal ar_cdc_m_valid : std_logic;
  signal ar_cdc_m_ready : std_logic;
  signal native_ar_len  : std_logic_vector(GC_NATIVE_ARLEN_WIDTH-1 downto 0);

  signal up_m_data  : std_logic_vector(C_CLIENT_DATA_WIDTH-1 downto 0);
  signal up_m_last  : std_logic;
  signal up_m_resp  : std_logic_vector(1 downto 0);
  signal up_m_id    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal up_m_valid : std_logic;
  signal up_m_ready : std_logic;

  signal r_cdc_s_data  : std_logic_vector(C_R_PAYLOAD_WIDTH-1 downto 0);
  signal r_cdc_s_valid : std_logic;
  signal r_cdc_s_ready : std_logic;
  signal r_cdc_m_data  : std_logic_vector(C_R_PAYLOAD_WIDTH-1 downto 0);
  signal r_cdc_m_valid : std_logic;
  signal r_cdc_m_ready : std_logic;
  signal demux_r_id    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal demux_r_data  : std_logic_vector(C_CLIENT_DATA_WIDTH-1 downto 0);
  signal demux_r_resp  : std_logic_vector(1 downto 0);
  signal demux_r_last  : std_logic;

  function f_native_arlen(client_arlen : std_logic_vector(7 downto 0))
    return std_logic_vector is
    variable native_beats : natural;
  begin
    native_beats := (to_integer(unsigned(client_arlen)) + 1) * C_RATIO;
    return std_logic_vector(to_unsigned(native_beats - 1, GC_NATIVE_ARLEN_WIDTH));
  end function;
begin
  assert GC_CLIENT_DATA_BYTES >= GC_NATIVE_DATA_BYTES
    report "axi_read_bridge: client data width must be >= native data width"
    severity failure;
  assert (GC_CLIENT_DATA_BYTES mod GC_NATIVE_DATA_BYTES) = 0
    report "axi_read_bridge: data-byte ratio must be integral"
    severity failure;
  assert is_power_of_two(C_RATIO)
    report "axi_read_bridge: data-byte ratio must be a power of two"
    severity failure;
  assert is_power_of_two(GC_CLIENT_DATA_BYTES) and
         is_power_of_two(GC_NATIVE_DATA_BYTES)
    report "axi_read_bridge: data bytes must be powers of two"
    severity failure;
  assert C_CLIENT_SIZE <= 7 and C_NATIVE_SIZE <= 7
    report "axi_read_bridge: AXI ARSIZE cannot encode the data width"
    severity failure;
  assert C_CLIENT_ARLEN_WIDTH >= 1
    report "axi_read_bridge: native ARLEN width is too small for the ratio"
    severity failure;

  p_req_convert : process(all)
    variable v_len : std_logic_vector(7 downto 0);
  begin
    for i in 0 to GC_NUM_CLIENTS-1 loop
      v_len := (others => '0');
      v_len(C_CLIENT_ARLEN_WIDTH-1 downto 0) := req_len(i);
      core_req_len(i) <= v_len;
      core_req_size(i) <= std_logic_vector(to_unsigned(C_CLIENT_SIZE, 3));
      core_req_burst(i) <= "01";
    end loop;
  end process;

  u_ar_mux : entity work.axi_ar_mux
    generic map (
      GC_NUM_CLIENTS     => GC_NUM_CLIENTS,
      GC_ADDR_WIDTH      => GC_ADDR_WIDTH,
      GC_ID_WIDTH        => GC_ID_WIDTH,
      GC_FIFO_DEPTH      => GC_CLIENT_FIFO_DEPTH,
      GC_R_BEATS_PER_POP => 1
    )
    port map (
      aclk      => client_aclk,
      aresetn   => aresetn,
      req_addr  => req_addr,
      req_len   => core_req_len,
      req_size  => core_req_size,
      req_burst => core_req_burst,
      req_valid => req_valid,
      req_ready => req_ready,
      r_pop     => core_r_pop,
      ar_id     => mux_ar_id,
      ar_addr   => mux_ar_addr,
      ar_len    => mux_ar_len,
      ar_size   => open,
      ar_burst  => open,
      ar_valid  => mux_ar_valid,
      ar_ready  => mux_ar_ready
    );

  ar_cdc_s_data <= mux_ar_id & mux_ar_addr & mux_ar_len;
  ar_cdc_s_valid <= mux_ar_valid;
  mux_ar_ready <= ar_cdc_s_ready;

  u_ar_cdc : entity work.axis_cdc
    generic map (
      GC_TDATA_WIDTH => C_AR_PAYLOAD_WIDTH,
      GC_CDC_DEPTH   => GC_CDC_DEPTH,
      GC_SYNC_STAGES => GC_SYNC_STAGES
    )
    port map (
      s_axis_aclk   => client_aclk,
      aresetn       => aresetn,
      s_axis_tdata  => ar_cdc_s_data,
      s_axis_tvalid => ar_cdc_s_valid,
      s_axis_tready => ar_cdc_s_ready,
      m_axis_aclk   => mem_aclk,
      m_axis_tdata  => ar_cdc_m_data,
      m_axis_tvalid => ar_cdc_m_valid,
      m_axis_tready => ar_cdc_m_ready
    );

  ar_id <= ar_cdc_m_data(C_AR_PAYLOAD_WIDTH-1 downto C_AR_PAYLOAD_WIDTH-GC_ID_WIDTH);
  ar_addr <= ar_cdc_m_data(C_AR_PAYLOAD_WIDTH-GC_ID_WIDTH-1 downto 8);
  native_ar_len <= f_native_arlen(ar_cdc_m_data(7 downto 0));
  ar_len <= native_ar_len;
  ar_size <= std_logic_vector(to_unsigned(C_NATIVE_SIZE, 3));
  ar_valid <= ar_cdc_m_valid;
  ar_cdc_m_ready <= ar_ready;

  r_ready <= up_m_ready;
  u_r_upsizer : entity work.axis_upsizer
    generic map (
      GC_S_TDATA_WIDTH => C_NATIVE_DATA_WIDTH,
      GC_RATIO         => C_RATIO,
      GC_ID_WIDTH      => GC_ID_WIDTH
    )
    port map (
      aclk          => mem_aclk,
      aresetn       => aresetn,
      s_axis_tdata  => r_data,
      s_axis_tlast  => r_last,
      s_axis_rresp  => r_resp,
      s_axis_rid    => r_id,
      s_axis_tvalid => r_valid,
      s_axis_tready => up_m_ready,
      m_axis_tdata  => up_m_data,
      m_axis_tlast  => up_m_last,
      m_axis_rresp  => up_m_resp,
      m_axis_rid    => up_m_id,
      m_axis_tvalid => up_m_valid,
      m_axis_tready => r_cdc_s_ready
    );

  r_cdc_s_data <= up_m_id & up_m_data & up_m_resp & up_m_last;
  r_cdc_s_valid <= up_m_valid;

  u_r_cdc : entity work.axis_cdc
    generic map (
      GC_TDATA_WIDTH => C_R_PAYLOAD_WIDTH,
      GC_CDC_DEPTH   => GC_CDC_DEPTH,
      GC_SYNC_STAGES => GC_SYNC_STAGES
    )
    port map (
      s_axis_aclk   => mem_aclk,
      aresetn       => aresetn,
      s_axis_tdata  => r_cdc_s_data,
      s_axis_tvalid => r_cdc_s_valid,
      s_axis_tready => r_cdc_s_ready,
      m_axis_aclk   => client_aclk,
      m_axis_tdata  => r_cdc_m_data,
      m_axis_tvalid => r_cdc_m_valid,
      m_axis_tready => r_cdc_m_ready
    );

  demux_r_id <= r_cdc_m_data(C_R_PAYLOAD_WIDTH-1 downto C_R_PAYLOAD_WIDTH-GC_ID_WIDTH);
  demux_r_data <= r_cdc_m_data(C_CLIENT_DATA_WIDTH+2 downto 3);
  demux_r_resp <= r_cdc_m_data(2 downto 1);
  demux_r_last <= r_cdc_m_data(0);

  u_r_demux : entity work.axi_r_demux
    generic map (
      GC_NUM_CLIENTS => GC_NUM_CLIENTS,
      GC_DATA_BYTES  => GC_CLIENT_DATA_BYTES,
      GC_ID_WIDTH    => GC_ID_WIDTH,
      GC_FIFO_DEPTH  => GC_CLIENT_FIFO_DEPTH
    )
    port map (
      aclk      => client_aclk,
      aresetn   => aresetn,
      r_id      => demux_r_id,
      r_data    => demux_r_data,
      r_resp    => demux_r_resp,
      r_last    => demux_r_last,
      r_valid   => r_cdc_m_valid,
      r_ready   => r_cdc_m_ready,
      rsp_data  => rsp_data,
      rsp_resp  => rsp_resp,
      rsp_last  => rsp_last,
      rsp_valid => rsp_valid,
      rsp_ready => rsp_ready,
      r_pop     => core_r_pop
    );
end architecture rtl;
