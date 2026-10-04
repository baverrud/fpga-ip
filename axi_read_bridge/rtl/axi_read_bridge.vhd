-----------------------------------------------------------------------
--Filename         : axi_read_bridge.vhd
--Description      : Client/native AXI read bridge:
--                 :  - Merges client read requests with axi_ar_mux.
--                 :  - Crosses AR from the client clock to the native clock.
--                 :  - Expands client-domain burst length to native beats.
--                 :  - Upsizes native R data before crossing back.
--                 :  - Demultiplexes the wide client responses with
--                 :    axi_r_demux.
--                 : aresetn may be asynchronous to both clocks: it is
--                 : synchronized into each clock domain internally
--                 : (asynchronous assertion, synchronous release).
--                 : The native slave must not interleave R beats of
--                 : different IDs (see README).
--Author           : Rune Baeverrud
--Current Revision : 1.10
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_bridge is
  generic (
    GC_NUM_CLIENTS        : positive := 4;   -- Client request/response ports
    GC_ADDR_WIDTH         : positive := 32;  -- Byte address width
    GC_ID_WIDTH           : positive := 4;   -- Native ID width; ID = client index
    GC_CLIENT_DATA_BYTES  : positive := 64;  -- Client beat width in bytes
    GC_NATIVE_DATA_BYTES  : positive := 16;  -- Native R beat width in bytes
    GC_NATIVE_ARLEN_WIDTH : positive range 2 to 8 := 8;           -- 8 for AXI4, 4 for AXI3
    GC_CLIENT_FIFO_DEPTH  : positive range 2 to positive'high := 32; -- Per-client credits / R FIFO
    GC_CDC_DEPTH          : positive range 2 to 1024 := 8;        -- Each CDC FIFO; power of two
    GC_SYNC_STAGES        : positive range 2 to 4 := 2            -- CDC pointer synchronizer stages
  );
  port (
    aclk     : in std_logic;  -- Client clock
    mem_aclk : in std_logic;  -- Native AXI clock
    aresetn  : in std_logic;  -- Active low; may be asynchronous (synchronized inside)

    -- Client request interface. req_len is client beats minus 1.
    -- req_addr must be client-beat aligned and the burst must stay inside
    -- one 4 KiB page (checked in simulation).
    req_addr  : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);
    req_len   : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(
      GC_NATIVE_ARLEN_WIDTH - log2ceil(GC_CLIENT_DATA_BYTES / GC_NATIVE_DATA_BYTES) - 1 downto 0);
    req_valid : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);
    req_ready : out std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- Client response interface. One beat is GC_CLIENT_DATA_BYTES wide.
    rsp_data  : out slv_array_t(0 to GC_NUM_CLIENTS-1)(8*GC_CLIENT_DATA_BYTES-1 downto 0);
    rsp_resp  : out slv2_array_t(0 to GC_NUM_CLIENTS-1);   -- Worst native response of the beat
    rsp_last  : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    rsp_valid : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    rsp_ready : in std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- Native AXI read-address channel. AXI sidebands, including ARSIZE and
    -- ARBURST, are constants tied by the integration boundary.
    ar_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);            -- Client index
    ar_addr  : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : out std_logic_vector(GC_NATIVE_ARLEN_WIDTH-1 downto 0);  -- Native beats - 1
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

