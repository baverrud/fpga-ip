-----------------------------------------------------------------------
--Filename         : axi_read_bridge_tb.vhd
--Description      : Integration testbench for axi_read_bridge and
--                 : axi_mem_model. Checks dual-clock transport, native
--                 : ARLEN expansion, upsized response data, response last,
--                 : and multiple client routing.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_bridge_tb is
end entity axi_read_bridge_tb;

architecture sim of axi_read_bridge_tb is
  constant C_NUM_CLIENTS : positive := 4;
  constant C_ADDR_WIDTH  : positive := 32;
  constant C_ID_WIDTH    : positive := 4;
  constant C_CLIENT_BYTES : positive := 64;
  constant C_NATIVE_BYTES : positive := 16;
  constant C_CLIENT_LEN_WIDTH : positive := 6;
  constant C_CLIENT_FIFO_DEPTH : positive := 32;
  constant C_CDC_DEPTH : positive := 8;
  constant C_CLIENT_PERIOD : time := 10 ns;
  constant C_MEM_PERIOD : time := 4 ns;
  constant C_TIMEOUT : time := 2 ms;

  -- Per-client response base addresses for the arbitration (phase 4) test.
  type addr4_t is array (0 to 3) of natural;
  constant C_P4_ADDR : addr4_t := (16#1000#, 16#2000#, 16#3000#, 16#4000#);

  -- Expected native ARLEN per accepted request, in test order (see p_stim):
  --   [0] client 0 len=0  -> 4   native beats -> ARLEN 3
  --   [1] client 1 len=1  -> 8   native beats -> ARLEN 7
  --   [2] client 2 len=2  -> 12  native beats -> ARLEN 11 (backpressure)
  --   [3..6] all four clients len=0 -> 4 each -> ARLEN 3 (arbitration)
  --   [7] client 3 len=31 -> 128 native beats -> ARLEN 127 (credit limit)
  type arlen_seq_t is array (natural range <>) of integer;
  constant C_EXPECTED_ARLEN : arlen_seq_t := (3, 7, 11, 3, 3, 3, 3, 127);

  signal client_aclk : std_logic := '0';
  signal mem_aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal sim_done : boolean := false;

  signal req_addr  : slv_array_t(0 to C_NUM_CLIENTS-1)(C_ADDR_WIDTH-1 downto 0) := (others => (others => '0'));
  signal req_len   : slv_array_t(0 to C_NUM_CLIENTS-1)(C_CLIENT_LEN_WIDTH-1 downto 0) := (others => (others => '0'));
  signal req_valid : std_logic_vector(0 to C_NUM_CLIENTS-1) := (others => '0');
  signal req_ready : std_logic_vector(0 to C_NUM_CLIENTS-1);

  signal rsp_data  : slv_array_t(0 to C_NUM_CLIENTS-1)(8*C_CLIENT_BYTES-1 downto 0);
  signal rsp_resp  : slv2_array_t(0 to C_NUM_CLIENTS-1);
  signal rsp_last  : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal rsp_valid : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal rsp_ready : std_logic_vector(0 to C_NUM_CLIENTS-1) := (others => '1');

  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);
  signal ar_size  : std_logic_vector(2 downto 0);
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;

  signal r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data  : std_logic_vector(8*C_NATIVE_BYTES-1 downto 0);
  signal r_resp  : std_logic_vector(1 downto 0);
  signal r_last  : std_logic;
  signal r_valid : std_logic;
  signal r_ready : std_logic;

  signal ar_seen : natural := 0;
  signal watchdog_expired : boolean := false;

  function f_expected_data(base_addr : natural) return std_logic_vector is
    variable v_data : std_logic_vector(8*C_CLIENT_BYTES-1 downto 0) := (others => '0');
  begin
    for word_idx in 0 to C_CLIENT_BYTES/4-1 loop
      v_data(32*word_idx+31 downto 32*word_idx) :=
        std_logic_vector(to_unsigned(base_addr + word_idx*4, 32));
    end loop;
    return v_data;
  end function;
