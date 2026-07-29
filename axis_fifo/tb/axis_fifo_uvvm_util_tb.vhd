---------------------------------------------------------------------------------------------------
-- Filename         : axis_fifo_uvvm_util_tb.vhd
-- Description      : Direct DUT testbench for axis_fifo using uvvm_util only.
--                    No harness, no VVC framework, no abstract command layer.
--                    The entity intentionally stays named axis_fifo_tb so the
--                    generic run scripts can reuse the standard work.axis_fifo_tb
--                    top name without any launcher changes.
--                    Includes proper AXI4-Stream handshake BFM procedures
--                    encapsulating the valid/ready protocol, ensuring tests
--                    behave correctly regardless of pipeline depth or timing.
-- Author           : Rune Bæverrud
-- Current Revision : 1.1
-- Licensing        : Zero-Clause BSD (0BSD)
---------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.util_pkg.all;
use work.axis_fifo_tb_bfm_pkg.all;

library uvvm_util;
use uvvm_util.types_pkg.all;
use uvvm_util.methods_pkg.all;

entity axis_fifo_tb is
end entity;

architecture sim of axis_fifo_tb is
  constant TCLK         : time     := 10 ns;
  constant C_WIDTH      : positive := 8;
  constant C_DEPTH      : positive := 3; -- odd/non-power-of-two depth to test range guards

  signal aclk           : std_logic := '0';
  signal aresetn        : std_logic := '0';

  signal s_axis_tdata   : std_logic_vector(C_WIDTH-1 downto 0) := (others => '0');
  signal s_axis_tvalid  : std_logic := '0';
  signal s_axis_tready  : std_logic;

  signal m_axis_tdata   : std_logic_vector(C_WIDTH-1 downto 0);
  signal m_axis_tvalid  : std_logic;
  signal m_axis_tready  : std_logic := '0';

  signal fifo_count     : unsigned(log2ceil(C_DEPTH) downto 0);
  signal test_done      : std_logic := '0';

  -- -----------------------------------------------------------------
  -- check_after_cycle:
  -- Wait for one rising clock edge, let combinatorial signals settle,
  -- then check fifo_count via UVVM's check_value.
  -- NOTE: fifo_count is passed as a SIGNAL, not as constant integer,
  -- so the expression is evaluated AFTER the wait, not at the call site.
  -- -----------------------------------------------------------------
  procedure check_count_after_cycle(
    signal   clk        : in  std_logic;
    signal   fifo_count : in  unsigned;
    constant expect     : in  integer;
    constant msg        : in  string
  ) is
  begin
    wait until rising_edge(clk);
    wait for 0 ns;
    check_value(to_integer(fifo_count), expect, ERROR, msg);
  end procedure;

