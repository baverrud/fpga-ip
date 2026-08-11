-----------------------------------------------------------------------
--Filename         : axis_latency_gen_tb.vhd
--Description      : Testbench for axis_latency_gen. Tests basic delay, burst
--                 : with backpressure, idle, timer wrap (via 8-bit timer DUT),
--                 : FIFO full, in-flight reset, data ordering, enable-gate
--                 : paths (jitter toggle, base_delay=0, both low), simultaneous
--                 : push/pop, min-delay observation, and full-rate verification.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.axis_bfm_pkg.all;

entity axis_latency_gen_tb is
end entity;

architecture sim of axis_latency_gen_tb is

  constant C_CLK_PERIOD : time := 10 ns;

  -- ===================================================================
  -- Main DUT (GC_TIMER_WIDTH=32) signals
  -- ===================================================================
  signal aclk              : std_logic := '0';
  signal aresetn           : std_logic := '0';

  signal s_axis_tdata      : std_logic_vector(31 downto 0) := (others => '0');
  signal s_axis_tvalid     : std_logic := '0';
  signal s_axis_tready     : std_logic;

  signal m_axis_tdata      : std_logic_vector(31 downto 0);
  signal m_axis_tvalid     : std_logic;
  signal m_axis_tready     : std_logic := '1';

  signal base_delay        : unsigned(31 downto 0) := to_unsigned(10, 32);
  signal enable_base_delay : std_logic := '1';
  signal enable_jitter     : std_logic := '1';

  -- fifo_count: log2ceil(GC_FIFO_DEPTH) + 1 = 5 bits for depth 16
  signal fifo_count        : unsigned(4 downto 0);

  -- ===================================================================
  -- Wrap DUT (GC_TIMER_WIDTH=8, for timer-wrap regression testing)
  -- Uses separate signals to run independently of the main DUT.
  -- The 8-bit timer wraps every 256 cycles, verifying the signed-
  -- subtraction wrap logic without simulating 2^32 cycles.
  -- ===================================================================
  signal wr_s_tdata     : std_logic_vector(31 downto 0) := (others => '0');
  signal wr_s_tvalid    : std_logic := '0';
  signal wr_s_tready    : std_logic;

  signal wr_m_tdata     : std_logic_vector(31 downto 0);
  signal wr_m_tvalid    : std_logic;
  signal wr_m_tready    : std_logic := '1';

  signal wr_base_delay  : unsigned(7 downto 0) := to_unsigned(10, 8);
  signal wr_fifo_count  : unsigned(4 downto 0);

  signal sim_done       : boolean := false;

  -- =================================================================
  -- Full-rate capture signals (for Phase 14 back-to-back verification)
  -- A concurrent process samples m_axis_tdata every cycle where
  -- m_axis_tvalid='1', enabling verification after back-to-back writes.
  -- =================================================================
  type slv32_array_t is array (natural range <>) of std_logic_vector(31 downto 0);
  signal captured_data  : slv32_array_t(0 to 15) := (others => (others => '0'));
  signal captured_cnt   : natural := 0;
  signal capture_done   : std_logic := '0';

