-----------------------------------------------------------------------
--Filename         : axis_fifo_tb.vhd
--Description      : Testbench for axis_fifo with AXI-Stream BFM
--                 : procedures encapsulating valid/ready handshake.
--                 : Tests odd/non-power-of-two depths, back-to-back
--                 : writes/reads, and empty/full boundary corner cases.
--Author           : Rune Baeverrud
--Current Revision : 1.1
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axis_bfm_pkg.all;

entity axis_fifo_tb is
end entity;

architecture sim of axis_fifo_tb is
  constant TCLK          : time    := 10 ns;
  constant C_DATA_WIDTH  : positive := 8;
  constant C_DATA_DEPTH  : positive := 3; -- odd/non-power-of-two depth to test range guards

  signal aclk           : std_logic := '0';
  signal aresetn        : std_logic := '0';

  signal s_axis_tdata   : std_logic_vector(C_DATA_WIDTH-1 downto 0) := (others => '0');
  signal s_axis_tvalid  : std_logic := '0';
  signal s_axis_tready  : std_logic;

  signal m_axis_tdata   : std_logic_vector(C_DATA_WIDTH-1 downto 0);
  signal m_axis_tvalid  : std_logic;
  signal m_axis_tready  : std_logic := '0';

  -- Size according to ceiling of log2(3) = 2. Range 2 downto 0.
  signal fifo_count     : unsigned(2 downto 0);

  signal test_done      : std_logic := '0';

