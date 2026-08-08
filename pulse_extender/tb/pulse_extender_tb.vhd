-----------------------------------------------------------------------
--Filename         : pulse_extender_tb.vhd
--Description      : Testbench for pulse_extender -- covers no-reset
--                 : power-on operation, reset, idle, single-trigger
--                 : pulse length, held-high trigger (no extension,
--                 : re-trigger after expiry), two pulses with a gap,
--                 : registered-output timing, and the GC_PULSE_LEN=1
--                 : edge case.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use std.textio.all;

entity pulse_extender_tb is
end entity;

architecture sim of pulse_extender_tb is

  constant C_CLK_PERIOD : time     := 10 ns;
  constant C_PULSE_LEN  : positive := 4;   -- DUT #1 pulse length
  constant C_PULSE_LEN1 : positive := 1;   -- DUT #2 pulse length (edge case)

  signal clk        : std_logic := '0';
  signal rstn       : std_logic := '1';  -- deasserted: module must work without reset
  signal trigger    : std_logic := '0';
  signal pulse_out  : std_logic;
  signal pulse_out1 : std_logic;
  signal sim_done   : boolean   := false;

  -- Self-checking helper: fail the run on the first mismatch.
  procedure check_bool(
    constant name : in string;
    constant got  : in boolean
  ) is
  begin
    if not got then
      report "FAIL: " & name severity failure;
    else
      report "PASS: " & name severity note;
    end if;
  end procedure;

  -- Measure the high-pulse length starting after the pulse begins.
  -- Samples pulse_out mid-cycle after the registered output has updated.
  procedure measure_pulse(
    signal   clk     : in  std_logic;
    signal   pulse   : in  std_logic;
    constant max_len : in  positive;
    variable length  : out natural
  ) is
  begin
    wait for C_CLK_PERIOD / 2;  -- settle to mid-cycle after the start edge
    length := 0;
    for i in 0 to max_len + 8 loop
      if pulse = '1' then
        length := length + 1;
        wait until rising_edge(clk);
        wait for C_CLK_PERIOD / 2;
      else
        exit;
      end if;
    end loop;
  end procedure;