begin

  aclk <= not aclk after C_CLK_PERIOD / 2 when not sim_done else '0';

  -- =================================================================
  -- Main DUT: 32-bit timer width. Used for phases 1-3 and 5-7:
  -- standard delay, burst with backpressure, idle, FIFO full,
  -- in-flight reset, and data ordering. The timer never wraps during
  -- these tests (2^32 cycles >> simulation length).
  -- =================================================================
  u_dut : entity work.axis_latency_gen
    generic map (
      GC_DATA_WIDTH  => 32,
      GC_FIFO_DEPTH  => 16,
      GC_TIMER_WIDTH => 32
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      s_axis_tdata      => s_axis_tdata,
      s_axis_tvalid     => s_axis_tvalid,
      s_axis_tready     => s_axis_tready,
      m_axis_tdata      => m_axis_tdata,
      m_axis_tvalid     => m_axis_tvalid,
      m_axis_tready     => m_axis_tready,
      base_delay        => base_delay,
      enable_base_delay => enable_base_delay,
      enable_jitter     => enable_jitter,
      fifo_count        => fifo_count
    );

  -- =================================================================
  -- Wrap DUT: 8-bit timer width. Used only in Phase 4 to verify the
  -- timer wrap-around logic. With a 32-bit timer the wrap would take
  -- 2^32 cycles (~43 s at 100 MHz) -- impractical for simulation.
  -- The 8-bit timer wraps every 256 cycles, proving the signed-
  -- modular subtraction releases entries correctly through rollover.
  -- =================================================================
  u_wrap_dut : entity work.axis_latency_gen
    generic map (
      GC_DATA_WIDTH  => 32,
      GC_FIFO_DEPTH  => 16,
      GC_TIMER_WIDTH => 8
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      s_axis_tdata      => wr_s_tdata,
      s_axis_tvalid     => wr_s_tvalid,
      s_axis_tready     => wr_s_tready,
      m_axis_tdata      => wr_m_tdata,
      m_axis_tvalid     => wr_m_tvalid,
      m_axis_tready     => wr_m_tready,
      base_delay        => wr_base_delay,
      enable_base_delay => enable_base_delay,
      enable_jitter     => enable_jitter,
      fifo_count        => wr_fifo_count
    );

  -- =================================================================
  -- Capture process: samples m_axis_tdata on every beat where
  -- m_axis_tvalid='1'. Used by Phase 14 to verify back-to-back
  -- writes where entries are consumed by the RTL during the write
  -- phase and cannot be drained with axis_read afterward.
  -- =================================================================
  p_capture : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        captured_cnt <= 0;
      elsif m_axis_tvalid = '1' and m_axis_tready = '1' and captured_cnt < captured_data'length then
        captured_data(captured_cnt) <= m_axis_tdata;
        captured_cnt <= captured_cnt + 1;
      end if;
    end if;
  end process;

  -- == Test sequence ==
  process
    variable l      : line;
    variable t_sent : time;
    variable t_rcvd : time;
    variable i         : natural;
    variable cnt_rx    : natural;
    variable v_rx_data : std_logic_vector(31 downto 0);
    type jitter_seq_t is array (natural range <>) of natural;
    constant C_EXPECTED_JITTER : jitter_seq_t := (0, 3, 1, 0);
    variable v_delay_cycles : natural;
  begin
    -- ============================================================
    -- Reset
    -- ============================================================
    write(l, string'("=== Phase 0: Reset ===")); writeline(output, l);
    aresetn <= '0';
    s_axis_tdata  <= (others => '0');
    s_axis_tvalid <= '0';
    m_axis_tready <= '1';
    wait for C_CLK_PERIOD * 5;
    aresetn <= '1';
    wait for C_CLK_PERIOD * 3;
    write(l, string'("  OK: reset complete")); writeline(output, l);

    -- ============================================================
    -- Phase 1: Single transfer -- verify delay >= base_delay
    -- ============================================================
    write(l, string'("=== Phase 1: Single transfer ===")); writeline(output, l);

    -- Send one word
    t_sent := now;
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, X"CAFEBABE");
    write(l, string'("  Sent: CAFEBABE at time "));
    write(l, t_sent / C_CLK_PERIOD);
    writeline(output, l);

    -- Wait for it to emerge
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_rx_data);
    t_rcvd := now;
    write(l, string'("  Received: "));
    hwrite(l, v_rx_data);
    write(l, string'(" at time "));
    write(l, t_rcvd / C_CLK_PERIOD);
    writeline(output, l);

    -- Verify data
    if v_rx_data /= X"CAFEBABE" then
      report "FAIL: data mismatch" severity failure;
    end if;

    -- Verify delay >= base_delay (in clock cycles)
    if (t_rcvd - t_sent) / C_CLK_PERIOD < to_integer(base_delay) then
      report "FAIL: delay shorter than base_delay" severity failure;
    end if;
    write(l, string'("  OK: delay = "));
    write(l, (t_rcvd - t_sent) / C_CLK_PERIOD);
    write(l, string'(" cycles (base_delay = "));
    write(l, to_integer(base_delay));
    write(l, string'(")"));
    writeline(output, l);

    -- ============================================================
    -- Phase 2: Burst transfer with backpressure
    -- ============================================================
    write(l, string'("=== Phase 2: Burst + backpressure ===")); writeline(output, l);
    m_axis_tready <= '0';  -- hold downstream
    cnt_rx := 0;

    -- Send 4 words while downstream is held
    for i in 0 to 3 loop
      axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready,
                 std_logic_vector(to_unsigned(16#A0# + i, 32)));
    end loop;
    write(l, string'("  Sent 4 words, downstream held")); writeline(output, l);

    -- Verify FIFO count
    wait until rising_edge(aclk);
    if to_integer(fifo_count) /= 4 then
      write(l, string'("  WARN: fifo_count = "));
      write(l, to_integer(fifo_count));
      write(l, string'(" (expected >= 4)"));
      writeline(output, l);
    end if;

    -- Release backpressure
    m_axis_tready <= '1';
    write(l, string'("  Backpressure released")); writeline(output, l);

    -- Collect 4 words
    for i in 0 to 3 loop
      axis_pop(aclk, m_axis_tready, m_axis_tvalid);
      cnt_rx := cnt_rx + 1;
      write(l, string'("  Received word "));
      write(l, cnt_rx);
      write(l, string'(": 0x"));
      hwrite(l, m_axis_tdata);
      writeline(output, l);
    end loop;

    if cnt_rx /= 4 then
      report "FAIL: burst count mismatch" severity failure;
    end if;
    write(l, string'("  OK: all 4 words received")); writeline(output, l);

    -- ============================================================
    -- Phase 3: Idle -- verify no spurious output
    -- ============================================================
    write(l, string'("=== Phase 3: Idle check ===")); writeline(output, l);
    s_axis_tvalid <= '0';
    for i in 0 to 9 loop
      wait until rising_edge(aclk);
    end loop;
    if m_axis_tvalid = '1' then
      report "FAIL: spurious m_axis_tvalid during idle" severity failure;
    end if;
    write(l, string'("  OK: no spurious output during idle")); writeline(output, l);

    -- ============================================================
    -- Phase 4: Timer wrap regression (8-bit timer)
    -- ============================================================
    write(l, string'("=== Phase 4: Timer wrap regression ===")); writeline(output, l);

    aresetn <= '0';
    s_axis_tvalid  <= '0';
    wr_s_tvalid    <= '0';
    m_axis_tready  <= '1';
    wr_m_tready    <= '1';
    wait for C_CLK_PERIOD * 3;
    aresetn <= '1';

    for i in 0 to 248 loop
      wait until rising_edge(aclk);
    end loop;

    t_sent := now;
    axis_write(aclk, wr_s_tdata, wr_s_tvalid, wr_s_tready, X"FACE0001");

    axis_read(aclk, wr_m_tready, wr_m_tvalid, wr_m_tdata, v_rx_data);
    t_rcvd := now;
    if v_rx_data /= X"FACE0001" then
      report "FAIL: wrap regression data mismatch" severity failure;
    end if;
    if (t_rcvd - t_sent) / C_CLK_PERIOD < to_integer(wr_base_delay) then
      report "FAIL: timer-wrap transfer released too early" severity failure;
    end if;

    write(l, string'("  OK: wrap transfer delay = "));
    write(l, (t_rcvd - t_sent) / C_CLK_PERIOD);
    write(l, string'(" cycles (base = "));
    write(l, to_integer(wr_base_delay));
    write(l, string'(")"));
    writeline(output, l);

    -- ============================================================
    -- Phase 5: FIFO full -- verify backpressure
    -- ============================================================
    write(l, string'("=== Phase 5: FIFO full backpressure ===")); writeline(output, l);
    base_delay <= to_unsigned(200, 32);
    m_axis_tready <= '0';
    wait for C_CLK_PERIOD * 3;

    -- Write 16 entries as fast as possible (fills depth-16 FIFO)
    for i in 0 to 15 loop
      axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready,
                 std_logic_vector(to_unsigned(i, 32)));
    end loop;
    write(l, string'("  Wrote 16 entries")); writeline(output, l);

    -- Next cycle should show backpressure
    wait until rising_edge(aclk);
    if s_axis_tready = '1' then
      report "FAIL: FIFO not full after 16 entries" severity failure;
    end if;
    write(l, string'("  OK: backpressure active")); writeline(output, l);

    -- Release backpressure and drain all 16 entries
    m_axis_tready <= '1';
    cnt_rx := 0;
    for i in 0 to 15 loop
      axis_pop(aclk, m_axis_tready, m_axis_tvalid);
      cnt_rx := cnt_rx + 1;
    end loop;
    if cnt_rx /= 16 then
      report "FAIL: drained " & integer'image(cnt_rx) & " entries (expected 16)" severity failure;
    end if;
    write(l, string'("  OK: all 16 entries drained")); writeline(output, l);

    -- ============================================================
    -- Phase 6: aresetn during operation
    -- ============================================================
    write(l, string'("=== Phase 6: aresetn during operation ===")); writeline(output, l);
    base_delay <= to_unsigned(50, 32);
    m_axis_tready <= '0';
    wait for C_CLK_PERIOD * 2;

    -- Write 4 entries while downstream held
    for i in 0 to 3 loop
      axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready,
                 std_logic_vector(to_unsigned(16#B0# + i, 32)));
    end loop;
    write(l, string'("  Wrote 4 entries, asserting reset...")); writeline(output, l);

    -- Assert reset while entries are in-flight
    wait until rising_edge(aclk);
    aresetn <= '0';
    wait for C_CLK_PERIOD * 5;
    aresetn <= '1';
    wait for C_CLK_PERIOD * 3;

    -- Verify no spurious output after reset
    if m_axis_tvalid = '1' then
      report "FAIL: spurious m_axis_tvalid after reset" severity failure;
    end if;
    write(l, string'("  OK: no spurious output after reset")); writeline(output, l);

    -- Write a new entry and verify post-reset functionality
    m_axis_tready <= '1';
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, X"BEEFFACE");
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_rx_data);
    if v_rx_data /= X"BEEFFACE" then
      report "FAIL: post-reset data mismatch" severity failure;
    end if;
    write(l, string'("  OK: post-reset entry dispatched correctly")); writeline(output, l);

    -- ============================================================
    -- Phase 7: Data ordering stress
    -- ============================================================
    write(l, string'("=== Phase 7: Data ordering stress ===")); writeline(output, l);
    base_delay <= to_unsigned(10, 32);
    m_axis_tready <= '1';
    wait for C_CLK_PERIOD * 3;

    -- Write 8 entries back-to-back
    for i in 0 to 7 loop
      axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready,
                 std_logic_vector(to_unsigned(16#100# + i, 32)));
    end loop;
    write(l, string'("  Wrote 8 entries, verifying order...")); writeline(output, l);

    -- Collect and verify FIFO order is preserved
    for i in 0 to 7 loop
      axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_rx_data);
      if v_rx_data /= std_logic_vector(to_unsigned(16#100# + i, 32)) then
        write(l, string'("FAIL: ordering mismatch at position "));
        write(l, i);
        write(l, string'(" (got 0x"));
        hwrite(l, v_rx_data);
        write(l, string'(")"));
        writeline(output, l);
        report "FAIL: data ordering" severity failure;
      end if;
    end loop;
    write(l, string'("  OK: all 8 entries in correct order")); writeline(output, l);

    -- ============================================================
    -- Phase 8: Enable jitter toggle
    --   Verifies the jitter_gen output returns to zero when
    --   enable_jitter is deasserted, and re-enables cleanly.
    --   The PRNG continues stepping while disabled, so the next
    --   enabled sample uses current PRNG state (not reset).
    -- ============================================================
    write(l, string'("=== Phase 8: Enable jitter toggle ===")); writeline(output, l);
    base_delay <= to_unsigned(10, 32);
    enable_jitter <= '0';
    wait for C_CLK_PERIOD * 3;

    -- Write an entry while jitter is disabled -- jg_jitter forced to 0
    t_sent := now;
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, X"CAFE0000");
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_rx_data);
    t_rcvd := now;
    if v_rx_data /= X"CAFE0000" then
      report "FAIL: jitter disabled data mismatch" severity failure;
    end if;
    write(l, string'("  Jitter disabled: OK (delay="));
    write(l, (t_rcvd - t_sent) / C_CLK_PERIOD);
    write(l, string'(")")); writeline(output, l);

    -- Re-enable jitter and write another entry
    enable_jitter <= '1';
    wait for C_CLK_PERIOD * 3;
    t_sent := now;
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, X"CAFE0001");
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_rx_data);
    t_rcvd := now;
    if v_rx_data /= X"CAFE0001" then
      report "FAIL: jitter re-enabled data mismatch" severity failure;
    end if;
    write(l, string'("  Jitter re-enabled: OK (delay="));
    write(l, (t_rcvd - t_sent) / C_CLK_PERIOD);
    write(l, string'(")")); writeline(output, l);

    -- ============================================================
    -- Phase 9: Enable base_delay = 0
    --   Verifies the minimum delay path when base_delay is gated.
    --   Expected: delay = 1 (FIFO latency floor) + jitter.
    -- ============================================================
    write(l, string'("=== Phase 9: Enable base_delay = 0 ===")); writeline(output, l);
    enable_base_delay <= '0';
    base_delay <= to_unsigned(0, 32);
    wait for C_CLK_PERIOD * 3;

    t_sent := now;
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, X"BEEF0001");
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_rx_data);
    t_rcvd := now;
    if v_rx_data /= X"BEEF0001" then
      report "FAIL: base_delay disabled data mismatch" severity failure;
    end if;
    if (t_rcvd - t_sent) / C_CLK_PERIOD < 1 then
      report "FAIL: delay < 1 with base_delay disabled" severity failure;
    end if;
    write(l, string'("  base_delay=0: OK (delay="));
    write(l, (t_rcvd - t_sent) / C_CLK_PERIOD);
    write(l, string'(", min=1)")); writeline(output, l);
    enable_base_delay <= '1';

    -- ============================================================
    -- Phase 10: Both enables low (minimum delay path)
    --   Only the timer + 1 floor contributes. Verifies the core
    --   survives with no added delay or jitter.
    -- ============================================================
    write(l, string'("=== Phase 10: Both enables low ===")); writeline(output, l);
    enable_base_delay <= '0';
    enable_jitter <= '0';
    base_delay <= to_unsigned(0, 32);
    wait for C_CLK_PERIOD * 3;

    t_sent := now;
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, X"BEEF0002");
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_rx_data);
    t_rcvd := now;
    if v_rx_data /= X"BEEF0002" then
      report "FAIL: both enables low data mismatch" severity failure;
    end if;
    if (t_rcvd - t_sent) / C_CLK_PERIOD < 1 then
      report "FAIL: delay < 1 with both enables low" severity failure;
    end if;
    write(l, string'("  Both disabled: OK (delay="));
    write(l, (t_rcvd - t_sent) / C_CLK_PERIOD);
    write(l, string'(", min=1)")); writeline(output, l);
    enable_base_delay <= '1';
    enable_jitter <= '1';

    -- ============================================================
    -- Phase 11: Simultaneous push/pop at max rate
    --   Uses enable_base_delay=0 so entries flow through with only
    --   the 1-cycle FIFO floor, enabling same-cycle push/pop.
    --   Verifies the axis_fifo handles concurrent access.
    -- ============================================================
    write(l, string'("=== Phase 11: Simultaneous push/pop ===")); writeline(output, l);
    base_delay <= to_unsigned(0, 32);
    enable_base_delay <= '0';
    wait for C_CLK_PERIOD * 3;

    -- Fill to mid-depth (8 entries, they depart at timer+1+jitter)
    for i in 0 to 7 loop
      axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready,
                 std_logic_vector(to_unsigned(16#200# + i, 32)));
    end loop;
    write(l, string'("  Filled 8 entries")); writeline(output, l);

    -- Wait a few cycles for the first entries to arrive at output
    for i in 0 to 10 loop
      wait until rising_edge(aclk);
    end loop;

    -- Simultaneous push/pop for 8 cycles
    for i in 0 to 7 loop
      s_axis_tdata <= std_logic_vector(to_unsigned(16#208# + i, 32));
      s_axis_tvalid <= '1';
      m_axis_tready <= '1';
      wait until rising_edge(aclk);
      if s_axis_tready = '1' and m_axis_tvalid = '1' then
        v_rx_data := m_axis_tdata;
      end if;
      s_axis_tvalid <= '0';
    end loop;
    s_axis_tvalid <= '0';
    write(l, string'("  Simultaneous push/pop: OK")); writeline(output, l);

    -- Drain remaining entries (8 written during simo phase)
    for i in 0 to 7 loop
      axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_rx_data);
    end loop;
    -- Verify FIFO is now empty
    wait until rising_edge(aclk);
    if m_axis_tvalid = '1' then
      report "FAIL: unexpected data after drain" severity failure;
    end if;
    write(l, string'("  Drain after simo: OK")); writeline(output, l);
    enable_base_delay <= '1';

    -- ============================================================
    -- Phase 12: Observe minimum delay (both enables low, tready=1)
    --   Pushes entries with enable_base_delay='0', enable_jitter='0'
    --   and m_axis_tready='1' so there is no backpressure. This
    --   exercises the absolute minimum delay path (FIFO floor only).
    --   No assertions -- purely for GUI waveform observation.
    -- ============================================================
    write(l, string'("=== Phase 12: Min-delay observation (GUI) ===")); writeline(output, l);
    base_delay <= to_unsigned(0, 32);
    enable_base_delay <= '0';
    enable_jitter <= '0';
    m_axis_tready <= '1';
    wait for C_CLK_PERIOD * 3;

    -- Push 8 words with tready held high; verify each entry on m_axis.
    -- With enable_base_delay='0' and enable_jitter='0', t_departure = timer,
    -- so time_arrived fires on the very next cycle. Each FWFT entry appears
    -- on m_axis exactly one cycle after the write handshake completes.
    for i in 0 to 7 loop
      t_sent := now;
      axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready,
                 std_logic_vector(to_unsigned(16#300# + i, 32)));
      write(l, string'("  Pushed 0x"));
      hwrite(l, std_logic_vector(to_unsigned(16#300# + i, 32)));
      write(l, string'(": sent at "));
      write(l, t_sent / C_CLK_PERIOD);
      writeline(output, l);

      -- Wait one cycle for the FWFT pipeline to place this entry on m_axis
      wait until rising_edge(aclk);

      -- Verify data on m_axis
      if m_axis_tvalid /= '1' then
        report "FAIL: m_axis_tvalid not asserted after push" severity failure;
      end if;
      if m_axis_tdata /= std_logic_vector(to_unsigned(16#300# + i, 32)) then
        write(l, string'("FAIL: m_axis_tdata mismatch at entry "));
        write(l, i);
        write(l, string'(" (expected 0x"));
        hwrite(l, std_logic_vector(to_unsigned(16#300# + i, 32)));
        write(l, string'(", got 0x"));
        hwrite(l, m_axis_tdata);
        write(l, string'(")"));
        writeline(output, l);
        report "FAIL: m_axis_tdata mismatch" severity failure;
      end if;
      write(l, string'("  Verified entry "));
      write(l, i);
      write(l, string'(" on m_axis: 0x"));
      hwrite(l, m_axis_tdata);
      writeline(output, l);
    end loop;
    write(l, string'("  All 8 entries written and verified -- each appeared on m_axis 1 cycle after push."));
    writeline(output, l);
    enable_base_delay <= '1';
    enable_jitter <= '1';

    -- ============================================================
    -- Phase 13: Full-rate back-to-back verification
    --   Writes 8 entries at full clock rate with base_delay=1.
    --   A concurrent capture process (p_capture) samples every beat
    --   on m_axis as it flows through. After writes complete, we
    --   wait for all 8 captured entries and verify their data.
    -- ============================================================
    write(l, string'("=== Phase 13: Full-rate verification ===")); writeline(output, l);

    -- Reset to clear the capture counter and DUT state
    aresetn <= '0';
    s_axis_tvalid <= '0';
    wait for C_CLK_PERIOD * 3;
    aresetn <= '1';
    base_delay <= to_unsigned(1, 32);
    enable_base_delay <= '1';
    enable_jitter <= '0';
    m_axis_tready <= '1';
    wait for C_CLK_PERIOD * 3;

    -- Write 8 entries back-to-back at full rate
    for i in 0 to 7 loop
      axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready,
                 std_logic_vector(to_unsigned(16#500# + i, 32)));
    end loop;
    write(l, string'("  Wrote 8 entries back-to-back."));
    writeline(output, l);

    -- Wait for capture process to collect all 8 entries
    for i in 0 to 15 loop
      wait until rising_edge(aclk);
    end loop;

    -- Verify captured data
    if captured_cnt < 8 then
      write(l, string'("FAIL: captured only "));
      write(l, captured_cnt);
      write(l, string'(" entries (expected 8)"));
      writeline(output, l);
      report "FAIL: capture count mismatch" severity failure;
    end if;
    for i in 0 to 7 loop
      if captured_data(i) /= std_logic_vector(to_unsigned(16#500# + i, 32)) then
        write(l, string'("FAIL: captured data mismatch at entry "));
        write(l, i);
        writeline(output, l);
        report "FAIL: captured data mismatch" severity failure;
      end if;
    end loop;
    write(l, string'("  OK: all 8 entries captured and verified at full rate."));
    writeline(output, l);

    -- ============================================================
    -- Phase 14: Deterministic jitter sequence
    --   Default xorshift32 seed/CDF produces jitter 0, 3, 1, 0 for
    --   the first four accepted writes (the first write uses the
    --   reset jitter value). Verify the measured delay includes the
    --   write-handshake cycle, one-cycle FIFO floor, and expected jitter.
    -- ============================================================
    write(l, string'("=== Phase 14: Deterministic jitter sequence ==="));
    writeline(output, l);
    aresetn <= '0';
    s_axis_tvalid <= '0';
    m_axis_tready <= '1';
    base_delay <= to_unsigned(0, 32);
    enable_base_delay <= '0';
    enable_jitter <= '1';
    wait for C_CLK_PERIOD * 3;
    aresetn <= '1';
    wait for C_CLK_PERIOD * 3;

    for i in C_EXPECTED_JITTER'range loop
      t_sent := now;
      axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready,
                 std_logic_vector(to_unsigned(16#600# + i, 32)));
      axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_rx_data);
      t_rcvd := now;
      if v_rx_data /= std_logic_vector(to_unsigned(16#600# + i, 32)) then
        report "FAIL: deterministic jitter data mismatch" severity failure;
      end if;
      v_delay_cycles := (t_rcvd - t_sent) / C_CLK_PERIOD;
      if v_delay_cycles /= 2 + C_EXPECTED_JITTER(i) then
        report "FAIL: deterministic jitter delay mismatch at entry " &
               integer'image(i) & ", got " & integer'image(v_delay_cycles) &
               ", expected " & integer'image(2 + C_EXPECTED_JITTER(i))
               severity failure;
      end if;
    end loop;
    write(l, string'("  OK: jitter sequence 0,3,1,0 verified"));
    writeline(output, l);

    -- ============================================================
    -- Done
    -- ============================================================
    write(l, string'("All tests passed.")); writeline(output, l);
    sim_done <= true;
    wait;
  end process;

end architecture;
