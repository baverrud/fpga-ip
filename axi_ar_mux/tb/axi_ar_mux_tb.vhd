-----------------------------------------------------------------------
--Filename         : axi_ar_mux_tb.vhd
--Description      : Self-checking testbench for axi_ar_mux:
--                 :  - Reset: all req_ready low, ar_valid low, no AR txn.
--                 :  - Single transaction + immediate AR handshake; checks
--                 :    req_ready pulse, registered ar_* outputs, and credit
--                 :    decrement by the request beat count.
--                 :  - AR lock: ar_ready held low holds ar_valid high and
--                 :    blocks all new grants until the handshake completes.
--                 :  - Credit limit + pop returns: a request larger than the
--                 :    remaining credit is blocked; r_pop pulses restore
--                 :    credits and unblock it; re-block is verified.
--                 :  - Round-robin fairness: simultaneous requests served in
--                 :    RR order with wrap-around.
--                 :  - Input line rate (hard guard): with all clients
--                 :    requesting and ar_ready high, one AR transaction per
--                 :    clock, ar_valid never deasserts, RR order preserved.
--                 :  - Mid-stream reset while a transaction is in flight.
--                 :  - Watchdog to catch deadlocks instead of hanging.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;  -- slv_array_t, slv8_array_t

entity axi_ar_mux_tb is
  generic (
    GC_NUM_CLIENTS     : positive := 4;
    GC_ADDR_WIDTH      : positive := 32;
    GC_ID_WIDTH        : positive := 4;
    GC_FIFO_DEPTH      : positive := 32;  -- matches the RTL default
    GC_R_BEATS_PER_POP : positive := 1;   -- client beats returned per r_pop
    GC_CLK_PERIOD      : time := 5 ns     -- 200 MHz
  );
end entity;

architecture sim of axi_ar_mux_tb is

  constant C_WAIT_TIMEOUT : positive := 2000;

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';

  signal req_addr  : slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);
  signal req_len   : slv8_array_t(0 to GC_NUM_CLIENTS-1);
  signal req_size  : slv_array_t(0 to GC_NUM_CLIENTS-1)(2 downto 0);
  signal req_burst : slv_array_t(0 to GC_NUM_CLIENTS-1)(1 downto 0);
  signal req_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1) := (others => '0');
  signal req_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal r_pop : std_logic_vector(0 to GC_NUM_CLIENTS-1) := (others => '0');

  signal ar_id    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);
  signal ar_size  : std_logic_vector(2 downto 0);
  signal ar_burst : std_logic_vector(1 downto 0);
  signal ar_valid : std_logic;
  signal ar_ready : std_logic := '0';

  signal sim_done : boolean := false;

  function f_min(a : natural; b : natural) return natural is
  begin
    if a < b then
      return a;
    else
      return b;
    end if;
  end function;

  -- Distinctive address for client c, transaction t.
  function f_addr(c : natural; t : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(c * 256 + t, GC_ADDR_WIDTH));
  end function;