begin

  -- Clock generator: hold clk low for 2*C_CLK_PERIOD at power-on before
  -- the first rising edge, then free-run. Gated on sim_done to avoid a
  -- simulation hang (clock is driven low when the test completes).
  clk_gen : process
  begin
    clk <= '0';
    wait for C_CLK_PERIOD * 2;  -- stay low before the first rising edge
    loop
      if sim_done then
        clk <= '0';
        wait;  -- stop clocking once the test is done
      end if;
      clk <= not clk;
      wait for C_CLK_PERIOD / 2;
    end loop;
  end process;

  -- DUT #1: default pulse length (4 cycles)
  u_dut : entity work.pulse_extender
    generic map (GC_PULSE_LEN => C_PULSE_LEN)
    port map (
      clk       => clk,
      rstn      => rstn,
      trigger   => trigger,
      pulse_out => pulse_out
    );

  -- DUT #2: minimum pulse length (1 cycle)
  u_dut1 : entity work.pulse_extender
    generic map (GC_PULSE_LEN => C_PULSE_LEN1)
    port map (
      clk       => clk,
      rstn      => rstn,
      trigger   => trigger,
      pulse_out => pulse_out1
    );

  -- == Test sequence ==
  process
    variable l        : line;
    variable high_cnt : natural := 0;
  begin
    -- ================================================================
    -- Phase 1: No reset -- rstn held high from power-on
    --   The module must start in a known state (outputs low) and
    --   generate a correct pulse without ever asserting reset.
    -- ================================================================
    write(l, string'("=== Phase 1: No reset (rstn held high) ===")); writeline(output, l);
    rstn <= '1';  -- keep reset deasserted
    trigger <= '0';
    wait for C_CLK_PERIOD * 2;
    wait for 0 ns;
    check_bool("no-reset: pulse_out = 0 at startup", pulse_out = '0');
    check_bool("no-reset: pulse_out1 = 0 at startup", pulse_out1 = '0');

    trigger <= '1';
    wait until rising_edge(clk);  -- pulse starts without reset
    trigger <= '0';
    measure_pulse(clk, pulse_out, C_PULSE_LEN, high_cnt);
    check_bool("no-reset: pulse length = 4", high_cnt = C_PULSE_LEN);
    check_bool("no-reset: output low after pulse", pulse_out = '0');
    wait for C_CLK_PERIOD * 2;  -- idle before reset phase

    -- ================================================================
    -- Phase 2: Reset -- both outputs must be low
    -- ================================================================
    write(l, string'("=== Phase 2: Reset ===")); writeline(output, l);
    rstn <= '0'; trigger <= '0';
    wait for C_CLK_PERIOD * 2;
    wait for 0 ns;
    check_bool("reset -> pulse_out = 0", pulse_out = '0');
    check_bool("reset -> pulse_out1 = 0", pulse_out1 = '0');

    rstn <= '1';
    wait until rising_edge(clk);
    wait for 0 ns;

    -- ================================================================
    -- Phase 3: Idle -- no trigger, outputs stay low
    -- ================================================================
    write(l, string'("=== Phase 3: Idle ===")); writeline(output, l);
    trigger <= '0';
    wait for C_CLK_PERIOD * 3;
    wait for 0 ns;
    check_bool("idle -> pulse_out = 0", pulse_out = '0');
    check_bool("idle -> pulse_out1 = 0", pulse_out1 = '0');

    -- ================================================================
    -- Phase 4: Single trigger -- output high for exactly C_PULSE_LEN
    -- ================================================================
    write(l, string'("=== Phase 4: Single trigger (len=4) ===")); writeline(output, l);
    trigger <= '1';
    wait for C_CLK_PERIOD / 4;
    check_bool("trigger does not assert output before clock", pulse_out = '0');
    wait until rising_edge(clk);  -- pulse starts
    wait for C_CLK_PERIOD / 4;
    check_bool("registered output asserts after clock", pulse_out = '1');
    trigger <= '0';

    measure_pulse(clk, pulse_out, C_PULSE_LEN, high_cnt);
    check_bool("single-trigger pulse length = 4", high_cnt = C_PULSE_LEN);
    check_bool("output low after pulse", pulse_out = '0');
    wait for C_CLK_PERIOD * 2;  -- idle before next phase

    -- ================================================================
    -- Phase 5: Held-high trigger
    --   - trigger during the active pulse does not extend it
    --   - after the pulse expires, a held-high trigger re-triggers
    -- ================================================================
    write(l, string'("=== Phase 5: Held-high trigger ===")); writeline(output, l);
    trigger <= '1';
    wait until rising_edge(clk);  -- pulse starts; keep trigger high
    measure_pulse(clk, pulse_out, C_PULSE_LEN, high_cnt);
    check_bool("held-high does not extend first pulse (len=4)", high_cnt = C_PULSE_LEN);

    -- While trigger stays high, the output re-triggers after expiry
    wait until pulse_out = '1';
    check_bool("held-high re-triggers after expiry", pulse_out = '1');
    trigger <= '0';
    wait for C_CLK_PERIOD * 2;

    -- ================================================================
    -- Phase 6: Two separate pulses with a gap (trigger low between)
    -- ================================================================
    write(l, string'("=== Phase 6: Two pulses with gap ===")); writeline(output, l);
    trigger <= '1';
    wait until rising_edge(clk);
    trigger <= '0';
    wait for C_CLK_PERIOD * (C_PULSE_LEN + 2);  -- let it end
    wait for 0 ns;
    check_bool("gap: output low between pulses", pulse_out = '0');

    trigger <= '1';
    wait until rising_edge(clk);
    trigger <= '0';
    measure_pulse(clk, pulse_out, C_PULSE_LEN, high_cnt);
    check_bool("second pulse length = 4", high_cnt = C_PULSE_LEN);

    -- ================================================================
    -- Phase 7: Minimum length (GC_PULSE_LEN = 1)
    -- ================================================================
    write(l, string'("=== Phase 7: GC_PULSE_LEN=1 ===")); writeline(output, l);
    wait for C_CLK_PERIOD * 2;
    trigger <= '1';
    wait until rising_edge(clk);
    trigger <= '0';
    wait for C_CLK_PERIOD / 2;  -- settle mid-cycle
    check_bool("len=1: pulse high on trigger", pulse_out1 = '1');
    wait until rising_edge(clk);
    wait for C_CLK_PERIOD / 2;
    check_bool("len=1: pulse low after 1 cycle", pulse_out1 = '0');

    -- ================================================================
    -- All phases complete
    -- ================================================================
    write(l, string'("=== ALL PHASES COMPLETE ===")); writeline(output, l);
    sim_done <= true;
    wait;
  end process;

end architecture;