-- Data flow, one direction per clock domain:
--   aclk     : req_* -> axi_ar_mux -> AR axis_cdc ----------------> native AR
--   mem_aclk : native R -> axis_upsizer -> R axis_cdc -> axi_r_demux -> rsp_*
-- Credits: every client beat popped by axi_r_demux returns one credit to
-- axi_ar_mux (r_pop), so a client never has more beats in flight than its
-- response FIFO can hold.
architecture rtl of axi_read_bridge is

  -- Widths
  constant C_CLIENT_DATA_WIDTH  : positive := 8 * GC_CLIENT_DATA_BYTES;
  constant C_NATIVE_DATA_WIDTH  : positive := 8 * GC_NATIVE_DATA_BYTES;
  constant C_RATIO              : positive := GC_CLIENT_DATA_BYTES / GC_NATIVE_DATA_BYTES; -- Native beats per client beat
  constant C_RATIO_LOG2         : natural  := log2ceil(C_RATIO);
  constant C_CLIENT_ARLEN_WIDTH : positive := GC_NATIVE_ARLEN_WIDTH - C_RATIO_LOG2;
  constant C_CLIENT_SIZE        : natural  := log2ceil(GC_CLIENT_DATA_BYTES); -- Client ARSIZE
  constant C_NATIVE_SIZE        : natural  := log2ceil(GC_NATIVE_DATA_BYTES); -- Native ARSIZE
  constant C_AXI_PAGE_BYTES     : positive := 4096;                         -- No burst may cross a page
  constant C_PAGE_BITS          : positive := minimum(12, GC_ADDR_WIDTH);   -- Address bits inside a page

  -- Low bits of every native ARLEN: (len + 1) * ratio - 1 equals
  -- len * ratio + (ratio - 1), i.e. the client length shifted left with
  -- all-ones fill.  Null (zero bits) when the ratio is 1.
  constant C_LEN_FILL : std_logic_vector(C_RATIO_LOG2-1 downto 0) := (others => '1');

  -- AR CDC payload: [ id | addr | client len ].  Only the client length
  -- crosses; the native length is formed after the crossing by wiring.
  constant C_AR_LEN_LO        : natural  := 0;
  constant C_AR_LEN_HI        : natural  := C_CLIENT_ARLEN_WIDTH - 1;
  constant C_AR_ADDR_LO       : natural  := C_AR_LEN_HI + 1;
  constant C_AR_ADDR_HI       : natural  := C_AR_ADDR_LO + GC_ADDR_WIDTH - 1;
  constant C_AR_ID_LO         : natural  := C_AR_ADDR_HI + 1;
  constant C_AR_ID_HI         : natural  := C_AR_ID_LO + GC_ID_WIDTH - 1;
  constant C_AR_PAYLOAD_WIDTH : positive := C_AR_ID_HI + 1;

  -- R CDC payload: [ id | wide data | resp | last ].
  constant C_R_LAST          : natural  := 0;
  constant C_R_RESP_LO       : natural  := 1;
  constant C_R_RESP_HI       : natural  := 2;
  constant C_R_DATA_LO       : natural  := 3;
  constant C_R_DATA_HI       : natural  := C_R_DATA_LO + C_CLIENT_DATA_WIDTH - 1;
  constant C_R_ID_LO         : natural  := C_R_DATA_HI + 1;
  constant C_R_ID_HI         : natural  := C_R_ID_LO + GC_ID_WIDTH - 1;
  constant C_R_PAYLOAD_WIDTH : positive := C_R_ID_HI + 1;

  -- Reset synchronizers: asynchronous assertion, synchronous release.
  attribute ASYNC_REG : string;
  signal aclk_rst_sync : std_logic_vector(1 downto 0) := (others => '0');
  signal mem_rst_sync  : std_logic_vector(1 downto 0) := (others => '0');
  attribute ASYNC_REG of aclk_rst_sync : signal is "TRUE";
  attribute ASYNC_REG of mem_rst_sync  : signal is "TRUE";
  signal aclk_aresetn : std_logic;  -- Reset for the aclk-domain blocks
  signal mem_aresetn  : std_logic;  -- Reset for the mem_aclk-domain blocks

  -- Client side (aclk)
  signal core_req_len : slv8_array_t(0 to GC_NUM_CLIENTS-1);  -- req_len, zero-extended
  signal core_r_pop   : std_logic_vector(0 to GC_NUM_CLIENTS-1);  -- Credit return per client

  signal mux_ar_id    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal mux_ar_addr  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal mux_ar_len   : std_logic_vector(7 downto 0);   -- Client beats - 1
  signal mux_ar_valid : std_logic;
  signal mux_ar_ready : std_logic;

  -- AR clock crossing (aclk -> mem_aclk)
  signal ar_cdc_s_data  : std_logic_vector(C_AR_PAYLOAD_WIDTH-1 downto 0);
  signal ar_cdc_s_valid : std_logic;
  signal ar_cdc_s_ready : std_logic;
  signal ar_cdc_m_data  : std_logic_vector(C_AR_PAYLOAD_WIDTH-1 downto 0);
  signal ar_cdc_m_valid : std_logic;
  signal ar_cdc_m_ready : std_logic;

  -- Upsizer output (mem_aclk): one client beat per transfer
  signal up_m_data  : std_logic_vector(C_CLIENT_DATA_WIDTH-1 downto 0);
  signal up_m_last  : std_logic;
  signal up_m_resp  : std_logic_vector(1 downto 0);  -- Worst response of the packed beats
  signal up_m_id    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal up_m_valid : std_logic;
  signal up_s_ready : std_logic;                     -- Registered; drives native r_ready

  -- R clock crossing (mem_aclk -> aclk)
  signal r_cdc_s_data  : std_logic_vector(C_R_PAYLOAD_WIDTH-1 downto 0);
  signal r_cdc_s_ready : std_logic;
  signal r_cdc_m_data  : std_logic_vector(C_R_PAYLOAD_WIDTH-1 downto 0);
  signal r_cdc_m_valid : std_logic;
  signal r_cdc_m_ready : std_logic;

