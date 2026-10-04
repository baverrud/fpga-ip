-----------------------------------------------------------------------
--Filename         : axi_ar_mux_tb.vhd
--Description      : Self-checking testbench for axi_ar_mux (revision 2.00).
--                 :
--                 : Structure:
--                 :  - p_stim's main sequence (at the bottom of p_stim) is a
--                 :    list of named tests. Read it first.
--                 :  - Every test starts with p_reset_dut, so it begins with
--                 :    full credits and empty registers.
--                 :  - Tests are built from small helpers (present, send,
--                 :    withdraw, pulse r_pop, expect refused, wait for AR,
--                 :    stream). Burst sizes are given in beats; f_arlen
--                 :    converts to AXI ARLEN in one place.
--                 :
--                 : Tests:
--                 :  test_reset_state             all req_ready high, AR idle
--                 :  test_first_request_line_rate one request per clock
--                 :                               straight after reset
--                 :  test_single_transaction      payload, holding release
--                 :  test_ar_stall                ar_ready low holds AR; one
--                 :                               grant waits in ar_pending
--                 :  test_credit_limit            refuse, pop, accept
--                 :  test_pop_during_handshake    same-cycle r_pop counted
--                 :  test_refused_does_not_block  other clients still served
--                 :  test_single_client_stream    full budget at line rate
--                 :  test_all_clients_line_rate   round robin, no bubble
--                 :  test_exhausted_client        zero credit blocks
--                 :  test_reset_while_stalled     clean recovery
--                 :  test_wide_r_side             GC_R_BEATS_PER_POP > 1
--                 :
--                 : Credit returns reach req_ready two edges after r_pop,
--                 : so tests that wait on credit keep presenting the request.
--                 : A watchdog fails the run instead of hanging on deadlock.
--Author           : Rune Baeverrud
--Current Revision : 2.00
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

  -- Maximum number of clocks any wait loop may take before the test fails.
  constant C_WAIT_TIMEOUT : positive := 2000;

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';

  signal req_addr  : slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0) := (others => (others => '0'));
  signal req_len   : slv8_array_t(0 to GC_NUM_CLIENTS-1) := (others => (others => '0'));
  signal req_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1) := (others => '0');
  signal req_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal r_pop : std_logic_vector(0 to GC_NUM_CLIENTS-1) := (others => '0');

  signal ar_id    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);
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

  -- Distinctive address for client c, request number n, so a wrong or
  -- repeated AR payload is caught by p_check_ar_is.
  function f_addr(c : natural; n : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(c * 256 + n, GC_ADDR_WIDTH));
  end function;

  -- AXI ARLEN for a burst of the given number of beats.
  function f_arlen(beats : positive) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(beats - 1, 8));
  end function;

  -- The mux uses the client index as AR ID.
  function f_id(client : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(client, GC_ID_WIDTH));
  end function;

  -- Burst sizes that stay legal for every configured GC_FIFO_DEPTH.
  constant C_SHORT_BURST   : positive := f_min(4, GC_FIFO_DEPTH);
  -- A burst that one r_pop pulse pays back in full.
  constant C_ONE_POP_BURST : positive := f_min(GC_R_BEATS_PER_POP, GC_FIFO_DEPTH);

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
      req_valid => req_valid,
      req_ready => req_ready,
      r_pop     => r_pop,
      ar_id     => ar_id,
      ar_addr   => ar_addr,
      ar_len    => ar_len,
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

  -- Stimulus and checking: helpers, then one procedure per test, then the
  -- main sequence that runs them (at the bottom).
  p_stim : process

    ---------------------------------------------------------------------
    -- Helpers: clock and reset
    ---------------------------------------------------------------------

    procedure p_wait_clocks(n : natural) is
    begin
      for k in 1 to n loop
        wait until rising_edge(aclk);
      end loop;
    end procedure;

    -- Every test starts here: all TB inputs idle, ar_ready high, and a
    -- two-clock synchronous reset, so credits are full and registers empty.
    procedure p_start_test(name : string) is
    begin
      report "AR-MUX TEST: " & name;
      req_valid <= (others => '0');
      r_pop     <= (others => '0');
      ar_ready  <= '1';
      aresetn   <= '0';
      p_wait_clocks(2);
      aresetn   <= '1';
      p_wait_clocks(1);
    end procedure;

    ---------------------------------------------------------------------
    -- Helpers: client side
    ---------------------------------------------------------------------
    -- A note on sampling: right after 'wait until rising_edge(aclk)' the
    -- DUT registers have not updated yet, so every DUT output still shows
    -- the value it had AT that edge. That is what these helpers check.

    -- Put a request on client c's interface and leave it there.
    procedure p_present(c : natural; addr : std_logic_vector; beats : positive) is
    begin
      req_addr(c)  <= addr;
      req_len(c)   <= f_arlen(beats);
      req_valid(c) <= '1';
    end procedure;

    procedure p_withdraw(c : natural) is
    begin
      req_valid(c) <= '0';
    end procedure;

    -- Present a request, wait until it is accepted, then withdraw it so the
    -- same request cannot be accepted twice.
    procedure p_send(c : natural; addr : std_logic_vector; beats : positive) is
    begin
      p_present(c, addr, beats);
      for k in 1 to C_WAIT_TIMEOUT loop
        wait until rising_edge(aclk);
        if req_ready(c) = '1' then
          p_withdraw(c);
          return;
        end if;
      end loop;
      report "FAIL: request never accepted for client " & integer'image(c)
        severity failure;
    end procedure;

    -- Client c's presented request must stay refused for n clocks.
    procedure p_expect_refused(c : natural; n : positive; failure_text : string) is
    begin
      for k in 1 to n loop
        wait until rising_edge(aclk);
        assert req_ready(c) = '0'
          report "FAIL: " & failure_text & " (client " & integer'image(c) & ")"
          severity failure;
      end loop;
    end procedure;

    -- One r_pop pulse returns GC_R_BEATS_PER_POP credits to client c.
    procedure p_pop(c : natural) is
    begin
      r_pop(c) <= '1';
      wait until rising_edge(aclk);
      r_pop(c) <= '0';
    end procedure;

    ---------------------------------------------------------------------
    -- Helpers: AR side
    ---------------------------------------------------------------------

    -- The AR port must be presenting exactly this transaction.
    procedure p_check_ar_is(c : natural; addr : std_logic_vector; beats : positive) is
    begin
      assert ar_valid = '1'
        report "FAIL: ar_valid low, expected client " & integer'image(c) severity failure;
      assert ar_id = f_id(c)
        report "FAIL: ar_id is not client " & integer'image(c) severity failure;
      assert ar_addr = addr
        report "FAIL: wrong ar_addr for client " & integer'image(c) severity failure;
      assert ar_len = f_arlen(beats)
        report "FAIL: wrong ar_len for client " & integer'image(c) severity failure;
    end procedure;

    -- Wait until this transaction is on the AR port. Returns on that edge;
    -- with ar_ready high, that edge is also its transfer. Transactions of
    -- other clients presented first are skipped.
    procedure p_wait_ar(c : natural; addr : std_logic_vector; beats : positive) is
    begin
      for k in 0 to C_WAIT_TIMEOUT loop
        if ar_valid = '1' and ar_id = f_id(c) and ar_addr = addr and
           ar_len = f_arlen(beats) then
          return;
        end if;
        wait until rising_edge(aclk);
      end loop;
      report "FAIL: AR transaction never presented for client " & integer'image(c)
        severity failure;
    end procedure;

    -- Client 0 streams n one-beat requests with addresses f_addr(0, first),
    -- f_addr(0, first + 1), ... changing the address after every accept.
    -- Checks that every AR transfer carries the next address in order, and
    -- that req_ready never drops while a request is presented.
    procedure p_stream_client0(n : positive; first : natural) is
      variable accepted    : natural := 0;
      variable transferred : natural := 0;
    begin
      p_present(0, f_addr(0, first), 1);
      for k in 1 to 4 * n + 8 loop
        wait until rising_edge(aclk);
        if ar_valid = '1' and ar_ready = '1' then
          p_check_ar_is(0, f_addr(0, first + transferred), 1);
          transferred := transferred + 1;
        end if;
        if req_valid(0) = '1' then
          assert req_ready(0) = '1'
            report "FAIL: req_ready bubble after " & integer'image(accepted) &
                   " accepted requests"
            severity failure;
          accepted := accepted + 1;
          if accepted < n then
            req_addr(0) <= f_addr(0, first + accepted);
          else
            p_withdraw(0);
          end if;
        end if;
        exit when (accepted = n) and (transferred = n);
      end loop;
      assert accepted = n
        report "FAIL: stream accepted " & integer'image(accepted) & " of " &
               integer'image(n) & " requests"
        severity failure;
      assert transferred = n
        report "FAIL: stream forwarded " & integer'image(transferred) & " of " &
               integer'image(n) & " requests"
        severity failure;
    end procedure;

    ---------------------------------------------------------------------
    -- Tests
    ---------------------------------------------------------------------

    -- After reset every holding register is empty and nobody is presenting,
    -- so every client must be ready and the AR port idle.
    procedure test_reset_state is
    begin
      p_start_test("reset state");
      assert req_ready = (0 to GC_NUM_CLIENTS-1 => '1')
        report "FAIL: req_ready not high after reset" severity failure;
      assert ar_valid = '0'
        report "FAIL: ar_valid not low after reset" severity failure;
    end procedure;

    -- A client holding req_valid high must be accepted on every clock from
    -- the very first one. This relies on a holding register being free on
    -- the clock its request is granted; a bubble would halve the input rate.
    procedure test_first_request_line_rate is
    begin
      p_start_test("first-request line rate");
      p_stream_client0(C_SHORT_BURST, 0);
    end procedure;

    -- One request, forwarded with the right payload, after which the
    -- holding register is free again.
    procedure test_single_transaction is
    begin
      p_start_test("single transaction");
      p_send(0, f_addr(0, 1), C_SHORT_BURST);
      p_wait_ar(0, f_addr(0, 1), C_SHORT_BURST);
      p_wait_clocks(1);
      assert ar_valid = '0'
        report "FAIL: ar_valid still high after the AR transfer" severity failure;
      assert req_ready(0) = '1'
        report "FAIL: holding register not released after the transfer" severity failure;
    end procedure;

    -- With ar_ready low the AR payload must not change. Client 1's grant
    -- waits in ar_pending, client 2's request waits in its holding
    -- register. After release all three transfer in order and AR drains.
    procedure test_ar_stall is
    begin
      p_start_test("AR stall");
      ar_ready <= '0';
      p_send(0, f_addr(0, 2), 2);
      p_wait_ar(0, f_addr(0, 2), 2);
      if GC_NUM_CLIENTS >= 2 then
        p_send(1, f_addr(1, 9), 1);
      end if;
      if GC_NUM_CLIENTS >= 3 then
        p_send(2, f_addr(2, 11), 1);
      end if;
      for k in 1 to 4 loop
        wait until rising_edge(aclk);
        p_check_ar_is(0, f_addr(0, 2), 2);
      end loop;

      ar_ready <= '1';
      if GC_NUM_CLIENTS >= 2 then
        p_wait_ar(1, f_addr(1, 9), 1);
      end if;
      if GC_NUM_CLIENTS >= 3 then
        p_wait_ar(2, f_addr(2, 11), 1);
      end if;
      p_wait_clocks(2);
      assert ar_valid = '0'
        report "FAIL: AR channel did not drain after the stall" severity failure;
    end procedure;

    -- Spend a little credit, then present a full-budget request: it no
    -- longer fits and must be refused. One r_pop pays the spent credit back
    -- and the request is accepted. That leaves zero credit, so even a
    -- one-beat request is refused until the next r_pop.
    procedure test_credit_limit is
    begin
      p_start_test("credit limit");
      p_send(0, f_addr(0, 3), C_ONE_POP_BURST);
      p_wait_ar(0, f_addr(0, 3), C_ONE_POP_BURST);

      p_present(0, f_addr(0, 4), GC_FIFO_DEPTH);
      p_expect_refused(0, 6, "full-budget request accepted without credit");
      p_pop(0);
      p_send(0, f_addr(0, 4), GC_FIFO_DEPTH);  -- still presented; accepted two edges after the pop
      p_wait_ar(0, f_addr(0, 4), GC_FIFO_DEPTH);

      p_present(0, f_addr(0, 5), 1);
      p_expect_refused(0, 4, "one-beat request accepted with zero credit");
      p_pop(0);
      p_send(0, f_addr(0, 5), 1);
      p_wait_ar(0, f_addr(0, 5), 1);
    end procedure;

    -- Spend the whole budget while ar_ready is low, then release AR with
    -- r_pop high on the same clock. The returned credit must not be lost.
    procedure test_pop_during_handshake is
    begin
      p_start_test("pop during AR handshake");
      ar_ready <= '0';
      p_send(0, f_addr(0, 6), GC_FIFO_DEPTH);
      p_wait_ar(0, f_addr(0, 6), GC_FIFO_DEPTH);
      ar_ready <= '1';
      p_pop(0);  -- same edge as the AR transfer
      p_send(0, f_addr(0, 7), C_ONE_POP_BURST);
      p_wait_ar(0, f_addr(0, 7), C_ONE_POP_BURST);
    end procedure;

    -- Client 0 has one credit left and presents a two-beat request it cannot
    -- afford. That request never enters the mux, so client 1 must still be
    -- served, and client 0 must still be refused.
    procedure test_refused_does_not_block is
    begin
      p_start_test("refused request does not block others");
      p_send(0, f_addr(0, 8), GC_FIFO_DEPTH - 1);
      p_wait_ar(0, f_addr(0, 8), GC_FIFO_DEPTH - 1);
      p_present(0, f_addr(0, 9), 2);
      p_send(1, f_addr(1, 10), 1);
      p_wait_ar(1, f_addr(1, 10), 1);
      assert req_ready(0) = '0'
        report "FAIL: client 0 accepted a request it cannot afford" severity failure;
      p_withdraw(0);
    end procedure;

    -- One client spends its whole budget at one request per clock; every
    -- request is forwarded, in order, with its own address.
    procedure test_single_client_stream is
    begin
      p_start_test("single-client stream");
      p_stream_client0(GC_FIFO_DEPTH, 500);
    end procedure;

    -- Every client requests continuously. The AR channel must carry one
    -- transaction per clock in round-robin order from client 0, for two
    -- full rounds.
    procedure test_all_clients_line_rate is
    begin
      p_start_test("all-client line rate");
      for c in 0 to GC_NUM_CLIENTS-1 loop
        p_present(c, f_addr(c, 20), 1);
      end loop;
      for k in 1 to C_WAIT_TIMEOUT loop
        wait until rising_edge(aclk);
        exit when ar_valid = '1';
      end loop;
      for n in 0 to 2 * GC_NUM_CLIENTS - 1 loop
        if n > 0 then
          wait until rising_edge(aclk);
        end if;
        p_check_ar_is(n mod GC_NUM_CLIENTS, f_addr(n mod GC_NUM_CLIENTS, 20), 1);
      end loop;
      req_valid <= (others => '0');
    end procedure;

    -- Spend the whole budget one beat at a time; the next request must be
    -- refused.
    procedure test_exhausted_client is
    begin
      p_start_test("exhausted client");
      for n in 1 to GC_FIFO_DEPTH loop
        p_send(0, f_addr(0, 100 + n), 1);
        p_wait_ar(0, f_addr(0, 100 + n), 1);
      end loop;
      p_present(0, f_addr(0, 200), 1);
      p_expect_refused(0, 4, "exhausted client accepted");
      p_withdraw(0);
    end procedure;

    -- Reset while a transaction is stalled on the AR port. Afterwards the
    -- port must be idle, every client ready, and traffic must work again.
    procedure test_reset_while_stalled is
    begin
      p_start_test("reset while stalled");
      ar_ready <= '0';
      p_send(0, f_addr(0, 300), f_min(3, GC_FIFO_DEPTH));
      p_wait_ar(0, f_addr(0, 300), f_min(3, GC_FIFO_DEPTH));

      p_start_test("reset while stalled: after reset");
      assert ar_valid = '0'
        report "FAIL: ar_valid not cleared by reset" severity failure;
      assert req_ready = (0 to GC_NUM_CLIENTS-1 => '1')
        report "FAIL: req_ready not high after reset" severity failure;
      p_send(0, f_addr(0, 301), 1);
      p_wait_ar(0, f_addr(0, 301), 1);
    end procedure;

    -- One r_pop returns GC_R_BEATS_PER_POP credits, as when an upsizer puts
    -- several client beats in one R beat. With zero credit, a single pop
    -- must be enough for a request of exactly that many beats.
    procedure test_pop_returns_ratio is
    begin
      p_start_test("one pop returns GC_R_BEATS_PER_POP credits");
      p_send(0, f_addr(0, 400), GC_FIFO_DEPTH);
      p_wait_ar(0, f_addr(0, 400), GC_FIFO_DEPTH);
      p_present(0, f_addr(0, 402), C_ONE_POP_BURST);
      p_expect_refused(0, 4, "request accepted with zero credit");
      p_pop(0);
      p_send(0, f_addr(0, 402), C_ONE_POP_BURST);
      p_wait_ar(0, f_addr(0, 402), C_ONE_POP_BURST);
    end procedure;

  begin
    ---------------------------------------------------------------------
    -- Main sequence
    ---------------------------------------------------------------------
    test_reset_state;
    test_first_request_line_rate;
    test_single_transaction;
    test_ar_stall;
    test_credit_limit;
    test_pop_during_handshake;
    if GC_NUM_CLIENTS >= 2 then
      test_refused_does_not_block;
    end if;
    test_single_client_stream;
    test_all_clients_line_rate;
    test_exhausted_client;
    test_reset_while_stalled;
    test_pop_returns_ratio;

    report "ALL AR-MUX CHECKS PASSED";
    sim_done <= true;
    wait;
  end process;

end architecture;
