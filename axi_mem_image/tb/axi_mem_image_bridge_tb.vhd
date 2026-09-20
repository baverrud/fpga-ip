-----------------------------------------------------------------------
--Filename         : axi_mem_image_bridge_tb.vhd
--Description      : Four-client axi_read_bridge integration example.
--                 :
--                 : The bridge converts four client-side 16-byte reads
--                 : into native 4-byte AXI reads.  axi_mem_image supplies
--                 : the native responses from four separate regions of
--                 : demo_image.hex:
--                 :   client 0 -> 0x1000..0x103F
--                 :   client 1 -> 0x2000..0x203F
--                 :   client 2 -> 0x3000..0x303F
--                 :   client 3 -> 0x4000..0x403F
--                 :
--                 : The test intentionally sends all four requests at once
--                 : so the bridge's arbitration and response demultiplexing
--                 : are exercised.  There is no generated-pattern monitor
--                 : in this demo: each client response is compared against
--                 : the byte formula used to generate demo_image.hex.
--                 :
--                 : Run with:
--                 :   run axi_mem_image vhdl modelsim --tb bridge
--                 :   run axi_mem_image vhdl xsim     --tb bridge
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_mem_image_bridge_tb is
end entity;

architecture sim of axi_mem_image_bridge_tb is

  constant C_CLIENTS      : positive := 4;
  constant C_ADDR_WIDTH   : positive := 32;
  constant C_ID_WIDTH     : positive := 4;
  constant C_CLIENT_BYTES : positive := 16;
  constant C_NATIVE_BYTES : positive := 4;
  constant C_CLIENT_LEN  : positive := 6;
  constant C_TIMEOUT      : time := 1 ms;

  signal aclk     : std_logic := '0';
  signal mem_aclk : std_logic := '0';
  signal aresetn  : std_logic := '0';
  signal sim_done : boolean := false;

  -- Four client-side request and response channels.
  signal req_addr  : slv_array_t(0 to C_CLIENTS-1)(C_ADDR_WIDTH-1 downto 0) :=
                     (others => (others => '0'));
  signal req_len   : slv_array_t(0 to C_CLIENTS-1)(C_CLIENT_LEN-1 downto 0) :=
                     (others => (others => '0'));
  signal req_valid : std_logic_vector(0 to C_CLIENTS-1) := (others => '0');
  signal req_ready : std_logic_vector(0 to C_CLIENTS-1);
  signal rsp_data  : slv_array_t(0 to C_CLIENTS-1)(8*C_CLIENT_BYTES-1 downto 0);
  signal rsp_resp  : slv2_array_t(0 to C_CLIENTS-1);
  signal rsp_last  : std_logic_vector(0 to C_CLIENTS-1);
  signal rsp_valid : std_logic_vector(0 to C_CLIENTS-1);
  signal rsp_ready : std_logic_vector(0 to C_CLIENTS-1) := (others => '1');

  -- Native AXI channel between axi_read_bridge and axi_mem_image.
  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;
  signal r_id     : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data   : std_logic_vector(8*C_NATIVE_BYTES-1 downto 0);
  signal r_resp   : std_logic_vector(1 downto 0);
  signal r_last   : std_logic;
  signal r_valid  : std_logic;
  signal r_ready  : std_logic;

