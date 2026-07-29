-----------------------------------------------------------------------
--Filename         : jitter_gen_tb.vhd
--Description      : Testbench for jitter_gen — covers reset, enable
--                 : gating, step/hold, and all 4 output buckets.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity jitter_gen_tb is
end entity;

architecture sim of jitter_gen_tb is

  constant C_CLK_PERIOD : time := 10 ns;

  signal clk  : std_logic := '0';
  signal rstn : std_logic := '0';
  signal step : std_logic := '0';
  signal enable : std_logic := '0';
  signal jitter : unsigned(15 downto 0);
  signal sim_done : boolean := false;

  -- Observed jitter value tracking
  signal hit_val0  : boolean := false;
  signal hit_val1  : boolean := false;
  signal hit_val2  : boolean := false;
  signal hit_val3  : boolean := false;

  -- Expected valid values
  constant C_VAL0 : unsigned(15 downto 0) := to_unsigned(0, 16);
  constant C_VAL1 : unsigned(15 downto 0) := to_unsigned(1, 16);
  constant C_VAL2 : unsigned(15 downto 0) := to_unsigned(5, 16);
  constant C_VAL3 : unsigned(15 downto 0) := to_unsigned(20, 16);

  impure function is_valid_jitter(v : unsigned) return boolean is
  begin
    return v = C_VAL0 or v = C_VAL1 or v = C_VAL2 or v = C_VAL3;
  end function;

