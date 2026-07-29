-----------------------------------------------------------------------
--Filename         : axis_latency_gen_tb.vhd
--Description      : Testbench for axis_latency_gen.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity axis_latency_gen_tb is
end entity;

architecture sim of axis_latency_gen_tb is

  constant C_CLK_PERIOD : time := 10 ns;

  signal aclk           : std_logic := '0';
  signal aresetn        : std_logic := '0';

  signal s_axis_tdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal s_axis_tvalid  : std_logic := '0';
  signal s_axis_tready  : std_logic;

  signal m_axis_tdata   : std_logic_vector(31 downto 0);
  signal m_axis_tvalid  : std_logic;
  signal m_axis_tready  : std_logic := '1';

  signal base_delay : unsigned(31 downto 0) := to_unsigned(10, 32);

  -- fifo_count: log2ceil(GC_FIFO_DEPTH) + 1 = 5 bits for depth 16
  signal fifo_count     : unsigned(4 downto 0);

  signal wr_s_tdata     : std_logic_vector(31 downto 0) := (others => '0');
  signal wr_s_tvalid    : std_logic := '0';
  signal wr_s_tready    : std_logic;

  signal wr_m_tdata     : std_logic_vector(31 downto 0);
  signal wr_m_tvalid    : std_logic;
  signal wr_m_tready    : std_logic := '1';

  signal wr_base_delay  : unsigned(7 downto 0) := to_unsigned(10, 8);
  signal wr_fifo_count  : unsigned(4 downto 0);

  signal sim_done       : boolean := false;

  -- -----------------------------------------------------------------
  -- AXI4-Stream Write BFM
  -- -----------------------------------------------------------------
  procedure axis_write(
    signal   clk    : in  std_logic;
    signal   tdata  : out std_logic_vector;
    signal   tvalid : out std_logic;
    signal   tready : in  std_logic;
    constant data   : in  std_logic_vector
  ) is
  begin
    tdata  <= data;
    tvalid <= '1';
    loop
      wait until rising_edge(clk);
      exit when tready = '1';
    end loop;
    tvalid <= '0';
  end procedure;

  -- -----------------------------------------------------------------
  -- AXI4-Stream Read BFM
  -- -----------------------------------------------------------------
  procedure axis_read(
    signal   clk    : in  std_logic;
    signal   tready : out std_logic;
    signal   tvalid : in  std_logic;
    signal   tdata  : in  std_logic_vector;
    variable data   : out std_logic_vector
  ) is
  begin
    tready <= '1';
    loop
      wait until rising_edge(clk);
      exit when tvalid = '1';
    end loop;
    data := tdata;
    tready <= '0';
  end procedure;

  -- -----------------------------------------------------------------
  -- AXI4-Stream Pop BFM
  -- -----------------------------------------------------------------
  procedure axis_pop(
    signal   clk    : in  std_logic;
    signal   tready : out std_logic;
    signal   tvalid : in  std_logic
  ) is
  begin
    tready <= '1';
    loop
      wait until rising_edge(clk);
      exit when tvalid = '1';
    end loop;
    tready <= '0';
  end procedure;

begin

  aclk <= not aclk after C_CLK_PERIOD / 2 when not sim_done else '0';

  u_dut : entity work.axis_latency_gen
    generic map (
      GC_DATA_WIDTH  => 32,
      GC_FIFO_DEPTH  => 16,
      GC_TIMER_WIDTH => 32
    )
    port map (
      aclk           => aclk,
      aresetn        => aresetn,
      s_axis_tdata   => s_axis_tdata,
      s_axis_tvalid  => s_axis_tvalid,
      s_axis_tready  => s_axis_tready,
      m_axis_tdata   => m_axis_tdata,
      m_axis_tvalid  => m_axis_tvalid,
      m_axis_tready  => m_axis_tready,
      base_delay => base_delay,
      fifo_count     => fifo_count
    );

  u_wrap_dut : entity work.axis_latency_gen
    generic map (
      GC_DATA_WIDTH  => 32,
      GC_FIFO_DEPTH  => 16,
      GC_TIMER_WIDTH => 8
    )
    port map (
      aclk           => aclk,
      aresetn        => aresetn,
      s_axis_tdata   => wr_s_tdata,
      s_axis_tvalid  => wr_s_tvalid,
      s_axis_tready  => wr_s_tready,
      m_axis_tdata   => wr_m_tdata,
      m_axis_tvalid  => wr_m_tvalid,
      m_axis_tready  => wr_m_tready,
      base_delay => wr_base_delay,
      fifo_count     => wr_fifo_count
    );

  -- == Test sequence ==
  process
    variable l      : line;
    variable t_sent : time;
    variable t_rcvd : time;
    variable i         : natural;
    variable cnt_rx    : natural;
    variable v_rx_data : std_logic_vector(31 downto 0);
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
    -- Phase 1: Single transfer — verify delay >= base_delay
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
    -- Phase 3: Idle — verify no spurious output
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
    -- Phase 5: FIFO full — verify backpressure
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
    -- Done
    -- ============================================================
    write(l, string'("All tests passed.")); writeline(output, l);
    sim_done <= true;
    wait;
  end process;

end architecture;