begin

  -- The two domains intentionally have different periods.  This keeps the
  -- integration example useful for checking the bridge CDC paths as well
  -- as the image-backed memory slave.
  p_client_clock : process
  begin
    while not sim_done loop
      aclk <= not aclk;
      wait for 5 ns;
    end loop;
    aclk <= '0';
    wait;
  end process;

  p_memory_clock : process
  begin
    while not sim_done loop
      mem_aclk <= not mem_aclk;
      wait for 2 ns;
    end loop;
    mem_aclk <= '0';
    wait;
  end process;

  -- A bounded watchdog converts a deadlock in either CDC path into a
  -- useful regression failure rather than an indefinitely running job.
  p_watchdog : process
  begin
    wait for C_TIMEOUT;
    assert sim_done
      report "axi_mem_image_bridge_tb: watchdog timeout"
      severity failure;
    wait;
  end process;

  -- The bridge is configured for four 16-byte clients and a 4-byte native
  -- bus.  Each client beat therefore becomes four native AXI beats.
  u_bridge : entity work.axi_read_bridge
    generic map (
      GC_NUM_CLIENTS        => C_CLIENTS,
      GC_ADDR_WIDTH         => C_ADDR_WIDTH,
      GC_ID_WIDTH           => C_ID_WIDTH,
      GC_CLIENT_DATA_BYTES  => C_CLIENT_BYTES,
      GC_NATIVE_DATA_BYTES => C_NATIVE_BYTES,
      GC_NATIVE_ARLEN_WIDTH => 8,
      GC_CLIENT_FIFO_DEPTH  => 8,
      GC_CDC_DEPTH          => 4
    )
    port map (
      aclk      => aclk,
      mem_aclk  => mem_aclk,
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
      ar_valid  => ar_valid,
      ar_ready  => ar_ready,
      r_id      => r_id,
      r_data    => r_data,
      r_resp    => r_resp,
      r_last    => r_last,
      r_valid   => r_valid,
      r_ready   => r_ready
    );

  -- Four 64-byte blocks in demo_image.hex are kept as four regions by the
  -- 256-byte gap threshold.  The image store returns zero for a miss, but
  -- the AXI wrapper converts a miss into SLVERR; all requests here are
  -- inside their assigned region and must therefore return OKAY.
  u_image : entity work.axi_mem_image
    generic map (
      GC_DATA_BYTES    => C_NATIVE_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_TIMER_WIDTH   => 8,
      GC_AR_FIFO_DEPTH => 4,
      GC_R_FIFO_DEPTH  => 4,
      GC_FILE          => "axi_mem_image/tb/data/demo_image.hex",
      GC_MAX_REGIONS   => C_CLIENTS,
      GC_GAP_BYTES     => 256,
      GC_REGION_WORDS  => 16
    )
    port map (
      aclk             => mem_aclk,
      aresetn          => aresetn,
      ar_base_enable   => '0',
      ar_jitter_enable => '0',
      r_base_enable    => '0',
      r_jitter_enable  => '0',
      base_latency     => (others => '0'),
      base_beat_gap    => (others => '0'),
      ar_id            => ar_id,
      ar_addr          => ar_addr,
      ar_len           => ar_len,
      ar_valid         => ar_valid,
      ar_ready         => ar_ready,
      r_id             => r_id,
      r_data           => r_data,
      r_resp           => r_resp,
      r_last           => r_last,
      r_valid          => r_valid,
      r_ready          => r_ready
    );

  p_stim : process

    type bool_array_t is array (0 to C_CLIENTS-1) of boolean;
    variable response_seen : bool_array_t := (others => false);
    variable response_count : natural := 0;
    variable wait_count : natural;
    variable zero_client_data : std_logic_vector(8*C_CLIENT_BYTES-1 downto 0) :=
                  (others => '0');

    -- The fixture byte formula is repeated here as a small independent
    -- reference model.  It is deliberately not read from the same file,
    -- so a loader and checker cannot share the same mistake.
    function expected_data(base_addr : natural) return std_logic_vector is
      variable v_data : std_logic_vector(8*C_CLIENT_BYTES-1 downto 0) :=
                        (others => '0');
      variable v_addr : natural;
    begin
      for byte_idx in 0 to C_CLIENT_BYTES - 1 loop
        v_addr := base_addr + byte_idx;
        v_data(8*byte_idx + 7 downto 8*byte_idx) :=
          std_logic_vector(to_unsigned(
            ((v_addr mod 256) + ((v_addr / 256) mod 256)) mod 256, 8));
      end loop;
      return v_data;
    end function;

  begin
    -- Hold reset long enough for both clocks to observe it, then wait one
    -- additional client edge so the bridge starts from a clean delta cycle.
    aresetn <= '0';
    for cycle in 1 to 8 loop
      wait until rising_edge(aclk);
    end loop;
    aresetn <= '1';
    wait until rising_edge(aclk);

    -- Present one request per client at the same time.  The bridge's
    -- arbitration chooses the order, while the returned IDs must route
    -- each 16-byte response back to the correct client.
    for client in 0 to C_CLIENTS - 1 loop
      req_addr(client) <= std_logic_vector(
        to_unsigned(16#1000# * (client + 1), C_ADDR_WIDTH));
      req_len(client) <= (others => '0');
      req_valid(client) <= '1';
    end loop;

    wait until rising_edge(aclk);
    assert req_ready = (req_ready'range => '1')
      report "axi_mem_image_bridge_tb: all four requests were not accepted"
      severity failure;
    req_valid <= (others => '0');

    -- Collect responses in whichever order arbitration produces them.
    -- rsp_ready remains high, so every observed valid beat is a handshake.
    wait_count := 0;
    while response_count < C_CLIENTS loop
      wait until rising_edge(aclk);
      for client in 0 to C_CLIENTS - 1 loop
        if rsp_valid(client) = '1' and not response_seen(client) then
          assert rsp_data(client) = expected_data(16#1000# * (client + 1))
            report "axi_mem_image_bridge_tb: client " & integer'image(client) &
                   " returned the wrong image bytes"
            severity failure;
          assert rsp_resp(client) = "00" and rsp_last(client) = '1'
            report "axi_mem_image_bridge_tb: client " & integer'image(client) &
                   " response sideband was incorrect"
            severity failure;
          response_seen(client) := true;
          response_count := response_count + 1;
        end if;
      end loop;
      wait_count := wait_count + 1;
      assert wait_count < 2000
        report "axi_mem_image_bridge_tb: response timeout"
        severity failure;
    end loop;

    -- A request outside every image region must not be mistaken for a
    -- successful zero-filled hole.  Hold the client response channel low
    -- while the native wrapper produces the error response to verify that
    -- r_valid, data and response remain stable until the handshake.
    rsp_ready(0) <= '0';
    req_addr(0) <= x"00008000";
    req_len(0) <= (others => '0');
    req_valid(0) <= '1';
    wait until rising_edge(aclk);
    while req_ready(0) = '0' loop
      wait until rising_edge(aclk);
    end loop;
    req_valid(0) <= '0';
    for cycle in 1 to 4 loop
      wait until rising_edge(aclk);
      assert rsp_valid(0) = '0' or rsp_resp(0) = "10"
        report "axi_mem_image_bridge_tb: outside-image response changed error code"
        severity failure;
    end loop;
    rsp_ready(0) <= '1';
    wait_count := 0;
    while rsp_valid(0) = '0' loop
      wait until rising_edge(aclk);
      wait_count := wait_count + 1;
      assert wait_count < 2000
        report "axi_mem_image_bridge_tb: outside-image response timeout"
        severity failure;
    end loop;
    assert rsp_data(0) = zero_client_data and
           rsp_resp(0) = "10" and rsp_last(0) = '1'
      report "axi_mem_image_bridge_tb: outside-image response was not zero/SLVERR"
      severity failure;

    report "axi_mem_image_bridge_tb: FOUR CLIENT IMAGE CHECKS PASSED"
      severity note;
    sim_done <= true;
    wait;
  end process;

end architecture;
