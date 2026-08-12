-----------------------------------------------------------------------
--Filename         : axi_r_demux_tb.vhd
--Description      : Self-checking testbench for axi_r_demux:
--                 :  - Reset: all rsp_valid low, r_ready high, no r_pop.
--                 :  - Single-beat routing + unpacking + credit pulse.
--                 :  - Interleaved multi-client routing with per-ID order.
--                 :  - FIFO-FULL backpressure through the one-beat skid:
--                 :    fill a client FIFO to depth, verify r_ready
--                 :    deasserts, then drain and verify no beat is lost.
--                 :  - Payload/sideband stability while a client stalls.
--                 :  - Mid-stream reset while beats are in flight.
--                 :  - Back-to-back full-rate streaming across clients and
--                 :    a back-to-back r_pop credit pulse train.
--                 :  - Watchdog to catch deadlocks instead of hanging.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;  -- slv_array_t, slv2_array_t

entity axi_r_demux_tb is
  generic (
    GC_NUM_CLIENTS : positive := 4;
    GC_DATA_BYTES  : positive := 4;  -- 32-bit data
    GC_ID_WIDTH    : positive := 4;
    GC_FIFO_DEPTH  : positive := 8;  -- small FIFOs for fast simulation
    GC_CLK_PERIOD  : time := 4 ns    -- 250 MHz
  );
end entity;

architecture sim of axi_r_demux_tb is

  constant C_DATA_BITS : positive := 8 * GC_DATA_BYTES;

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';

  signal r_id    : std_logic_vector(GC_ID_WIDTH-1 downto 0) := (others => '0');
  signal r_data  : std_logic_vector(C_DATA_BITS-1 downto 0) := (others => '0');
  signal r_resp  : std_logic_vector(1 downto 0) := (others => '0');
  signal r_last  : std_logic := '0';
  signal r_valid : std_logic := '0';
  signal r_ready : std_logic;

  signal rsp_data  : slv_array_t(0 to GC_NUM_CLIENTS-1)(C_DATA_BITS-1 downto 0);
  signal rsp_resp  : slv2_array_t(0 to GC_NUM_CLIENTS-1);
  signal rsp_last  : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal rsp_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal rsp_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1) := (others => '0');
  signal r_pop : std_logic_vector(0 to GC_NUM_CLIENTS-1);

  signal sim_done : boolean := false;

  -- Distinctive word for client c, beat b (width-safe for 2^N data widths:
  -- client in the upper half, beat in the lower half, 4 bits each).
  function f_word(c : natural; b : natural) return std_logic_vector is
    constant C_HALF : positive := C_DATA_BITS / 2;
  begin
    return std_logic_vector(to_unsigned(c mod 16, C_HALF)) &
           std_logic_vector(to_unsigned(b mod 16, C_HALF));
  end function;

