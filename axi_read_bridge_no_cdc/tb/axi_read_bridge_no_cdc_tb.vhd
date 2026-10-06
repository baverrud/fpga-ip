-----------------------------------------------------------------------
--Filename         : axi_read_bridge_no_cdc_tb.vhd
--Description      : Multi-client 512-bit direct-path regression bench.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_bridge_no_cdc_tb is
end entity;

architecture sim of axi_read_bridge_no_cdc_tb is
  constant C_NUM_CLIENTS : positive := 4;
  constant C_ADDR_WIDTH  : positive := 32;
  constant C_ID_WIDTH    : positive := 4;
  constant C_FIFO_DEPTH  : positive := 8;
  constant C_TIMEOUT     : time := 100 us;

  type natural_array_t is array (natural range <>) of natural;
  constant C_ADDRS : natural_array_t(0 to C_NUM_CLIENTS-1) :=
    (16#1000#, 16#2000#, 16#3000#, 16#4000#);

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal sim_done : std_logic := '0';

  signal req_addr  : slv_array_t(0 to C_NUM_CLIENTS-1)(C_ADDR_WIDTH-1 downto 0) := (others => (others => '0'));
  signal req_len   : slv8_array_t(0 to C_NUM_CLIENTS-1) := (others => (others => '0'));
  signal req_valid : std_logic_vector(0 to C_NUM_CLIENTS-1) := (others => '0');
  signal req_ready : std_logic_vector(0 to C_NUM_CLIENTS-1);

  signal rsp_data  : slv_array_t(0 to C_NUM_CLIENTS-1)(511 downto 0);
  signal rsp_data_arr : slv32_array_t(0 to C_NUM_CLIENTS*16-1);
  signal rsp_resp  : slv2_array_t(0 to C_NUM_CLIENTS-1);
  signal rsp_last  : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal rsp_valid : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal rsp_ready : std_logic_vector(0 to C_NUM_CLIENTS-1) := (others => '0');

  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;

  signal r_id      : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data    : std_logic_vector(511 downto 0);
  signal r_data_arr : slv32_array_t(0 to 15);
  signal r_resp    : std_logic_vector(1 downto 0);
  signal r_last  : std_logic;
  signal r_valid : std_logic;
  signal r_ready : std_logic;

  function f_data(client_idx : natural; beat_idx : natural)
    return std_logic_vector is
    variable v_data : std_logic_vector(511 downto 0);
    variable v_addr : natural;
  begin
    for word_idx in 0 to 15 loop
      v_addr := C_ADDRS(client_idx) + beat_idx * 64 + word_idx * 4;
      v_data(32*word_idx+31 downto 32*word_idx) :=
        std_logic_vector(to_unsigned(v_addr, 32));
    end loop;
    return v_data;
  end function;
begin
  aclk <= not aclk after 5 ns when sim_done = '0' else '0';

  gen_r_data_words : for word_idx in 0 to 15 generate
    r_data_arr(word_idx) <= r_data(32*word_idx+31 downto 32*word_idx);
  end generate;

  gen_rsp_clients : for client_idx in 0 to C_NUM_CLIENTS-1 generate
    gen_rsp_words : for word_idx in 0 to 15 generate
      rsp_data_arr(client_idx*16+word_idx) <=
        rsp_data(client_idx)(32*word_idx+31 downto 32*word_idx);
    end generate;
  end generate;

  u_dut : entity work.axi_read_bridge_no_cdc
    generic map (
      GC_NUM_CLIENTS       => C_NUM_CLIENTS,
      GC_ADDR_WIDTH        => C_ADDR_WIDTH,
      GC_ID_WIDTH          => C_ID_WIDTH,
      GC_CLIENT_FIFO_DEPTH => C_FIFO_DEPTH
    )
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
      ar_valid  => ar_valid,
      ar_ready  => ar_ready,
      r_id      => r_id,
      r_data    => r_data,
      r_resp    => r_resp,
      r_last    => r_last,
      r_valid   => r_valid,
      r_ready   => r_ready
    );

  u_mem_model : entity work.axi_mem_model
    generic map (
      GC_DATA_BYTES    => 64,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_TIMER_WIDTH   => 16,
      GC_AR_FIFO_DEPTH => C_FIFO_DEPTH,
      GC_R_FIFO_DEPTH  => C_FIFO_DEPTH
    )
    port map (
      aclk             => aclk,
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
      r_resp            => r_resp,
      r_last            => r_last,
      r_valid           => r_valid,
      r_ready           => r_ready
    );

  p_watchdog : process
  begin
    wait for C_TIMEOUT;
    assert sim_done = '1'
      report "axi_read_bridge_no_cdc_tb watchdog timeout"
      severity failure;
    wait;
  end process;

  p_r_data_helper_check : process(aclk)
    variable beats_seen   : natural_array_t(0 to C_NUM_CLIENTS-1) := (others => 0);
    variable client_idx   : natural;
    variable expected_data : std_logic_vector(511 downto 0);
  begin
    if rising_edge(aclk) and aresetn = '1' and r_valid = '1' and r_ready = '1' then
      client_idx := to_integer(unsigned(r_id));
      assert client_idx < C_NUM_CLIENTS
        report "native R ID outside client range" severity failure;
      if client_idx < C_NUM_CLIENTS then
        expected_data := f_data(client_idx, beats_seen(client_idx));
        for word_idx in 0 to 15 loop
          assert r_data_arr(word_idx) = expected_data(32*word_idx+31 downto 32*word_idx)
            report "native R data helper word mismatch" severity failure;
        end loop;
        if r_last = '1' then
          beats_seen(client_idx) := 0;
        else
          beats_seen(client_idx) := beats_seen(client_idx) + 1;
        end if;
      end if;
    end if;
  end process;

  p_stim : process
    variable ar_seen  : std_logic_vector(0 to C_NUM_CLIENTS-1);
    variable ar_order : natural_array_t(0 to C_NUM_CLIENTS-1);
    variable ar_count : natural;
    variable client_idx : natural;
    variable expected_last : std_logic;
    variable expected_data : std_logic_vector(511 downto 0);

    procedure wait_cycles(n : natural) is
    begin
      for cycle in 1 to n loop
        wait until rising_edge(aclk);
      end loop;
    end procedure;
  begin
    aresetn <= '0';
    req_valid <= (others => '0');
    rsp_ready <= (others => '0');
    wait_cycles(4);
    aresetn <= '1';
    wait_cycles(2);

    for client in 0 to C_NUM_CLIENTS-1 loop
      req_addr(client) <= std_logic_vector(to_unsigned(C_ADDRS(client), C_ADDR_WIDTH));
      req_len(client) <= std_logic_vector(to_unsigned(client, 8));
      req_valid(client) <= '1';
    end loop;
    loop
      wait until rising_edge(aclk);
      for client in 0 to C_NUM_CLIENTS-1 loop
        if req_ready(client) = '1' then
          req_valid(client) <= '0';
        end if;
      end loop;
      exit when req_valid = (req_valid'range => '0');
    end loop;

    ar_seen := (others => '0');
    ar_count := 0;
    while ar_count < C_NUM_CLIENTS loop
      wait until rising_edge(aclk);
      if ar_valid = '1' and ar_ready = '1' then
        client_idx := to_integer(unsigned(ar_id));
        assert client_idx < C_NUM_CLIENTS
          report "native AR ID outside client range" severity failure;
        if client_idx < C_NUM_CLIENTS then
          assert ar_seen(client_idx) = '0'
            report "duplicate native AR ID" severity failure;
          assert ar_addr = std_logic_vector(to_unsigned(C_ADDRS(client_idx), C_ADDR_WIDTH))
            report "native AR address mismatch" severity failure;
          assert to_integer(unsigned(ar_len)) = client_idx
            report "native ARLEN mismatch" severity failure;
          ar_seen(client_idx) := '1';
          ar_order(ar_count) := client_idx;
        end if;
        ar_count := ar_count + 1;
      end if;
    end loop;

    -- Hold client outputs to exercise per-client response FIFO buffering.
    for client in 0 to C_NUM_CLIENTS-1 loop
      rsp_ready(client) <= '1';
      for beat_idx in 0 to client loop
        loop
          wait until rising_edge(aclk);
          exit when rsp_valid(client) = '1';
        end loop;
        expected_last := '0';
        if beat_idx = client then
          expected_last := '1';
        end if;
        expected_data := f_data(client, beat_idx);
        assert rsp_data(client) = expected_data
          report "512-bit response data mismatch" severity failure;
        for word_idx in 0 to 15 loop
          assert rsp_data_arr(client*16+word_idx) =
                 expected_data(32*word_idx+31 downto 32*word_idx)
            report "client response data helper word mismatch" severity failure;
        end loop;
        assert rsp_resp(client) = "00"
          report "response status mismatch" severity failure;
        assert rsp_last(client) = expected_last
          report "response last mismatch" severity failure;
      end loop;
      rsp_ready(client) <= '0';
    end loop;

    report "axi_read_bridge_no_cdc_tb PASSED" severity note;
    sim_done <= '1';
    wait;
  end process;
end architecture sim;