begin
  -- Infinite clock generator, runs until all test assertions are complete.
  aclk <= not aclk after TCLK / 2 when test_done = '0' else '0';

  -- Device Under Test (DUT) Instantiation
  dut: entity work.axis_fifo
    generic map (
      GC_TDATA_WIDTH => C_WIDTH,
      GC_FIFO_DEPTH  => C_DEPTH)
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
  process
    variable v_data : std_logic_vector(C_WIDTH-1 downto 0);
  begin
    report "START UVVM_UTIL-ONLY AXIS FIFO TEST";
    set_alert_stop_limit(ERROR, 1);

    -- ================================================================
    -- Reset Sequence
    -- ================================================================
    report "=== Reset ===";
    aresetn <= '0';
    wait for TCLK;
    aresetn <= '1';
    wait until rising_edge(aclk);
    wait for 0 ns;

    check_value(to_integer(fifo_count), 0, ERROR, "fifo_count should be 0 after reset");
    check_value(m_axis_tvalid, '0', ERROR, "m_axis_tvalid should be 0 after reset");

    -- ================================================================
    -- FIFO Fill Sequence
    -- ================================================================
    report "=== Pushing Data ===";

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"A1");
    check_count_after_cycle(aclk, fifo_count, 1, "fifo_count should be 1 after 1st push");

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"B2");
    check_count_after_cycle(aclk, fifo_count, 2, "fifo_count should be 2 after 2nd push");

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"C3");
    wait until rising_edge(aclk);
    wait for 0 ns;

    check_value(to_integer(fifo_count), C_DEPTH, ERROR, "fifo_count should equal C_DEPTH after 3rd push");
    check_value(s_axis_tready, '0', ERROR, "s_axis_tready should deassert when FIFO is full");

    -- ================================================================
    -- Output Validation (First-Word Fall-Through)
    -- ================================================================
    report "=== Verifying FIFO outputs (FWFT) ===";
    check_value(m_axis_tvalid, '1', ERROR, "m_axis_tvalid should be 1");
    check_value(m_axis_tdata, x"A1", ERROR, "first element out should be 0xA1");

    -- ================================================================
    -- Simultaneous Push-Pop (Protocol-Compliant when Full)
    -- ================================================================
    -- FIFO is full (3 elements). Pop one element to free a slot, then
    -- push x"D4". The handshake handles pipeline latency transparently.
    report "=== Simultaneous Push-Pop (Protocol-compliant) ===";
    axis_pop (aclk, m_axis_tready, m_axis_tvalid);
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"D4");
    wait until rising_edge(aclk);
    wait for 0 ns;

    -- Occupancy returned to 3 (popped 1 -> 2, then pushed 1 -> 3).
    check_value(to_integer(fifo_count), C_DEPTH, ERROR, "fifo_count should be 3 after pop+push when full");

    -- ================================================================
    -- Stall Stability Check (valid held, ready low)
    -- ================================================================
    report "=== Stall stability while full ===";
    m_axis_tready <= '0';
    for i in 1 to 4 loop
      wait until rising_edge(aclk);
      wait for 0 ns;
      check_value(m_axis_tvalid, '1', ERROR, "m_axis_tvalid dropped during sustained stall");
      check_value(m_axis_tdata, x"B2", ERROR, "m_axis_tdata changed during sustained stall");
      check_value(to_integer(fifo_count), C_DEPTH, ERROR, "fifo_count changed during sustained stall");
    end loop;

    -- ================================================================
    -- Sequential Queue Drainage
    -- ================================================================
    report "=== Draining remaining items ===";

    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    check_value(v_data, x"B2", ERROR, "Expected 0xB2");
    check_count_after_cycle(aclk, fifo_count, 2, "fifo_count should be 2 after first drain");

    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    check_value(v_data, x"C3", ERROR, "Expected 0xC3");
    check_count_after_cycle(aclk, fifo_count, 1, "fifo_count should be 1 after second drain");

    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    check_value(v_data, x"D4", ERROR, "Expected 0xD4");
    check_count_after_cycle(aclk, fifo_count, 0, "fifo_count should be 0 after third drain");

    check_value(m_axis_tvalid, '0', ERROR, "m_axis_tvalid should deassert when empty");

    -- ================================================================
    -- CORNER CASE 1: Empty-State Read Attempt (Protocol Violation Guard)
    -- ================================================================
    -- Drive tready for one cycle while FIFO is empty to verify the DUT
    -- handles this gracefully (no out-of-range crash on index -1).
    report "--- CORNER CASE 1: Read Attempt on Empty ---";
    m_axis_tready <= '1';
    wait until rising_edge(aclk);
    wait for 0 ns;
    m_axis_tready <= '0';

    check_value(to_integer(fifo_count), 0, ERROR, "fifo_count mutated during dummy read when empty");
    check_value(m_axis_tvalid, '0', ERROR, "m_axis_tvalid should remain '0' after empty read attempt");

    -- ================================================================
    -- CORNER CASE 2: Full-State Write Attempt (Protocol Violation Guard)
    -- ================================================================
    report "--- Refilling FIFO to full (3 elements) ---";
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"E5");
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"F6");
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"07");
    wait until rising_edge(aclk);
    wait for 0 ns;

    check_value(to_integer(fifo_count), C_DEPTH, ERROR, "fifo_count should be 3 (full)");
    check_value(s_axis_tready, '0', ERROR, "s_axis_tready should be '0' when full");

    -- Rogue master: asserts valid for one cycle while tready='0'.
    -- The FIFO must ignore this data.
    report "--- CORNER CASE 2: Write Attempt on Full (Rogue master) ---";
    s_axis_tdata  <= x"99";
    s_axis_tvalid <= '1';
    wait until rising_edge(aclk);
    wait for 0 ns;
    s_axis_tvalid <= '0';

    check_value(to_integer(fifo_count), C_DEPTH, ERROR, "Over-occupancy detected after rogue write!");
    check_value(s_axis_tready, '0', ERROR, "s_axis_tready mutated after invalid full write attempt");

    -- Drain and verify that 0x99 did not corrupt stored data.
    -- Expected sequence: 0xE5 -> 0xF6 -> 0x07
    report "--- Verifying stored queue elements after rogue write attempt ---";

    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    check_value(v_data, x"E5", ERROR, "Expected first element to be 0xE5");
    check_count_after_cycle(aclk, fifo_count, 2, "fifo_count should be 2");

    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    check_value(v_data, x"F6", ERROR, "Expected second element to be 0xF6");
    check_count_after_cycle(aclk, fifo_count, 1, "fifo_count should be 1");

    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    check_value(v_data, x"07", ERROR, "Expected third element to be 0x07");
    check_count_after_cycle(aclk, fifo_count, 0, "fifo_count should be 0");

    -- ================================================================
    -- CORNER CASE 3: Back-to-Back Single-Item Transits
    -- ================================================================
    -- Test individual items transiting the FIFO: push then pop each
    -- item using proper handshake BFMs, ensuring no deadlocks or bubbles.
    report "--- CORNER CASE 3: Single-cycle Back-to-Back Transit Pipeline ---";

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"11");
    wait until rising_edge(aclk);
    wait for 0 ns;
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    check_value(v_data, x"11", ERROR, "Transit 1 failed, expected 0x11");
    check_count_after_cycle(aclk, fifo_count, 0, "Transient count did not return to 0");

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"22");
    wait until rising_edge(aclk);
    wait for 0 ns;
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    check_value(v_data, x"22", ERROR, "Transit 2 failed, expected 0x22");
    check_count_after_cycle(aclk, fifo_count, 0, "Transient count did not return to 0 after transit 2");

    -- ================================================================
    -- CORNER CASE 4: In-Flight Reset while Non-Empty
    -- ================================================================
    report "--- CORNER CASE 4: In-flight reset while non-empty ---";

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"5A");
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"6B");
    wait until rising_edge(aclk);
    wait for 0 ns;
    check_value(to_integer(fifo_count), 2, ERROR, "setup for in-flight reset expected fifo_count=2");

    aresetn <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);
    aresetn <= '1';
    wait until rising_edge(aclk);
    wait for 0 ns;

    check_value(to_integer(fifo_count), 0, ERROR, "fifo_count should clear to 0 after in-flight reset");
    check_value(m_axis_tvalid, '0', ERROR, "m_axis_tvalid should be 0 after in-flight reset");
    check_value(s_axis_tready, '1', ERROR, "s_axis_tready should be 1 after in-flight reset");

    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, x"77");
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, v_data);
    check_value(v_data, x"77", ERROR, "post-reset functional check failed (expected 0x77)");
    check_count_after_cycle(aclk, fifo_count, 0, "fifo_count should return to 0 after post-reset push/pop");

    report "=== ALL TESTS PASSED SUCCESSFULLY! ===";
    report_alert_counters(FINAL);

    test_done <= '1';
    std.env.stop;
    wait;
  end process;

end architecture;