begin

  u_dut : entity work.axi_r_demux
    generic map (
      GC_NUM_CLIENTS => GC_NUM_CLIENTS,
      GC_DATA_BYTES  => GC_DATA_BYTES,
      GC_ID_WIDTH    => GC_ID_WIDTH,
      GC_FIFO_DEPTH  => GC_FIFO_DEPTH
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
      r_pop     => r_pop
    );

  -- Clock generator: hold the clock low before the first rising edge, then
  -- stop it once the stimulus process marks the simulation complete.
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
      report "FAIL: watchdog timeout (possible r_demux deadlock)" severity failure;
    end if;
    wait;
  end process;

  p_stim : process
    variable pop_cnt   : integer_vector(0 to GC_NUM_CLIENTS-1) := (others => 0);
    variable line_seen : integer_vector(0 to GC_NUM_CLIENTS-1) := (others => 0);
    variable beats_per_client : integer;
  begin
    ------------------------------------------------------------------
    -- Reset
    ------------------------------------------------------------------
    aresetn <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait until rising_edge(aclk);

    assert rsp_valid = (0 to GC_NUM_CLIENTS-1 => '0')
      report "FAIL: all rsp_valid should be '0' after reset" severity failure;
    assert r_ready = '1'
      report "FAIL: r_ready should be '1' after reset" severity failure;
    assert r_pop = (0 to GC_NUM_CLIENTS-1 => '0')
      report "FAIL: r_pop should be '0' after reset" severity failure;

    ------------------------------------------------------------------
    -- Test 1: single beat to client 0, pop + credit pulse
    ------------------------------------------------------------------
    r_id    <= std_logic_vector(to_unsigned(0, GC_ID_WIDTH));
    r_data  <= f_word(0, 1);
    r_last  <= '1';
    r_resp  <= "01";
    r_valid <= '1';
    while r_ready /= '1' loop
      wait until rising_edge(aclk);
    end loop;
    wait until rising_edge(aclk);  -- accept edge
    r_valid <= '0';

    -- FIFO latency is one cycle; pop after it appears.
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    assert rsp_valid(0) = '1'
      report "FAIL: client 0 rsp_valid not asserted" severity failure;
    assert rsp_data(0) = f_word(0, 1)
      report "FAIL: client 0 rsp_data mismatch" severity failure;
    assert rsp_last(0) = '1'
      report "FAIL: client 0 rsp_last mismatch" severity failure;
    assert rsp_resp(0) = "01"
      report "FAIL: client 0 rsp_resp mismatch" severity failure;

    -- Pop and check the registered credit pulse one cycle after the pop.
    rsp_ready(0) <= '1';
    wait until rising_edge(aclk);   -- pop edge
    rsp_ready(0) <= '0';
    wait until rising_edge(aclk);   -- r_pop(0) now reflects the pop
    assert r_pop(0) = '1'
      report "FAIL: r_pop(0) should pulse one cycle after pop" severity failure;
    wait until rising_edge(aclk);
    assert r_pop(0) = '0'
      report "FAIL: r_pop(0) should drop after one cycle" severity failure;
    assert rsp_valid(0) = '0'
      report "FAIL: client 0 FIFO should be empty after pop" severity failure;

    ------------------------------------------------------------------
    -- Test 2: interleaved multi-client routing with per-ID order
    ------------------------------------------------------------------
    -- Client 1: beats 1,2 (last on beat 2); Client 2: beat 1 (last).
    for i in 1 to 2 loop
      r_id    <= std_logic_vector(to_unsigned(1, GC_ID_WIDTH));
      r_data  <= f_word(1, i);
      r_last  <= '1' when i = 2 else '0';
      r_resp  <= "00";
      r_valid <= '1';
      while r_ready /= '1' loop
        wait until rising_edge(aclk);
      end loop;
      wait until rising_edge(aclk);
      r_valid <= '0';
    end loop;

    r_id    <= std_logic_vector(to_unsigned(2, GC_ID_WIDTH));
    r_data  <= f_word(2, 1);
    r_last  <= '1';
    r_resp  <= "10";
    r_valid <= '1';
    while r_ready /= '1' loop
      wait until rising_edge(aclk);
    end loop;
    wait until rising_edge(aclk);
    r_valid <= '0';

    wait until rising_edge(aclk);
    wait until rising_edge(aclk);

    -- Client 1 presents beat 1; Client 2 presents beat 1.
    assert rsp_valid(1) = '1' and rsp_data(1) = f_word(1, 1) and rsp_last(1) = '0'
      report "FAIL: client 1 beat 1 mismatch" severity failure;
    assert rsp_valid(2) = '1' and rsp_data(2) = f_word(2, 1) and rsp_last(2) = '1'
      report "FAIL: client 2 beat 1 mismatch" severity failure;
    assert rsp_resp(2) = "10"
      report "FAIL: client 2 rsp_resp mismatch" severity failure;

    -- Pop client 1 beat 1; client 1 should then present beat 2 (order).
    rsp_ready(1) <= '1';
    wait until rising_edge(aclk);
    rsp_ready(1) <= '0';
    wait until rising_edge(aclk);
    assert rsp_valid(1) = '1' and rsp_data(1) = f_word(1, 2) and rsp_last(1) = '1'
      report "FAIL: client 1 beat 2 mismatch (order lost)" severity failure;
    rsp_ready(1) <= '1';
    wait until rising_edge(aclk);
    rsp_ready(1) <= '0';

    -- Drain client 2.
    rsp_ready(2) <= '1';
    wait until rising_edge(aclk);
    rsp_ready(2) <= '0';

    ------------------------------------------------------------------
    -- Test 3: FIFO-full backpressure through the one-beat skid
    ------------------------------------------------------------------
    -- With a depth-GC_FIFO_DEPTH FIFO and a one-beat skid, client 3 can
    -- absorb GC_FIFO_DEPTH + 1 beats (FIFO + skid) before r_ready
    -- deasserts. No beat may be lost.
    rsp_ready(3) <= '0';
    r_last <= '0';
    r_resp <= "00";
    for b in 0 to GC_FIFO_DEPTH loop
      r_id    <= std_logic_vector(to_unsigned(3, GC_ID_WIDTH));
      r_data  <= f_word(3, b);
      r_valid <= '1';
      while r_ready /= '1' loop
        wait until rising_edge(aclk);
      end loop;
      wait until rising_edge(aclk);  -- accept edge
      r_valid <= '0';
    end loop;

    -- The skid is now full; r_ready must be deasserted (registered).
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    assert r_ready = '0'
      report "FAIL: r_ready should be '0' when FIFO + skid are full" severity failure;

    -- A further beat must NOT be accepted while r_ready is low.
    r_id    <= std_logic_vector(to_unsigned(3, GC_ID_WIDTH));
    r_data  <= f_word(3, 99);
    r_valid <= '1';
    wait until rising_edge(aclk);
    assert r_ready = '0'
      report "FAIL: upstream beat accepted while full" severity failure;
    r_valid <= '0';

    -- Drain client 3 beat-by-beat; all GC_FIFO_DEPTH + 1 beats arrive in
    -- order, including the one parked in the skid (no loss).
    for b in 0 to GC_FIFO_DEPTH loop
      -- Data must be present and correct before the pop.
      wait until rising_edge(aclk);
      assert rsp_valid(3) = '1'
        report "FAIL: client 3 no data for beat " & integer'image(b) severity failure;
      assert rsp_data(3) = f_word(3, b)
        report "FAIL: client 3 beat " & integer'image(b) & " mismatch" severity failure;
      -- Pop this beat; the credit pulse is visible the cycle after the pop.
      rsp_ready(3) <= '1';
      wait until rising_edge(aclk);   -- pop edge
      rsp_ready(3) <= '0';
      wait until rising_edge(aclk);   -- r_pop(3) now reflects the pop
      assert r_pop(3) = '1'
        report "FAIL: r_pop(3) missing on beat " & integer'image(b) severity failure;
    end loop;
    assert rsp_valid(3) = '0'
      report "FAIL: client 3 FIFO should be empty after drain" severity failure;

    ------------------------------------------------------------------
    -- Test 4: stability while a client is stalled
    ------------------------------------------------------------------
    r_id    <= std_logic_vector(to_unsigned(0, GC_ID_WIDTH));
    r_data  <= f_word(0, 7);
    r_last  <= '1';
    r_resp  <= "11";
    r_valid <= '1';
    while r_ready /= '1' loop
      wait until rising_edge(aclk);
    end loop;
    wait until rising_edge(aclk);
    r_valid <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);

    -- Hold rsp_ready low and verify the output stays stable.
    rsp_ready(0) <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
        assert rsp_valid(0) = '1' and rsp_data(0) = f_word(0, 7) and
          rsp_last(0) = '1' and rsp_resp(0) = "11"
      report "FAIL: client 0 output unstable while stalled" severity failure;
    rsp_ready(0) <= '1';
    wait until rising_edge(aclk);
    rsp_ready(0) <= '0';

    ------------------------------------------------------------------
    -- Test 5: back-to-back full-rate streaming + credit pulse train
    ------------------------------------------------------------------
    -- Alternate clients 0 and 1 back-to-back; each pop returns a pulse.
    for b in 0 to 3 loop
      r_id    <= std_logic_vector(to_unsigned(b mod 2, GC_ID_WIDTH));
      r_data  <= f_word(b mod 2, b + 10);
      r_last  <= '1';
      r_resp  <= "00";
      r_valid <= '1';
      while r_ready /= '1' loop
        wait until rising_edge(aclk);
      end loop;
      wait until rising_edge(aclk);
      r_valid <= '0';
    end loop;
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);

    -- Verify the first beats, then pop both clients back-to-back and check
    -- the credit pulse train (one pulse per pop, on both clients).
    assert rsp_valid(0) = '1' and rsp_data(0) = f_word(0, 10) and rsp_last(0) = '1'
      report "FAIL: client 0 back-to-back beat 10 mismatch" severity failure;
    assert rsp_valid(1) = '1' and rsp_data(1) = f_word(1, 11) and rsp_last(1) = '1'
      report "FAIL: client 1 back-to-back beat 11 mismatch" severity failure;
    rsp_ready(0) <= '1';
    rsp_ready(1) <= '1';
    wait until rising_edge(aclk);   -- pop beat 10 (c0) and beat 11 (c1)
    wait until rising_edge(aclk);   -- first credit pulse visible
    assert r_pop(0) = '1'
      report "FAIL: missing credit pulse on client 0 during back-to-back drain" severity failure;
    assert r_pop(1) = '1'
      report "FAIL: missing credit pulse on client 1 during back-to-back drain" severity failure;
    wait until rising_edge(aclk);   -- second (back-to-back) credit pulse visible
    assert r_pop(0) = '1'
      report "FAIL: missing second credit pulse on client 0" severity failure;
    assert r_pop(1) = '1'
      report "FAIL: missing second credit pulse on client 1" severity failure;
    rsp_ready(0) <= '0';
    rsp_ready(1) <= '0';
    assert rsp_valid(0) = '0' and rsp_valid(1) = '0'
      report "FAIL: clients 0/1 should be empty after back-to-back drain" severity failure;

    ------------------------------------------------------------------
    -- Test 6: input line rate - accept a beat every cycle (hard guard)
    ------------------------------------------------------------------
    -- All clients drain at full rate while the input streams 64 beats
    -- round-robin, one beat per cycle. r_ready must never deassert (the R
    -- channel must accept data on every beat at 250 MHz), and every
    -- accepted beat must be popped exactly once (no data loss).
    rsp_ready <= (others => '1');
    pop_cnt := (others => 0);
    line_seen := (others => 0);
    beats_per_client := 64 / GC_NUM_CLIENTS;
    assert 64 mod GC_NUM_CLIENTS = 0
      report "FAIL: line-rate burst length must be a multiple of GC_NUM_CLIENTS" severity failure;

    for b in 0 to 63 loop
      r_id    <= std_logic_vector(to_unsigned(b mod GC_NUM_CLIENTS, GC_ID_WIDTH));
      r_data  <= f_word(b mod GC_NUM_CLIENTS, b + 200);
      r_last  <= '1';
      r_resp  <= "00";
      r_valid <= '1';
      wait until rising_edge(aclk);
      assert r_ready = '1'
        report "FAIL: input r_ready dropped during full-rate burst (beat " &
               integer'image(b) & ")" severity failure;
      for i in 0 to GC_NUM_CLIENTS-1 loop
        if rsp_valid(i) = '1' then
          assert rsp_data(i) = f_word(i, 200 + i + line_seen(i) * GC_NUM_CLIENTS) and
                 rsp_resp(i) = "00" and rsp_last(i) = '1'
            report "FAIL: line-rate output payload/sideband mismatch" severity failure;
          line_seen(i) := line_seen(i) + 1;
        end if;
        if r_pop(i) = '1' then
          pop_cnt(i) := pop_cnt(i) + 1;
        end if;
      end loop;
    end loop;
    r_valid <= '0';

    -- Drain tail: let the last accepted beats reach their clients and pop.
    for k in 0 to GC_FIFO_DEPTH + 4 loop
      wait until rising_edge(aclk);
      for i in 0 to GC_NUM_CLIENTS-1 loop
        if rsp_valid(i) = '1' then
          assert rsp_data(i) = f_word(i, 200 + i + line_seen(i) * GC_NUM_CLIENTS) and
                 rsp_resp(i) = "00" and rsp_last(i) = '1'
            report "FAIL: line-rate tail payload/sideband mismatch" severity failure;
          line_seen(i) := line_seen(i) + 1;
        end if;
        if r_pop(i) = '1' then
          pop_cnt(i) := pop_cnt(i) + 1;
        end if;
      end loop;
    end loop;

    -- Every client must have popped exactly its share of the burst.
    for i in 0 to GC_NUM_CLIENTS-1 loop
      assert pop_cnt(i) = beats_per_client
        report "FAIL: client " & integer'image(i) & " popped " &
               integer'image(pop_cnt(i)) & " of " &
               integer'image(beats_per_client) & " beats (data lost)"
        severity failure;
    end loop;
    assert rsp_valid = (0 to GC_NUM_CLIENTS-1 => '0')
      report "FAIL: clients not empty after line-rate burst" severity failure;

    ------------------------------------------------------------------
    -- Test 7: mid-stream reset while beats are in flight
    ------------------------------------------------------------------
    r_id    <= std_logic_vector(to_unsigned(3, GC_ID_WIDTH));
    r_data  <= f_word(3, 77);
    r_valid <= '1';
    wait until rising_edge(aclk);
    aresetn <= '0';  -- reset with a beat pending
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    r_valid <= '0';
    wait until rising_edge(aclk);

    -- Everything must be clean after reset.
    assert rsp_valid = (0 to GC_NUM_CLIENTS-1 => '0')
      report "FAIL: rsp_valid not cleared after mid-stream reset" severity failure;
    assert r_ready = '1'
      report "FAIL: r_ready not restored after mid-stream reset" severity failure;

    report "ALL R-DEMUX CHECKS PASSED";
    sim_done <= true;
    wait;
  end process;

end architecture;