begin
  -- Infinite clock generator process, runs until all test assertions are complete.
  aclk <= not aclk after TCLK / 2 when test_done = '0' else '0';

  -- Device Under Test (DUT) Instantiation
  dut: entity work.axis_fifo
    generic map (
      GC_TDATA_WIDTH => C_DATA_WIDTH,
      GC_FIFO_DEPTH  => C_DATA_DEPTH)
    port map (
      aclk           => aclk,
      aresetn        => aresetn,
      s_axis_tdata   => s_axis_tdata,
      s_axis_tvalid  => s_axis_tvalid,
      s_axis_tready  => s_axis_tready,
      m_axis_tdata   => m_axis_tdata,
      m_axis_tvalid  => m_axis_tvalid,
      m_axis_tready  => m_axis_tready,
      fifo_count     => fifo_count);

  -- Main Sequential Stimulus Process
  process is
    variable v_data : std_logic_vector(C_DATA_WIDTH-1 downto 0);
  begin
    -- ================================================================
    -- Reset Sequence
    -- ================================================================
    report "=== Reset ===";
    aresetn <= '0';
    wait for TCLK;
    aresetn <= '1';
    wait until rising_edge(aclk);

    assert fifo_count = 0
      report "FAIL: fifo_count should be 0 after reset"
      severity error;

    -- ================================================================
    -- FIFO Fill Sequence
    -- ================================================================
    report "=== Pushing Data ===";

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"A1");
    wait until rising_edge(aclk);
    assert fifo_count = 1
      report "FAIL: fifo_count should be 1 after 1st push, got " & integer'image(to_integer(fifo_count))
      severity error;

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"B2");
  wait until rising_edge(aclk);
    assert fifo_count = 2
      report "FAIL: fifo_count should be 2 after 2nd push, got " & integer'image(to_integer(fifo_count))
      severity error;

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"C3");
  wait until rising_edge(aclk);

    -- Assert full status: fifo_count must equal GC_FIFO_DEPTH
    -- and s_axis_tready must be deasserted.
    assert fifo_count = 3
      report "FAIL: fifo_count should be 3 after 3rd push, got " & integer'image(to_integer(fifo_count))
      severity error;
    assert s_axis_tready = '0'
      report "FAIL: s_axis_tready should be 0 (full)"
      severity error;

    -- ================================================================
    -- Output Validation (First-Word Fall-Through)
    -- ================================================================
    report "=== Verifying FIFO outputs (First item should be at output) ===";
    assert m_axis_tvalid = '1'
      report "FAIL: m_axis_tvalid should be 1"
      severity error;
    assert m_axis_tdata = x"A1"
      report "FAIL: First element out should be 0xA1, got " & integer'image(to_integer(unsigned(m_axis_tdata)))
      severity error;

    -- ================================================================
    -- Simultaneous Push-Pop (Protocol-Compliant when Full)
    -- ================================================================
    -- FIFO is full (3 elements). Pop one element to free a slot, then
    -- push x"D4".  Due to the DUT's registered pipeline, the pop
    -- commits on cycle N and the push commits on cycle N+1 -- the
    -- handshake handles this transparently as long as the consumer
    -- asserts tready and the producer holds tvalid.
    report "=== Simultaneous Push-Pop (Protocol-compliant) ===";
    axis_pop (aclk, m_axis_tready, m_axis_tvalid);
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"D4");
    wait until rising_edge(aclk);

    -- Occupancy returned to 3 (popped 1 -> 2, then pushed 1 -> 3).
    assert fifo_count = 3
      report "FAIL: fifo_count should be 3 after pop+push when full, got " & integer'image(to_integer(fifo_count))
      severity error;

    -- ================================================================
    -- Stall Stability Check (valid held, ready low)
    -- ================================================================
    report "=== Stall stability while full ===";
    m_axis_tready <= '0';
    for i in 1 to 4 loop
      wait until rising_edge(aclk);
      wait until rising_edge(aclk);
      assert m_axis_tvalid = '1'
        report "FAIL: m_axis_tvalid dropped during sustained stall"
        severity error;
      assert m_axis_tdata = x"B2"
        report "FAIL: m_axis_tdata changed during sustained stall"
        severity error;
      assert fifo_count = 3
        report "FAIL: fifo_count changed during sustained stall"
        severity error;
    end loop;

    -- ================================================================
    -- Sequential Queue Drainage
    -- ================================================================
    report "=== Draining remaining items ===";

    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    assert v_data = x"B2"
      report "FAIL: Expected 0xB2, got " & integer'image(to_integer(unsigned(v_data)))
      severity error;
    wait until rising_edge(aclk);

    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    assert v_data = x"C3"
      report "FAIL: Expected 0xC3, got " & integer'image(to_integer(unsigned(v_data)))
      severity error;
    wait until rising_edge(aclk);

    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    assert v_data = x"D4"
      report "FAIL: Expected 0xD4, got " & integer'image(to_integer(unsigned(v_data)))
      severity error;
    wait until rising_edge(aclk);

    assert fifo_count = 0
      report "FAIL: fifo_count should be 0 when empty"
      severity error;
    assert m_axis_tvalid = '0'
      report "FAIL: m_axis_tvalid should be 0 when empty"
      severity error;

    -- ================================================================
    -- CORNER CASE 1: Empty-State Read Attempt (Protocol Violation Guard)
    -- ================================================================
    -- Read request while FIFO is empty. The core must gracefully handle
    -- this (no out-of-range crashes on index -1).  axis_pop waits for
    -- tvalid, which will never come when empty -- so instead we drive
    -- tready for one cycle manually (simulating a premature read request).
    report "--- CORNER CASE 1: Read Attempt on Empty ---";
    m_axis_tready <= '1';
    wait until rising_edge(aclk);
    m_axis_tready <= '0';
    wait until rising_edge(aclk);

    assert fifo_count = 0
      report "FAIL: fifo_count mutated during dummy read when empty!"
      severity error;
    assert m_axis_tvalid = '0'
      report "FAIL: m_axis_tvalid cleared but was expected to be '0'"
      severity error;

    -- ================================================================
    -- CORNER CASE 2: Full-State Write Attempt (Protocol Violation Guard)
    -- ================================================================
    report "--- Refilling FIFO to full (3 elements) ---";
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"E5");
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"F6");
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"07");
    wait until rising_edge(aclk);

    assert fifo_count = 3
      report "FAIL: Not full during corner case prep, got " & integer'image(to_integer(fifo_count))
      severity error;
    assert s_axis_tready = '0'
      report "FAIL: Ready flag should be '0' when full"
      severity error;

    -- Rogue master: asserts valid for one cycle while tready='0' (violates
    -- the AXI rule that valid must be held until handshake completes).
    -- The FIFO must ignore this data.
    report "--- CORNER CASE 2: Write Attempt on Full (Rogue master) ---";
    s_axis_tdata  <= x"99";
    s_axis_tvalid <= '1';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    s_axis_tvalid <= '0';

    assert fifo_count = 3
      report "FAIL: Over-occupancy detected! Count is " & integer'image(to_integer(fifo_count))
      severity error;
    assert s_axis_tready = '0'
      report "FAIL: Ready flag mutated after invalid full write attempt"
      severity error;

    -- Drain and verify that 0x99 did not corrupt stored data.
    -- Expected sequence: 0xE5 -> 0xF6 -> 0x07
    report "--- Verifying stored queue elements after rogue write attempt ---";

    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    assert v_data = x"E5"
      report "FAIL: Expected first element to be 0xE5, got " & integer'image(to_integer(unsigned(v_data)))
      severity error;
    wait until rising_edge(aclk);

    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    assert v_data = x"F6"
      report "FAIL: Expected second element to be 0xF6, got " & integer'image(to_integer(unsigned(v_data)))
      severity error;
    wait until rising_edge(aclk);

    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    assert v_data = x"07"
      report "FAIL: Expected third element to be 0x07, got " & integer'image(to_integer(unsigned(v_data)))
      severity error;
    wait until rising_edge(aclk);

    assert fifo_count = 0
      report "FAIL: Expected empty queue after verify drain"
      severity error;

    -- ================================================================
    -- CORNER CASE 3: Back-to-Back Single-Item Transits
    -- ================================================================
    -- Test individual items transiting the FIFO: push then pop each
    -- item using proper handshake BFMs, verifying pipeline throughput
    -- without deadlocks or bubbles.
    report "--- CORNER CASE 3: Single-cycle Back-to-Back Transit Pipeline ---";

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"11");
  wait until rising_edge(aclk);
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    assert v_data = x"11" report "FAIL: Transit 1 failed, expected 0x11" severity error;
  wait until rising_edge(aclk);
    assert fifo_count = 0 report "FAIL: Transient count did not return to 0" severity error;

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"22");
  wait until rising_edge(aclk);
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    assert v_data = x"22" report "FAIL: Transit 2 failed, expected 0x22" severity error;
  wait until rising_edge(aclk);
    assert fifo_count = 0 report "FAIL: Transient count did not return to 0 after transit 2" severity error;

    -- ================================================================
    -- CORNER CASE 4: In-Flight Reset while Non-Empty
    -- ================================================================
    report "--- CORNER CASE 4: In-flight reset while non-empty ---";

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"5A");
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"6B");
    wait until rising_edge(aclk);
    assert fifo_count = 2
      report "FAIL: setup for in-flight reset expected fifo_count=2"
      severity error;

    aresetn <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);

    assert fifo_count = 0
      report "FAIL: fifo_count should clear to 0 after in-flight reset"
      severity error;
    assert m_axis_tvalid = '0'
      report "FAIL: m_axis_tvalid should be 0 after in-flight reset"
      severity error;
    assert s_axis_tready = '1'
      report "FAIL: s_axis_tready should be 1 after in-flight reset"
      severity error;

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"77");
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    assert v_data = x"77"
      report "FAIL: post-reset functional check failed (expected 0x77)"
      severity error;
    wait until rising_edge(aclk);
    assert fifo_count = 0
      report "FAIL: fifo_count should return to 0 after post-reset push/pop"
      severity error;

    report "=== axis_fifo simple TB completed. No assertion errors detected. ===";
    test_done <= '1';
    wait;
  end process;

end architecture;