begin

  u_dut : entity work.axi_ar_mux
    generic map (
      GC_NUM_CLIENTS     => GC_NUM_CLIENTS,
      GC_ADDR_WIDTH      => GC_ADDR_WIDTH,
      GC_ID_WIDTH        => GC_ID_WIDTH,
      GC_FIFO_DEPTH      => GC_FIFO_DEPTH,
      GC_R_BEATS_PER_POP => GC_R_BEATS_PER_POP
    )
    port map (
      aclk      => aclk,
      aresetn   => aresetn,
      req_addr  => req_addr,
      req_len   => req_len,
      req_size  => req_size,
      req_burst => req_burst,
      req_valid => req_valid,
      req_ready => req_ready,
      r_pop     => r_pop,
      ar_id     => ar_id,
      ar_addr   => ar_addr,
      ar_len    => ar_len,
      ar_size   => ar_size,
      ar_burst  => ar_burst,
      ar_valid  => ar_valid,
      ar_ready  => ar_ready
    );

  -- Clock generator: hold low for 2 periods, then free-run gated on sim_done.
  p_clk : process
  begin
    aclk <= '0';
    wait for GC_CLK_PERIOD * 2;
    loop
      if sim_done then
        aclk <= '0';
        wait;
      end if;
      aclk <= not aclk;
      wait for GC_CLK_PERIOD / 2;
    end loop;
  end process;

  -- Watchdog (prevents a deadlock from hanging the batch run).
  p_watchdog : process
  begin
    wait for 1 ms;
    if not sim_done then
      report "FAIL: watchdog timeout (possible axi_ar_mux deadlock)" severity failure;
    end if;
    wait;
  end process;

  p_stim : process
    -- Dynamic "other client" index: lets ModelSim avoid a static out-of-range
    -- index when the config has only one client (guard keeps it unused).
    variable v_other : integer := 1;
    variable v_third : integer := 2;
    variable stream_input_count : natural;
    variable stream_ar_count    : natural;
    variable stream_input_hs    : boolean;
    variable stream_ar_present  : boolean;
    -- Present one request and wait for the combinational ready handshake.
    procedure p_send(
      constant cli  : in integer;
      constant addr : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
      constant len  : in std_logic_vector(7 downto 0)
    ) is
      variable wait_count : natural := 0;
    begin
      req_valid(cli) <= '1';
      req_addr(cli)  <= addr;
      req_len(cli)   <= len;
      req_size(cli)  <= "010";  -- 4 bytes
      req_burst(cli) <= "01";   -- INCR
      -- Hold valid until a rising edge observes ready high; that edge is
      -- the capture/handshake edge.  Release valid immediately after so the
      -- same request cannot be granted twice.
      loop
        wait until rising_edge(aclk);
        exit when req_ready(cli) = '1';
        assert wait_count < C_WAIT_TIMEOUT
          report "FAIL: request handshake timeout for client " & integer'image(cli)
          severity failure;
        wait_count := wait_count + 1;
      end loop;
      req_valid(cli) <= '0';
    end procedure;

    -- Assert the AR channel is presenting the given transaction.
    procedure p_check_ar(
      constant cli  : in integer;
      constant addr : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
      constant len  : in std_logic_vector(7 downto 0)
    ) is
    begin
      assert ar_valid = '1'
        report "FAIL: ar_valid not asserted for client " & integer'image(cli)
        severity failure;
      assert ar_id = std_logic_vector(to_unsigned(cli, GC_ID_WIDTH))
        report "FAIL: ar_id mismatch for client " & integer'image(cli)
        severity failure;
      assert ar_addr = addr
        report "FAIL: ar_addr mismatch" severity failure;
      assert ar_len = len
        report "FAIL: ar_len mismatch" severity failure;
      assert ar_size = "010"
        report "FAIL: ar_size not forwarded" severity failure;
      assert ar_burst = "01"
        report "FAIL: ar_burst not forwarded" severity failure;
    end procedure;

    procedure p_wait_ar(
      constant cli  : in integer;
      constant addr : in std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
      constant len  : in std_logic_vector(7 downto 0)
    ) is
      variable wait_count : natural := 0;
    begin
      loop
        if (ar_valid = '1') and
           (ar_id = std_logic_vector(to_unsigned(cli, GC_ID_WIDTH))) and
           (ar_addr = addr) and (ar_len = len) then
          p_check_ar(cli, addr, len);
          return;
        end if;
        assert wait_count < C_WAIT_TIMEOUT
          report "FAIL: AR presentation timeout for client " & integer'image(cli)
          severity failure;
        wait until rising_edge(aclk);
        wait_count := wait_count + 1;
      end loop;
    end procedure;

  begin
    ------------------------------------------------------------------
    -- Reset
    ------------------------------------------------------------------
    aresetn <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait until rising_edge(aclk);

    assert req_ready = (0 to GC_NUM_CLIENTS-1 => '1')
      report "FAIL: empty client buffers should be ready after reset" severity failure;
    assert ar_valid = '0'
      report "FAIL: ar_valid should be '0' after reset" severity failure;

    ------------------------------------------------------------------
    -- Test 1: single transaction, immediate AR handshake
    ------------------------------------------------------------------
    report "AR-MUX PHASE: reset";
    ar_ready <= '1';
    report "AR-MUX PHASE: test1 single transaction";
        p_send(0, f_addr(0, 1),
          std_logic_vector(to_unsigned(f_min(4, GC_FIFO_DEPTH) - 1, 8)));
        p_wait_ar(0, f_addr(0, 1),
         std_logic_vector(to_unsigned(f_min(4, GC_FIFO_DEPTH) - 1, 8)));

    -- p_wait_ar observed the presentation edge; the transfer happened on
    -- that edge (ar_ready high), so one more edge settles the release.
    wait until rising_edge(aclk);
    assert ar_valid = '0'
      report "FAIL: ar_valid should drop after the AR handshake" severity failure;
    assert req_ready(0) = '1'
      report "FAIL: client buffer was not released after the transfer" severity failure;

    ------------------------------------------------------------------
    -- Test 2: AR lock - ar_ready held low holds the transaction
    ------------------------------------------------------------------
    -- Fresh reset for deterministic credits.
    report "AR-MUX PHASE: test2 lock";
    aresetn <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait until rising_edge(aclk);

    ar_ready <= '0';
    p_send(0, f_addr(0, 2), x"01");   -- 2 beats, ar_ready low
    p_wait_ar(0, f_addr(0, 2), x"01");

    -- While locked, ar_valid must hold. One other client may be accepted
    -- into the pending slot, but it must not alter the active AR payload.
    if GC_NUM_CLIENTS >= 2 then
      p_send(v_other, f_addr(v_other, 9), x"00");
    end if;
    if GC_NUM_CLIENTS >= 3 then
      p_send(v_third, f_addr(v_third, 11), x"00");
    end if;
    for k in 0 to 3 loop
      wait until rising_edge(aclk);
      p_check_ar(0, f_addr(0, 2), x"01");
    end loop;

    -- Release: the locked transaction handshakes and the pending request is
    -- promoted immediately on the same edge.
    ar_ready <= '1';
    if GC_NUM_CLIENTS >= 2 then
      p_wait_ar(v_other, f_addr(v_other, 9), x"00");
      if GC_NUM_CLIENTS >= 3 then
        p_wait_ar(v_third, f_addr(v_third, 11), x"00");
        wait until rising_edge(aclk);
      else
        wait until rising_edge(aclk);
        assert ar_valid = '0'
          report "FAIL: pending request did not complete"
          severity failure;
      end if;
    else
      wait until rising_edge(aclk);
      wait until rising_edge(aclk);
      assert ar_valid = '0'
        report "FAIL: locked transaction should complete without pending request"
        severity failure;
    end if;

    ------------------------------------------------------------------
    -- Test 3: credit limit, pop returns, and re-block
    ------------------------------------------------------------------
    report "AR-MUX PHASE: test3 credits";
    aresetn <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait until rising_edge(aclk);
    ar_ready <= '1';

    -- Drain a number of beats no larger than one pop return. One pop then
    -- restores the full budget for every positive pop ratio, including a
    -- ratio larger than the FIFO depth (the RTL saturates at the limit).
    p_send(0, f_addr(0, 3),
         std_logic_vector(to_unsigned(f_min(GC_R_BEATS_PER_POP,
                          GC_FIFO_DEPTH) - 1, 8)));
    p_wait_ar(0, f_addr(0, 3),
          std_logic_vector(to_unsigned(f_min(GC_R_BEATS_PER_POP,
                             GC_FIFO_DEPTH) - 1, 8)));
    wait until rising_edge(aclk);   -- AR handshake

    -- A full-budget (GC_FIFO_DEPTH-beat) request does not fit: must NOT be
    -- granted because the initial drain left fewer than GC_FIFO_DEPTH
    -- credits.
    req_valid(0) <= '1';
    req_addr(0)  <= f_addr(0, 4);
    req_len(0)   <= std_logic_vector(to_unsigned(GC_FIFO_DEPTH - 1, 8));
    req_size(0)  <= "010";
    req_burst(0) <= "01";
    for k in 0 to 5 loop
      wait until rising_edge(aclk);
      assert req_ready(0) = '0'
        report "FAIL: over-credit request granted" severity failure;
      assert ar_valid = '0'
        report "FAIL: ar_valid asserted without credit" severity failure;
    end loop;

    -- One pop returns enough credits to restore the full budget. No further
    -- pops are issued, so the exact credit limit is exercised.
    r_pop(0) <= '1';
    wait until rising_edge(aclk);
    r_pop(0) <= '0';
    req_valid(0) <= '0';
    report "AR-MUX: full-budget request granted after pops";
    p_wait_ar(0, f_addr(0, 4),
              std_logic_vector(to_unsigned(GC_FIFO_DEPTH - 1, 8)));
    wait until rising_edge(aclk);        -- handshake, credit(0) = 0
    req_valid(0) <= '0';

    -- Now even a 1-beat request is blocked until a pop returns credit.
    req_valid(0) <= '1';
    req_addr(0)  <= f_addr(0, 5);
    req_len(0)   <= x"00";
    for k in 0 to 3 loop
      wait until rising_edge(aclk);
      assert req_ready(0) = '0'
        report "FAIL: 1-beat request granted with zero credit" severity failure;
    end loop;
    r_pop(0) <= '1';
    wait until rising_edge(aclk);
    r_pop(0) <= '0';
    report "AR-MUX: waiting for 1-beat grant after pop";
    p_wait_ar(0, f_addr(0, 5), x"00");
    req_valid(0) <= '0';
    wait until rising_edge(aclk);        -- handshake
    req_valid(0) <= '0';

    ------------------------------------------------------------------
    -- Test 3b: simultaneous r_pop and AR handshake
    ------------------------------------------------------------------
    report "AR-MUX PHASE: test3b simultaneous pop and handshake";
    aresetn <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait until rising_edge(aclk);

    -- Hold the AR channel so the request is only presented, then release
    -- with r_pop in the same cycle as the handshake edge.
    ar_ready <= '0';
    p_send(0, f_addr(0, 6),
           std_logic_vector(to_unsigned(GC_FIFO_DEPTH - 1, 8)));
    p_wait_ar(0, f_addr(0, 6),
          std_logic_vector(to_unsigned(GC_FIFO_DEPTH - 1, 8)));
    ar_ready <= '1';
    r_pop(0)  <= '1';
    wait until rising_edge(aclk);       -- AR handshake and credit return
    r_pop(0)  <= '0';

    p_send(0, f_addr(0, 7),
           std_logic_vector(to_unsigned(f_min(GC_R_BEATS_PER_POP,
                                              GC_FIFO_DEPTH) - 1, 8)));
    p_wait_ar(0, f_addr(0, 7),
               std_logic_vector(to_unsigned(f_min(GC_R_BEATS_PER_POP,
                                                   GC_FIFO_DEPTH) - 1, 8)));
    wait until rising_edge(aclk);
    req_valid(0) <= '0';

    ------------------------------------------------------------------
    -- Test 3c: skip an oversized request when another client fits
    ------------------------------------------------------------------
    if GC_NUM_CLIENTS >= 2 then
      report "AR-MUX PHASE: test3c partial-credit arbitration";
      aresetn <= '0';
      wait until rising_edge(aclk);
      wait until rising_edge(aclk);
      aresetn <= '1';
      wait until rising_edge(aclk);
      ar_ready <= '1';

      -- Leave one credit on client 0, then present a two-beat request that
      -- cannot fit while client 1 presents an eligible one-beat request.
      p_send(0, f_addr(0, 8),
             std_logic_vector(to_unsigned(GC_FIFO_DEPTH - 2, 8)));
            p_wait_ar(0, f_addr(0, 8),
            std_logic_vector(to_unsigned(GC_FIFO_DEPTH - 2, 8)));
      wait until rising_edge(aclk);
      req_valid(0) <= '1';
      req_addr(0)  <= f_addr(0, 9);
      req_len(0)   <= x"01";
      req_size(0)  <= "010";
      req_burst(0) <= "01";
      p_send(v_other, f_addr(v_other, 10), x"00");
      p_wait_ar(v_other, f_addr(v_other, 10), x"00");
      wait until rising_edge(aclk);
      req_valid(0) <= '0';
      req_valid(v_other) <= '0';
    end if;

    ------------------------------------------------------------------
    -- Test 3d: unique-payload single-client line rate
    ------------------------------------------------------------------
    report "AR-MUX PHASE: test3d single-client line rate";
    aresetn <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait until rising_edge(aclk);
    ar_ready <= '1';
    req_valid <= (others => '0');
    req_valid(0) <= '1';
    req_addr(0)  <= f_addr(0, 500);
    req_len(0)   <= x"00";
    req_size(0)  <= "010";
    req_burst(0) <= "01";
    stream_input_count := 0;
    stream_ar_count := 0;
    for cycle in 0 to 4 * GC_FIFO_DEPTH + 8 loop
      wait until rising_edge(aclk);
      stream_input_hs := (req_valid(0) = '1') and (req_ready(0) = '1');
      stream_ar_present := (ar_valid = '1') and (ar_ready = '1');
      if ar_valid = '1' then
        p_check_ar(0, f_addr(0, 500 + stream_ar_count), x"00");
      end if;
      if stream_input_hs then
        stream_input_count := stream_input_count + 1;
        if stream_input_count < GC_FIFO_DEPTH then
          req_addr(0) <= f_addr(0, 500 + stream_input_count);
        else
          req_valid(0) <= '0';
        end if;
      end if;
      if stream_ar_present then
        stream_ar_count := stream_ar_count + 1;
      end if;
      exit when (stream_input_count = GC_FIFO_DEPTH) and
                (stream_ar_count = GC_FIFO_DEPTH);
    end loop;
    assert stream_input_count = GC_FIFO_DEPTH
      report "FAIL: single-client stream did not accept full budget"
      severity failure;
    assert stream_ar_count = GC_FIFO_DEPTH
      report "FAIL: single-client stream did not forward full budget"
      severity failure;

    report "AR-MUX PHASE: test4 line rate";
    aresetn <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait until rising_edge(aclk);
    ar_ready <= '1';

    -- All clients request continuously; RR with ar_ready high must sustain
    -- one AR transaction per clock with no bubble on ar_valid.
    req_valid <= (others => '1');
    for i in 0 to GC_NUM_CLIENTS-1 loop
      req_addr(i)  <= f_addr(i, 20);
      req_len(i)   <= x"00";
      req_size(i)  <= "010";
      req_burst(i) <= "01";
    end loop;

    -- Wait for the first pipelined grant to be presented.
    loop
      wait until rising_edge(aclk);
      exit when ar_valid = '1';
    end loop;
    for t in 0 to 2*GC_NUM_CLIENTS-1 loop
      if t > 0 then
        wait until rising_edge(aclk);  -- next txn, presented every edge
      end if;
      assert ar_valid = '1'
        report "FAIL: line-rate bubble on ar_valid at txn " & integer'image(t)
        severity failure;
      assert ar_id = std_logic_vector(to_unsigned(t mod GC_NUM_CLIENTS, GC_ID_WIDTH))
        report "FAIL: line-rate RR order broken at txn " & integer'image(t)
        severity failure;
      p_check_ar(t mod GC_NUM_CLIENTS,
                 f_addr(t mod GC_NUM_CLIENTS, 20), x"00");
    end loop;
    req_valid <= (others => '0');

    -- Each client issued 2 one-beat transactions, so each still has credit.
    -- Verify a client with an exhausted budget blocks: drain client 0 fully.
    report "AR-MUX PHASE: test5 exhaust";
    aresetn <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait until rising_edge(aclk);

    -- Drain client 0's entire credit budget with one-beat requests.
    for k in 1 to GC_FIFO_DEPTH loop
      p_send(0, f_addr(0, 100 + k), x"00");
      p_wait_ar(0, f_addr(0, 100 + k), x"00");
      wait until rising_edge(aclk);   -- handshake, credit decremented
    end loop;
    -- Credit(0) is now 0: a further request must be blocked.
    req_valid(0) <= '1';
    req_addr(0)  <= f_addr(0, 200);
    req_len(0)   <= x"00";
    for k in 0 to 3 loop
      wait until rising_edge(aclk);
      assert req_ready(0) = '0'
        report "FAIL: exhausted client 0 granted" severity failure;
    end loop;
    req_valid(0) <= '0';

    ------------------------------------------------------------------
    -- Test 6: mid-stream reset while a transaction is in flight
    ------------------------------------------------------------------
    report "AR-MUX PHASE: test6 mid-stream reset";
    aresetn <= '0';                     -- fresh credits for this test
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait until rising_edge(aclk);

    ar_ready <= '0';
    p_send(0, f_addr(0, 300),
           std_logic_vector(to_unsigned(f_min(3, GC_FIFO_DEPTH) - 1, 8)));
    p_wait_ar(0, f_addr(0, 300),
              std_logic_vector(to_unsigned(f_min(3, GC_FIFO_DEPTH) - 1, 8)));

    aresetn <= '0';                     -- reset with a locked transaction
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait until rising_edge(aclk);

    assert ar_valid = '0'
      report "FAIL: ar_valid not cleared after mid-stream reset" severity failure;
    assert req_ready = (0 to GC_NUM_CLIENTS-1 => '1')
      report "FAIL: client buffers not ready after mid-stream reset" severity failure;

    -- A post-reset transaction must work normally.
    ar_ready <= '1';
    p_send(0, f_addr(0, 301), x"00");
    p_wait_ar(0, f_addr(0, 301), x"00");
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);

    ------------------------------------------------------------------
    -- Test 7: wider R-side credit returns (GC_R_BEATS_PER_POP > 1)
    ------------------------------------------------------------------
    -- One r_pop returns GC_R_BEATS_PER_POP credits, matching an R channel
    -- widened by an axis_upsizer where one R beat carries multiple client
    -- beats. With the default GC_R_BEATS_PER_POP=1 this test is skipped.
    if GC_R_BEATS_PER_POP > 1 then
      report "AR-MUX PHASE: test7 wider r-side";
      aresetn <= '0';
      wait until rising_edge(aclk);
      wait until rising_edge(aclk);
      aresetn <= '1';
      wait until rising_edge(aclk);
      ar_ready <= '1';

      -- One full-budget request drains the configured credit budget to zero.
      p_send(0, f_addr(0, 400),
             std_logic_vector(to_unsigned(GC_FIFO_DEPTH - 1, 8)));
      p_wait_ar(0, f_addr(0, 400),
                std_logic_vector(to_unsigned(GC_FIFO_DEPTH - 1, 8)));
      wait until rising_edge(aclk);   -- handshake, credit 0

      -- A 1-beat request is blocked at zero credit.
      req_valid(0) <= '1';
      req_addr(0)  <= f_addr(0, 402);
      req_len(0)   <= x"00";
      req_size(0)  <= "010";
      req_burst(0) <= "01";
      for k in 0 to 3 loop
        wait until rising_edge(aclk);
        assert req_ready(0) = '0'
          report "FAIL: wider r-side over-grant at zero credit" severity failure;
      end loop;

      -- ONE pop returns GC_R_BEATS_PER_POP credits, unblocking the 1-beat
      -- request (proves the wider R side is accounted for).
      r_pop(0) <= '1';
      wait until rising_edge(aclk);
      r_pop(0) <= '0';
      req_valid(0) <= '0';
      p_wait_ar(0, f_addr(0, 402), x"00");
      wait until rising_edge(aclk);
      req_valid(0) <= '0';
    end if;

    report "ALL AR-MUX CHECKS PASSED";
    sim_done <= true;
    wait;
  end process;

end architecture;