begin
  p_client_clk : process
  begin
    client_aclk <= '0';
    while not sim_done loop
      wait for C_CLIENT_PERIOD / 2;
      client_aclk <= not client_aclk;
    end loop;
    client_aclk <= '0';
    wait;
  end process;

  p_mem_clk : process
  begin
    mem_aclk <= '0';
    while not sim_done loop
      wait for C_MEM_PERIOD / 2;
      mem_aclk <= not mem_aclk;
    end loop;
    mem_aclk <= '0';
    wait;
  end process;

  p_watchdog : process
  begin
    wait for C_TIMEOUT;
    if not sim_done then
      watchdog_expired <= true;
      report "axi_read_bridge_tb watchdog timeout" severity failure;
    end if;
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
      client_aclk => client_aclk,
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

  u_mem : entity work.axi_mem_model
    generic map (
      GC_DATA_BYTES    => C_NATIVE_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_TIMER_WIDTH   => 16,
      GC_AR_FIFO_DEPTH => 8,
      GC_R_FIFO_DEPTH  => 8
    )
    port map (
      aclk            => mem_aclk,
      aresetn         => aresetn,
      ar_base_enable  => '0',
      ar_jitter_enable => '0',
      r_base_enable   => '0',
      r_jitter_enable => '0',
      base_latency    => (others => '0'),
      base_beat_gap   => (others => '0'),
      ar_id           => ar_id,
      ar_addr         => ar_addr,
      ar_len          => ar_len,
      ar_valid        => ar_valid,
      ar_ready        => ar_ready,
      r_id            => r_id,
      r_data          => r_data,
      r_resp          => r_resp,
      r_last          => r_last,
      r_valid        => r_valid,
      r_ready        => r_ready
    );

  p_ar_monitor : process(mem_aclk)
  begin
    if rising_edge(mem_aclk) then
      if aresetn = '1' and ar_valid = '1' and ar_ready = '1' then
        report "native AR id=" & integer'image(to_integer(unsigned(ar_id))) &
          " len=" & integer'image(to_integer(unsigned(ar_len))) severity note;
        assert ar_size = "100"
          report "native ARSIZE is not 128-bit (4 bytes exponent)"
          severity failure;
        if ar_seen < C_EXPECTED_ARLEN'length then
          assert to_integer(unsigned(ar_len)) = C_EXPECTED_ARLEN(ar_seen)
            report "native ARLEN mismatch at transaction " & integer'image(ar_seen)
            severity failure;
        end if;
        if ar_seen = 7 then
          assert to_integer(unsigned(ar_id)) = 3
            report "max-length native AR not routed to client 3"
            severity failure;
        end if;
        ar_seen <= ar_seen + 1;
      end if;
    end if;
  end process;

  p_stim : process
    variable wait_count : natural;

    -- Wait until the client request is accepted (req_ready high at an edge).
    procedure p_wait_accept(constant idx : natural) is
      variable wait_count : natural;
    begin
      wait_count := 0;
      loop
        wait until rising_edge(client_aclk);
        wait for 1 ns;
        exit when req_ready(idx) = '1';
        wait_count := wait_count + 1;
        assert wait_count < 1000 report "request accept timeout" severity failure;
      end loop;
    end procedure;

    -- Wait until a response handshake occurs (valid AND ready high, sampled
    -- just after the edge). Counting valid alone would re-read the same beat
    -- while it is held for backpressure.
    procedure p_wait_rsp(constant idx : natural) is
      variable wait_count : natural;
    begin
      wait_count := 0;
      loop
        wait until rising_edge(client_aclk);
        wait for 1 ns;
        exit when (rsp_valid(idx) = '1') and (rsp_ready(idx) = '1');
        wait_count := wait_count + 1;
        assert wait_count < 4000 report "response timeout" severity failure;
      end loop;
    end procedure;

    -- Stall the client for two cycles, then accept exactly one response
    -- beat. Backpressure reaches the full R path once the per-client FIFO
    -- fills (demux FIFO -> R CDC -> upsizer skid -> r_ready low -> mem model
    -- stall).
    procedure p_backpressure_rsp(constant idx : natural) is
    begin
      rsp_ready(idx) <= '0';
      wait until rising_edge(client_aclk);
      wait until rising_edge(client_aclk);
      rsp_ready(idx) <= '1';
      p_wait_rsp(idx);
    end procedure;
  begin
    wait for 100 ns;
    aresetn <= '1';

    -- One 512-bit client beat becomes four native 128-bit beats.
    wait until falling_edge(client_aclk);
    req_addr(0) <= x"00001000";
    req_len(0) <= (others => '0');
    req_valid(0) <= '1';
    wait_count := 0;
    loop
      wait until rising_edge(client_aclk);
      wait for 1 ns;
      exit when req_ready(0) = '1';
      wait_count := wait_count + 1;
      assert wait_count < 1000 report "client 0 request timeout" severity failure;
    end loop;
    req_valid(0) <= '0';

    wait_count := 0;
    loop
      wait until rising_edge(client_aclk);
      wait for 1 ns;
      exit when rsp_valid(0) = '1';
      wait_count := wait_count + 1;
      assert wait_count < 2000 report "client 0 response timeout" severity failure;
    end loop;
    assert rsp_data(0) = f_expected_data(16#1000#)
      report "client 0 response data mismatch"
      severity failure;
    assert rsp_resp(0) = "00" and rsp_last(0) = '1'
      report "client 0 response sideband mismatch"
      severity failure;

    -- Two client beats become eight native beats and two 512-bit responses.
    wait until falling_edge(client_aclk);
    req_addr(1) <= x"00002000";
    req_len(1) <= std_logic_vector(to_unsigned(1, C_CLIENT_LEN_WIDTH));
    req_valid(1) <= '1';
    wait_count := 0;
    loop
      wait until rising_edge(client_aclk);
      wait for 1 ns;
      exit when req_ready(1) = '1';
      wait_count := wait_count + 1;
      assert wait_count < 1000 report "client 1 request timeout" severity failure;
    end loop;
    req_valid(1) <= '0';

    wait_count := 0;
    loop
      wait until rising_edge(client_aclk);
      wait for 1 ns;
      exit when rsp_valid(1) = '1';
      wait_count := wait_count + 1;
      assert wait_count < 2000 report "client 1 first response timeout" severity failure;
    end loop;
    assert rsp_data(1) = f_expected_data(16#2000#)
      report "client 1 first response data mismatch"
      severity failure;
    assert rsp_last(1) = '0'
      report "client 1 first response asserted last"
      severity failure;

    wait_count := 0;
    loop
      wait until rising_edge(client_aclk);
      wait for 1 ns;
      exit when rsp_valid(1) = '1';
      wait_count := wait_count + 1;
      assert wait_count < 2000 report "client 1 second response timeout" severity failure;
    end loop;
    assert rsp_data(1) = f_expected_data(16#2040#)
      report "client 1 second response data mismatch"
      severity failure;
    assert rsp_resp(1) = "00" and rsp_last(1) = '1'
      report "client 1 second response sideband mismatch"
      severity failure;

    -- Phase 3: client 2 response under consumer backpressure (rsp_ready(2)
    -- low 2 of every 4 client cycles). Three client beats -> 12 native
    -- beats, native ARLEN 11.
    wait until falling_edge(client_aclk);
    req_addr(2) <= x"00004000";
    req_len(2)  <= std_logic_vector(to_unsigned(2, C_CLIENT_LEN_WIDTH));
    req_valid(2) <= '1';
    p_wait_accept(2);
    req_valid(2) <= '0';
    for n in 0 to 2 loop
      p_backpressure_rsp(2);
      assert rsp_data(2) = f_expected_data(16#4000# + n*64)
        report "client 2 response data mismatch under backpressure"
        severity failure;
      assert rsp_resp(2) = "00"
        report "client 2 response resp mismatch under backpressure"
        severity failure;
      if n = 2 then
        assert rsp_last(2) = '1'
          report "client 2 final response not asserted last"
          severity failure;
      else
        assert rsp_last(2) = '0'
          report "client 2 early response asserted last"
          severity failure;
      end if;
    end loop;
    rsp_ready(2) <= '1';

    -- Phase 4: all four clients request in the same cycle. Exercises
    -- round-robin arbitration in axi_ar_mux and 4-way id routing in
    -- axi_r_demux (client ids 0..3).
    --
    -- Each request is a single-cycle pulse (valid high for one half-cycle).
    -- req_ready is not RR-gated, so all four are accepted on the first
    -- rising edge; the valids are low again before any grant fires, which
    -- keeps the mux live-refill from re-buffering a stale request.
    wait until falling_edge(client_aclk);
    req_addr(0) <= std_logic_vector(to_unsigned(C_P4_ADDR(0), C_ADDR_WIDTH));
    req_len(0)  <= (others => '0');
    req_valid(0) <= '1';
    req_addr(1) <= std_logic_vector(to_unsigned(C_P4_ADDR(1), C_ADDR_WIDTH));
    req_len(1)  <= (others => '0');
    req_valid(1) <= '1';
    req_addr(2) <= std_logic_vector(to_unsigned(C_P4_ADDR(2), C_ADDR_WIDTH));
    req_len(2)  <= (others => '0');
    req_valid(2) <= '1';
    req_addr(3) <= std_logic_vector(to_unsigned(C_P4_ADDR(3), C_ADDR_WIDTH));
    req_len(3)  <= (others => '0');
    req_valid(3) <= '1';
    -- All four are accepted on the first rising edge (all buffers empty, so
    -- req_ready is high only during the accept deltas and cannot be sampled
    -- externally). Deassert the valids before any grant fires so the mux
    -- live-refill cannot re-buffer a stale request.
    wait until rising_edge(client_aclk);
    wait until falling_edge(client_aclk);
    req_valid <= (others => '0');
    -- Responses arrive in grant (round-robin) order, which is not client
    -- order, and each is consumed immediately (rsp_ready high). Poll all
    -- clients and verify each response as it arrives.
    for rcvd in 0 to 3 loop
      wait_count := 0;
      loop
        wait until rising_edge(client_aclk);
        wait for 1 ns;
        exit when (rsp_valid(0) and rsp_ready(0)) = '1' or
                  (rsp_valid(1) and rsp_ready(1)) = '1' or
                  (rsp_valid(2) and rsp_ready(2)) = '1' or
                  (rsp_valid(3) and rsp_ready(3)) = '1';
        wait_count := wait_count + 1;
        assert wait_count < 2000 report "phase 4 response timeout" severity failure;
      end loop;
      for c in 0 to 3 loop
        if (rsp_valid(c) and rsp_ready(c)) = '1' then
          assert rsp_data(c) = f_expected_data(C_P4_ADDR(c))
            report "client " & integer'image(c) & " arbitration data mismatch"
            severity failure;
          assert rsp_resp(c) = "00" and rsp_last(c) = '1'
            report "client " & integer'image(c) & " arbitration sideband mismatch"
            severity failure;
        end if;
      end loop;
    end loop;

    -- Phase 5: maximum-length request that fits the credit budget, consumed
    -- under backpressure. client 3 len=31 -> 32 client beats -> 128 native
    -- beats, native ARLEN 127 (the 8-bit ARLEN limit and exactly
    -- GC_CLIENT_FIFO_DEPTH=32 credits). The client-3 FIFO fills, so the
    -- stall propagates through the full R path to the mem model mid-burst.
    -- Checks f_native_arlen scaling at the boundary and full-length data
    -- ordering under end-to-end backpressure.
    wait until falling_edge(client_aclk);
    req_addr(3) <= x"00005000";
    req_len(3)  <= std_logic_vector(to_unsigned(31, C_CLIENT_LEN_WIDTH));
    req_valid(3) <= '1';
    p_wait_accept(3);
    req_valid(3) <= '0';
    for n in 0 to 31 loop
      p_backpressure_rsp(3);
      assert rsp_data(3) = f_expected_data(16#5000# + n*64)
        report "client 3 max-length data mismatch at beat " & integer'image(n)
        severity failure;
      assert rsp_resp(3) = "00"
        report "client 3 max-length resp mismatch"
        severity failure;
      if n = 31 then
        assert rsp_last(3) = '1'
          report "client 3 max-length final response not asserted last"
          severity failure;
      else
        assert rsp_last(3) = '0'
          report "client 3 max-length early response asserted last"
          severity failure;
      end if;
    end loop;
    rsp_ready(3) <= '1';

    assert ar_seen = 8
      report "unexpected native AR transaction count"
      severity failure;
    report "ALL AXI READ BRIDGE CHECKS PASSED" severity note;
    sim_done <= true;
    wait;
  end process;
end architecture sim;