begin

  -- Elaboration checks

  assert GC_CLIENT_DATA_BYTES >= GC_NATIVE_DATA_BYTES
    report "axi_read_bridge: client data width must be >= native data width"
    severity failure;
  assert (GC_CLIENT_DATA_BYTES mod GC_NATIVE_DATA_BYTES) = 0
    report "axi_read_bridge: data-byte ratio must be integral"
    severity failure;
  -- A power-of-two ratio is what makes the native ARLEN pure wiring.
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

  -- Reset synchronizers
  -- aresetn may come from any domain.  Each clock domain gets its own copy
  -- that asserts at once and releases on that domain's clock, so no flop
  -- sees an asynchronous release.  The two axis_cdc instances take the raw
  -- aresetn because they contain the same synchronizers for both sides.
  p_aclk_rst_sync : process(aclk, aresetn)
  begin
    if aresetn = '0' then
      aclk_rst_sync <= (others => '0');
    elsif rising_edge(aclk) then
      aclk_rst_sync <= aclk_rst_sync(0) & '1';
    end if;
  end process;
  aclk_aresetn <= aclk_rst_sync(1);

  p_mem_rst_sync : process(mem_aclk, aresetn)
  begin
    if aresetn = '0' then
      mem_rst_sync <= (others => '0');
    elsif rising_edge(mem_aclk) then
      mem_rst_sync <= mem_rst_sync(0) & '1';
    end if;
  end process;
  mem_aresetn <= mem_rst_sync(1);

  -- Request side (aclk)

  -- axi_ar_mux takes 8-bit lengths; the client length is narrower.
  gen_req_len : for i in 0 to GC_NUM_CLIENTS-1 generate
    core_req_len(i) <= std_logic_vector(resize(unsigned(req_len(i)), 8));
  end generate;

  -- synthesis translate_off
  -- Simulation-only request rules.  A misaligned start would make the
  -- packed client beat straddle two client windows, and a burst crossing a
  -- 4 KiB page is illegal on the native AXI port.
  p_req_check : process(aclk)
    variable v_offset : natural;  -- Start offset inside the 4 KiB page
    variable v_bytes  : natural;  -- Burst size in bytes
  begin
    if rising_edge(aclk) then
      if aclk_aresetn = '1' then
        for i in 0 to GC_NUM_CLIENTS-1 loop
          if req_valid(i) = '1' and req_ready(i) = '1' then
            v_offset := to_integer(unsigned(req_addr(i)(C_PAGE_BITS-1 downto 0)));
            v_bytes  := (to_integer(unsigned(req_len(i))) + 1) * GC_CLIENT_DATA_BYTES;
            assert v_offset mod GC_CLIENT_DATA_BYTES = 0
              report "axi_read_bridge: client " & integer'image(i) &
                     " req_addr is not aligned to GC_CLIENT_DATA_BYTES"
              severity failure;
            assert v_offset + v_bytes <= C_AXI_PAGE_BYTES
              report "axi_read_bridge: client " & integer'image(i) &
                     " request crosses a 4 KiB AXI page"
              severity failure;
          end if;
        end loop;
      end if;
    end if;
  end process;
  -- synthesis translate_on

  u_ar_mux : entity work.axi_ar_mux
    generic map (
      GC_NUM_CLIENTS     => GC_NUM_CLIENTS,
      GC_ADDR_WIDTH      => GC_ADDR_WIDTH,
      GC_ID_WIDTH        => GC_ID_WIDTH,
      GC_FIFO_DEPTH      => GC_CLIENT_FIFO_DEPTH,
      GC_R_BEATS_PER_POP => 1  -- One pop per client beat
    )
    port map (
      aclk      => aclk,
      aresetn   => aclk_aresetn,
      req_addr  => req_addr,
      req_len   => core_req_len,
      req_valid => req_valid,
      req_ready => req_ready,
      r_pop     => core_r_pop,
      ar_id     => mux_ar_id,
      ar_addr   => mux_ar_addr,
      ar_len    => mux_ar_len,
      ar_valid  => mux_ar_valid,
      ar_ready  => mux_ar_ready
    );

  -- AR crossing (aclk -> mem_aclk)

  -- The upper bits of mux_ar_len are always zero, so only the client
  -- length bits are carried across.
  ar_cdc_s_data(C_AR_ID_HI   downto C_AR_ID_LO)   <= mux_ar_id;
  ar_cdc_s_data(C_AR_ADDR_HI downto C_AR_ADDR_LO) <= mux_ar_addr;
  ar_cdc_s_data(C_AR_LEN_HI  downto C_AR_LEN_LO)  <= mux_ar_len(C_CLIENT_ARLEN_WIDTH-1 downto 0);
  ar_cdc_s_valid <= mux_ar_valid;
  mux_ar_ready   <= ar_cdc_s_ready;

  u_ar_cdc : entity work.axis_cdc
    generic map (
      GC_TDATA_WIDTH => C_AR_PAYLOAD_WIDTH,
      GC_CDC_DEPTH   => GC_CDC_DEPTH,
      GC_SYNC_STAGES => GC_SYNC_STAGES
    )
    port map (
      s_axis_aclk   => aclk,
      aresetn       => aresetn,  -- Synchronized inside axis_cdc
      s_axis_tdata  => ar_cdc_s_data,
      s_axis_tvalid => ar_cdc_s_valid,
      s_axis_tready => ar_cdc_s_ready,
      m_axis_aclk   => mem_aclk,
      m_axis_tdata  => ar_cdc_m_data,
      m_axis_tvalid => ar_cdc_m_valid,
      m_axis_tready => ar_cdc_m_ready
    );

  -- Native AR (mem_aclk)
  ar_id    <= ar_cdc_m_data(C_AR_ID_HI   downto C_AR_ID_LO);
  ar_addr  <= ar_cdc_m_data(C_AR_ADDR_HI downto C_AR_ADDR_LO);
  -- Native beats - 1 = (client beats * ratio) - 1: shift left, fill with ones.
  ar_len   <= ar_cdc_m_data(C_AR_LEN_HI  downto C_AR_LEN_LO) & C_LEN_FILL;
  ar_valid <= ar_cdc_m_valid;
  ar_cdc_m_ready <= ar_ready;

  -- Response side (mem_aclk -> aclk)

  -- Packs C_RATIO native beats into one client beat.  Requires the native
  -- slave to keep each burst's beats contiguous (no cross-ID interleave).
  r_ready <= up_s_ready;
  u_r_upsizer : entity work.axis_upsizer
    generic map (
      GC_S_TDATA_WIDTH => C_NATIVE_DATA_WIDTH,
      GC_RATIO         => C_RATIO,
      GC_ID_WIDTH      => GC_ID_WIDTH
    )
    port map (
      aclk          => mem_aclk,
      aresetn       => mem_aresetn,
      s_axis_tdata  => r_data,
      s_axis_tlast  => r_last,
      s_axis_rresp  => r_resp,
      s_axis_rid    => r_id,
      s_axis_tvalid => r_valid,
      s_axis_tready => up_s_ready,
      m_axis_tdata  => up_m_data,
      m_axis_tlast  => up_m_last,
      m_axis_rresp  => up_m_resp,
      m_axis_rid    => up_m_id,
      m_axis_tvalid => up_m_valid,
      m_axis_tready => r_cdc_s_ready
    );

  r_cdc_s_data(C_R_ID_HI   downto C_R_ID_LO)   <= up_m_id;
  r_cdc_s_data(C_R_DATA_HI downto C_R_DATA_LO) <= up_m_data;
  r_cdc_s_data(C_R_RESP_HI downto C_R_RESP_LO) <= up_m_resp;
  r_cdc_s_data(C_R_LAST)                       <= up_m_last;

  u_r_cdc : entity work.axis_cdc
    generic map (
      GC_TDATA_WIDTH => C_R_PAYLOAD_WIDTH,
      GC_CDC_DEPTH   => GC_CDC_DEPTH,
      GC_SYNC_STAGES => GC_SYNC_STAGES
    )
    port map (
      s_axis_aclk   => mem_aclk,
      aresetn       => aresetn,  -- Synchronized inside axis_cdc
      s_axis_tdata  => r_cdc_s_data,
      s_axis_tvalid => up_m_valid,
      s_axis_tready => r_cdc_s_ready,
      m_axis_aclk   => aclk,
      m_axis_tdata  => r_cdc_m_data,
      m_axis_tvalid => r_cdc_m_valid,
      m_axis_tready => r_cdc_m_ready
    );

  -- Routes each client beat by ID (= client index) into that client's FIFO
  -- and pulses core_r_pop when the client consumes a beat.
  u_r_demux : entity work.axi_r_demux
    generic map (
      GC_NUM_CLIENTS => GC_NUM_CLIENTS,
      GC_DATA_BYTES  => GC_CLIENT_DATA_BYTES,
      GC_ID_WIDTH    => GC_ID_WIDTH,
      GC_FIFO_DEPTH  => GC_CLIENT_FIFO_DEPTH
    )
    port map (
      aclk      => aclk,
      aresetn   => aclk_aresetn,
      r_id      => r_cdc_m_data(C_R_ID_HI   downto C_R_ID_LO),
      r_data    => r_cdc_m_data(C_R_DATA_HI downto C_R_DATA_LO),
      r_resp    => r_cdc_m_data(C_R_RESP_HI downto C_R_RESP_LO),
      r_last    => r_cdc_m_data(C_R_LAST),
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