begin

  clk <= not clk after C_CLK_PERIOD / 2 when not sim_done else '0';

  -- Clocked checker
  process(clk)
    variable l : line;
  begin
    if rising_edge(clk) then
      if rstn = '1' then
        if not is_valid_jitter(jitter) then
          write(l, string'("FAIL: invalid jitter value "));
          write(l, to_integer(jitter));
          writeline(output, l);
          report "Test failed." severity failure;
        end if;
        if jitter = C_VAL0 then hit_val0 <= true; end if;
        if jitter = C_VAL1 then hit_val1 <= true; end if;
        if jitter = C_VAL2 then hit_val2 <= true; end if;
        if jitter = C_VAL3 then hit_val3 <= true; end if;
      end if;
    end if;
  end process;

  u_dut : entity work.jitter_gen
    generic map (
      GC_JITTER_WIDTH => 16,
      GC_SEED => x"DEADBEEF",
      GC_VAL_0 => 0,    GC_VAL_1 => 1,
      GC_VAL_2 => 5,    GC_VAL_3 => 20,
      GC_TH_0  => 128,  GC_TH_1  => 192,
      GC_TH_2  => 240
    )
    port map (
      clk => clk, rstn => rstn, step => step, enable => enable,
      jitter => jitter
    );

  -- == Test sequence ==
  process
    variable l : line;
    variable cnt0, cnt1, cnt2, cnt3 : natural := 0;
  begin
    -- ============================================================
    -- Phase 1: Reset — output must be 0
    -- ============================================================
    write(l, string'("=== Phase 1: Reset check ===")); writeline(output, l);
    rstn <= '0'; enable <= '0'; step <= '0';
    wait for C_CLK_PERIOD * 2;
    wait for 0 ns;
    if jitter /= 0 then
      report "FAIL: output not zero after reset" severity failure;
    end if;
    write(l, string'("  OK: output=0 after reset")); writeline(output, l);

    -- ============================================================
    -- Phase 2: Enable low — output stays 0 even with step
    -- ============================================================
    write(l, string'("=== Phase 2: Enable low + step -> output=0 ===")); writeline(output, l);
    rstn <= '1'; enable <= '0';
    for i in 0 to 3 loop
      wait until rising_edge(clk); step <= '1';
      wait until rising_edge(clk); step <= '0';
      if jitter /= 0 then
        report "FAIL: output not zero when enable=0" severity failure;
      end if;
    end loop;
    write(l, string'("  OK: output held at 0 with enable=0")); writeline(output, l);

    -- ============================================================
    -- Phase 3: Enable high + no step — output holds
    -- ============================================================
    write(l, string'("=== Phase 3: Enable high, no step -> hold ===")); writeline(output, l);
    enable <= '1';
    wait for C_CLK_PERIOD * 3;
    if jitter /= 0 then
      report "FAIL: output changed without step" severity failure;
    end if;
    write(l, string'("  OK: output held at 0 with enable=1, no step")); writeline(output, l);

    -- ============================================================
    -- Phase 4: Run 65536 samples and report bucket distribution
    -- ============================================================
    write(l, string'("=== Phase 4: 65536 iterations ===")); writeline(output, l);
    enable <= '1';
    cnt0 := 0; cnt1 := 0; cnt2 := 0; cnt3 := 0;
    for i in 0 to 65535 loop
      wait until rising_edge(clk); step <= '1';
      wait until rising_edge(clk);
      case to_integer(jitter) is  -- read while step is still high
        when 0  => cnt0 := cnt0 + 1;
        when 1  => cnt1 := cnt1 + 1;
        when 5  => cnt2 := cnt2 + 1;
        when 20 => cnt3 := cnt3 + 1;
        when others =>
          report "FAIL: unexpected jitter value " & integer'image(to_integer(jitter))
          severity failure;
      end case;
      step <= '0';
    end loop;

    -- ============================================================
    -- Phase 5: Enable toggle test
    -- ============================================================
    write(l, string'("=== Phase 5: Enable toggle ===")); writeline(output, l);
    step <= '0';
    wait until rising_edge(clk);
    enable <= '0';
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    if jitter /= 0 then
      report "FAIL: output not zero after enable dropped" severity failure;
    end if;
    write(l, string'("  enable=0 -> jitter=0: OK")); writeline(output, l);

    -- Re-enable and step: output should update
    enable <= '1';
    wait until rising_edge(clk);
    step <= '1';
    wait until rising_edge(clk);  -- step=1 active; DUT updates jitter
    step <= '0';
    wait until rising_edge(clk);  -- wait for delta propagation
    write(l, string'("  enable=1 + step -> jitter="));
    write(l, to_integer(jitter));
    writeline(output, l);

    -- ============================================================
    -- Final bucket report (65536 samples from Phase 4)
    -- ============================================================
    write(l, string'("Bucket report (65536 samples):")); writeline(output, l);
    write(l, string'("  GC_VAL_0 (0):  ")); write(l, cnt0);
    write(l, string'("  ")); write(l, (cnt0 * 10000 / 65536) / 100);
    write(l, string'(".")); write(l, (cnt0 * 10000 / 65536) mod 100);
    write(l, string'("%")); writeline(output, l);
    write(l, string'("  GC_VAL_1 (1):  ")); write(l, cnt1);
    write(l, string'("  ")); write(l, (cnt1 * 10000 / 65536) / 100);
    write(l, string'(".")); write(l, (cnt1 * 10000 / 65536) mod 100);
    write(l, string'("%")); writeline(output, l);
    write(l, string'("  GC_VAL_2 (5):  ")); write(l, cnt2);
    write(l, string'("  ")); write(l, (cnt2 * 10000 / 65536) / 100);
    write(l, string'(".")); write(l, (cnt2 * 10000 / 65536) mod 100);
    write(l, string'("%")); writeline(output, l);
    write(l, string'("  GC_VAL_3 (20): ")); write(l, cnt3);
    write(l, string'("  ")); write(l, (cnt3 * 10000 / 65536) / 100);
    write(l, string'(".")); write(l, (cnt3 * 10000 / 65536) mod 100);
    write(l, string'("%")); writeline(output, l);

    -- Assert all four buckets were observed at least once
    if not hit_val0 then
      report "FAIL: bucket GC_VAL_0 never observed" severity failure;
    end if;
    if not hit_val1 then
      report "FAIL: bucket GC_VAL_1 never observed" severity failure;
    end if;
    if not hit_val2 then
      report "FAIL: bucket GC_VAL_2 never observed" severity failure;
    end if;
    if not hit_val3 then
      report "FAIL: bucket GC_VAL_3 never observed" severity failure;
    end if;
    write(l, string'("  All 4 buckets observed OK")); writeline(output, l);

    -- ============================================================
    -- Done
    -- ============================================================
    write(l, string'("All tests passed.")); writeline(output, l);
    sim_done <= true;
    wait;
  end process;

end architecture;
