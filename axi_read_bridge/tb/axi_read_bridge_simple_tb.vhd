-----------------------------------------------------------------------
--Filename         : axi_read_bridge_simple_tb.vhd
--Description      : Simple, hand-editable testbench for axi_read_bridge.
--                   One client reads from an axi_mem_store native slave.
--                   The sequencer fills the store with a known pattern,
--                   sends four requests of 1..4 client beats, and checks
--                   the native AR transfers and every client response.
--                   Start here when experimenting with the bridge; the
--                   comprehensive testbench is axi_read_bridge_tb.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_bridge_simple_tb is
end entity;

architecture sim of axi_read_bridge_simple_tb is
  constant C_NUM_CLIENTS       : positive := 1;
  constant C_ADDR_WIDTH        : positive := 32;
  constant C_ID_WIDTH          : positive := 4;
  constant C_CLIENT_BYTES      : positive := 64;    -- One client beat
  constant C_NATIVE_BYTES      : positive := 16;    -- One native beat (4 per client beat)
  constant C_CLIENT_LEN_WIDTH  : positive := 6;     -- 8 - log2(64/16)
  constant C_CLIENT_FIFO_DEPTH : positive := 32;
  constant C_CDC_DEPTH         : positive := 8;
  constant C_MEM_BYTES         : positive := 16#4000#;  -- 16 KiB store
  constant C_CLIENT_PERIOD     : time := 10 ns;    -- 100 MHz client clock
  constant C_MEM_PERIOD        : time := 4 ns;     -- 250 MHz native clock
  constant C_TIMEOUT           : time := 2 ms;
  constant C_NUM_REQUESTS      : positive := 4;

  -- Request n reads C_REQUEST_LENS(n) + 1 client beats from
  -- C_REQUEST_ADDRS(n); each client beat is 4 native beats.
  type natural_array_t is array (0 to C_NUM_REQUESTS-1) of natural;
  constant C_REQUEST_ADDRS  : natural_array_t := (16#0000#, 16#1000#, 16#2000#, 16#3000#);
  constant C_REQUEST_LENS   : natural_array_t := (0, 1, 2, 3);
  constant C_EXPECTED_ARLEN : natural_array_t := (3, 7, 11, 15);  -- 4 * beats - 1

  signal aclk     : std_logic := '0';
  signal mem_aclk : std_logic := '0';
  signal aresetn  : std_logic := '0';
  signal sim_done : boolean := false;

  -- Client interface (one client)
  signal req_addr  : slv_array_t(0 to C_NUM_CLIENTS-1)(C_ADDR_WIDTH-1 downto 0) := (others => (others => '0'));
  signal req_len   : slv_array_t(0 to C_NUM_CLIENTS-1)(C_CLIENT_LEN_WIDTH-1 downto 0) := (others => (others => '0'));
  signal req_valid : std_logic_vector(0 to C_NUM_CLIENTS-1) := (others => '0');
  signal req_ready : std_logic_vector(0 to C_NUM_CLIENTS-1);

  signal rsp_data  : slv_array_t(0 to C_NUM_CLIENTS-1)(8*C_CLIENT_BYTES-1 downto 0);
  signal rsp_resp  : slv2_array_t(0 to C_NUM_CLIENTS-1);
  signal rsp_last  : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal rsp_valid : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal rsp_ready : std_logic_vector(0 to C_NUM_CLIENTS-1) := (others => '1');

  -- Debug-friendly 32-bit word views of the wide data buses (wave window).
  signal rsp_data_arr : slv32_array_t(0 to C_CLIENT_BYTES/4-1);
  signal r_data_arr   : slv32_array_t(0 to C_NATIVE_BYTES/4-1);

  -- Native AXI read port between the bridge and the store
  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;

  signal r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data  : std_logic_vector(8*C_NATIVE_BYTES-1 downto 0);
  signal r_resp  : std_logic_vector(1 downto 0);
  signal r_last  : std_logic;
  signal r_valid : std_logic;
  signal r_ready : std_logic;

  -- Store population port (one byte per native clock)
  signal mem_wr_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal mem_wr_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal mem_wr_valid : std_logic := '0';
  signal mem_wr_ready : std_logic;
  signal mem_wr_error : std_logic;

  -- Client beat expected at base_addr: 32-bit word k holds base_addr + 4*k.
  function f_expected_data(base_addr : natural) return std_logic_vector is
    variable v_data : std_logic_vector(8*C_CLIENT_BYTES-1 downto 0) := (others => '0');
  begin
    for word_idx in 0 to C_CLIENT_BYTES/4-1 loop
      v_data(32*word_idx+31 downto 32*word_idx) :=
        std_logic_vector(to_unsigned(base_addr + word_idx*4, 32));
    end loop;
    return v_data;
  end function;

  -- Byte at addr in the same pattern, little endian, for filling the store.
  function f_mem_byte(addr : natural) return std_logic_vector is
    variable v_word : std_logic_vector(31 downto 0);
  begin
    v_word := std_logic_vector(to_unsigned(addr - (addr mod 4), 32));
    return v_word(8*(addr mod 4)+7 downto 8*(addr mod 4));
  end function;
begin

  -- Word 0 is the least-significant 32-bit word, matching f_expected_data.
  p_debug_array_views : process(all)
  begin
    for word_idx in rsp_data_arr'range loop
      rsp_data_arr(word_idx) <= rsp_data(0)(32*word_idx+31 downto 32*word_idx);
    end loop;
    for word_idx in r_data_arr'range loop
      r_data_arr(word_idx) <= r_data(32*word_idx+31 downto 32*word_idx);
    end loop;
  end process;

  aclk     <= not aclk     after C_CLIENT_PERIOD / 2 when not sim_done else '0';
  mem_aclk <= not mem_aclk after C_MEM_PERIOD / 2    when not sim_done else '0';

  p_watchdog : process
  begin
    wait for C_TIMEOUT;
    assert sim_done
      report "axi_read_bridge_simple_tb watchdog timeout" severity failure;
    wait;
  end process;

  u_bridge : entity work.axi_read_bridge
    generic map (
      GC_NUM_CLIENTS        => C_NUM_CLIENTS,
      GC_ADDR_WIDTH         => C_ADDR_WIDTH,
      GC_ID_WIDTH           => C_ID_WIDTH,
      GC_CLIENT_DATA_BYTES  => C_CLIENT_BYTES,
      GC_NATIVE_DATA_BYTES  => C_NATIVE_BYTES,
      GC_NATIVE_ARLEN_WIDTH => 8,
      GC_CLIENT_FIFO_DEPTH  => C_CLIENT_FIFO_DEPTH,
      GC_CDC_DEPTH          => C_CDC_DEPTH
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

  -- Native slave: a real byte store, filled by p_stim before the reads.
  u_mem : entity work.axi_mem_store
    generic map (
      GC_DATA_BYTES     => C_NATIVE_BYTES,
      GC_ADDR_WIDTH     => C_ADDR_WIDTH,
      GC_ID_WIDTH       => C_ID_WIDTH,
      GC_TIMER_WIDTH    => 16,
      GC_AR_FIFO_DEPTH  => C_CDC_DEPTH,
      GC_R_FIFO_DEPTH   => C_CDC_DEPTH,
      GC_MEM_SIZE_BYTES => C_MEM_BYTES
    )
    port map (
      aclk             => mem_aclk,
      aresetn          => aresetn,
      ar_base_enable   => '0',  -- No added latency: functional test only
      ar_jitter_enable => '0',
      r_base_enable    => '0',
      r_jitter_enable  => '0',
      base_latency     => (others => '0'),
      base_beat_gap    => (others => '0'),
      mem_wr_addr      => mem_wr_addr,
      mem_wr_data      => mem_wr_data,
      mem_wr_valid     => mem_wr_valid,
      mem_wr_ready     => mem_wr_ready,
      mem_wr_error     => mem_wr_error,
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

  -- Checks each native AR against the request table.
  p_ar_monitor : process(mem_aclk)
    variable ar_seen : natural := 0;
  begin
    if rising_edge(mem_aclk) then
      if (aresetn = '1') and (ar_valid = '1') and (ar_ready = '1') then
        assert ar_id = std_logic_vector(to_unsigned(0, C_ID_WIDTH))
          report "native AR ID mismatch"
          severity failure;
        assert ar_seen < C_NUM_REQUESTS
          report "unexpected extra native AR transfer"
          severity failure;
        if ar_seen < C_NUM_REQUESTS then
          assert ar_addr = std_logic_vector(to_unsigned(C_REQUEST_ADDRS(ar_seen), C_ADDR_WIDTH))
            report "native AR address mismatch"
            severity failure;
          assert to_integer(unsigned(ar_len)) = C_EXPECTED_ARLEN(ar_seen)
            report "native ARLEN mismatch"
            severity failure;
        end if;
        ar_seen := ar_seen + 1;
      end if;
    end if;
  end process;

  p_stim : process
    variable expected_last : std_logic;

    procedure wait_cycles(n : natural) is
    begin
      for i in 1 to n loop
        wait until rising_edge(aclk);
      end loop;
    end procedure;

    -- Present one request and hold it until it is accepted.
    procedure send_request(constant address : natural;
                           constant length  : natural) is
    begin
      req_addr(0)  <= std_logic_vector(to_unsigned(address, C_ADDR_WIDTH));
      req_len(0)   <= std_logic_vector(to_unsigned(length, C_CLIENT_LEN_WIDTH));
      req_valid(0) <= '1';
      loop
        wait until rising_edge(aclk);
        exit when req_ready(0) = '1';
      end loop;
      req_valid(0) <= '0';
    end procedure;
  begin
    -- Reset, then fill the store one byte per native clock.
    wait_cycles(2);
    aresetn <= '1';
    wait until rising_edge(mem_aclk);
    for addr in 0 to C_MEM_BYTES-1 loop
      mem_wr_addr  <= std_logic_vector(to_unsigned(addr, C_ADDR_WIDTH));
      mem_wr_data  <= f_mem_byte(addr);
      mem_wr_valid <= '1';
      wait until rising_edge(mem_aclk);
      assert mem_wr_error = '0'
        report "store population write error" severity failure;
    end loop;
    mem_wr_valid <= '0';
    wait_cycles(2);

    -- Issue all four requests back to back; responses queue in the
    -- client FIFO (rsp_ready stays high, so they drain as they arrive).
    for request_idx in 0 to C_NUM_REQUESTS-1 loop
      send_request(C_REQUEST_ADDRS(request_idx), C_REQUEST_LENS(request_idx));
    end loop;

    -- Every client beat must carry the pattern of its own address, OKAY,
    -- and last only on the final beat of its request.
    for request_idx in 0 to C_NUM_REQUESTS-1 loop
      for beat_idx in 0 to C_REQUEST_LENS(request_idx) loop
        loop
          wait until rising_edge(aclk);
          exit when (rsp_valid(0) = '1') and (rsp_ready(0) = '1');
        end loop;
        expected_last := '0';
        if beat_idx = C_REQUEST_LENS(request_idx) then
          expected_last := '1';
        end if;
        assert rsp_data(0) = f_expected_data(
          C_REQUEST_ADDRS(request_idx) + beat_idx * C_CLIENT_BYTES)
          report "client response data mismatch"
          severity failure;
        assert rsp_resp(0) = "00"
          report "client response error"
          severity failure;
        assert rsp_last(0) = expected_last
          report "client response last mismatch"
          severity failure;
      end loop;
    end loop;

    report "axi_read_bridge_simple_tb PASSED" severity note;
    sim_done <= true;
    wait;
  end process;

end architecture sim;
