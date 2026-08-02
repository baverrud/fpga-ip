-----------------------------------------------------------------------
--Filename         : parallel_prng_tb.vhd
--Description      : Self-checking testbench for xorshift32 and
--                 : xoroshiro128+ PRNG modules.  The first ten
--                 : xoroshiro128+ outputs are checked against the
--                 : published reference recurrence and default seeds.
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity parallel_prng_tb is
end entity;

architecture sim of parallel_prng_tb is

  -- The testbench drives both generators with the same synchronous reset
  -- and free-running step signal, then compares their visible outputs.
  constant C_CLK_PERIOD : time := 10 ns;

  -- Golden values generated from the official Marsaglia xorshift32
  -- recurrence: x ^= x<<13; x ^= x>>17; x ^= x<<5.
  -- Reference: https://www.jstatsoft.org/article/view/v008i14
  -- Seed: GC_SEED = DEADBEEF.
  type t_expected32 is array (0 to 9) of std_logic_vector(31 downto 0);
  constant C_EXPECTED32 : t_expected32 := (
    x"DEADBEEF",
    x"477D20B7",
    x"8E1D9142",
    x"BA8C2458",
    x"FEE0503B",
    x"680E0348",
    x"A48DB81B",
    x"6254EA5C",
    x"1CFDAFB3",
    x"8878FDF6");

  -- Golden values generated from the official xoroshiro128+ reference
  -- implementation by Blackman and Vigna:
  -- https://prng.di.unimi.it/xoroshiro128plus.c
  -- Seeds: s0=DEADBEEFCAFEBABE, s1=0123456789ABCDEF.
  -- Recurrence: result=s0+s1; s1^=s0; s0=rotl(s0,24)^s1^(s1<<16);
  --             s1=rotl(s1,37).  Values below expose the current state
  -- sum, so entry 0 is the initial seed sum.
  type t_expected128 is array (0 to 9) of std_logic_vector(63 downto 0);
  constant C_EXPECTED128 : t_expected128 := (
    x"DFD1045754AA88AD",
    x"367B30A37CBA4BF7",
    x"CB698A776B7EF330",
    x"67E6D12D9E668705",
    x"F7F6C11645C9152D",
    x"5B50F397CED0E7F7",
    x"32B46C09903D111E",
    x"74D5B76A0F324A9E",
    x"01740D083ACBE2BC",
    x"A1C615E0D63FC689");

  signal clk  : std_logic := '0';
  signal rstn : std_logic := '0';
  signal step : std_logic := '1';  -- free-running

  signal data32  : std_logic_vector(31 downto 0);
  signal data128 : std_logic_vector(63 downto 0);

  -- Golden tables cover the initial state output plus the first nine
  -- state transitions.  The assertions below deliberately check only
  -- the first ten samples; later values remain available for waveforms.

  component xorshift32 is
    generic (
      GC_SEED : std_logic_vector(31 downto 0) := x"DEADBEEF"
    );
    port (
      clk  : in  std_logic;
      rstn : in  std_logic;
      step : in  std_logic;
      data : out std_logic_vector(31 downto 0)
    );
  end component;

  component xorshift128 is
    generic (
      GC_SEED0 : std_logic_vector(63 downto 0) := x"DEADBEEFCAFEBABE";
      GC_SEED1 : std_logic_vector(63 downto 0) := x"0123456789ABCDEF"
    );
    port (
      clk  : in  std_logic;
      rstn : in  std_logic;
      step : in  std_logic;
      data : out std_logic_vector(63 downto 0)
    );
  end component;

begin

  -- Free-running clock.  The testbench stops explicitly through std.env.stop.
  clk <= not clk after C_CLK_PERIOD / 2;

  -- Synchronous active-low reset.  The first two clock periods load the
  -- configured seeds before normal stepping begins.
  process
  begin
    rstn <= '0';
    wait for C_CLK_PERIOD * 2;
    rstn <= '1';
    wait;
  end process;

  -- DUT: Marsaglia xorshift32 reference implementation.
  u_xorshift32 : xorshift32
    generic map (
      GC_SEED => x"DEADBEEF"
    )
    port map (
      clk  => clk,
      rstn => rstn,
      step => step,
      data => data32
    );

  -- DUT: xoroshiro128+ implementation using the two 64-bit seed values.
  u_xorshift128 : xorshift128
    generic map (
      GC_SEED0 => x"DEADBEEFCAFEBABE",
      GC_SEED1 => x"0123456789ABCDEF"
    )
    port map (
      clk  => clk,
      rstn => rstn,
      step => step,
      data => data128
    );

  -- Monitor and checker.  At each active rising edge, the assertions compare
  -- the outputs against the golden tables before printing both sequences.
  process(clk)
    variable l : line;
    variable sample_idx : natural := 0;
  begin
    if rising_edge(clk) then
      if rstn = '1' then
        if sample_idx <= C_EXPECTED128'high then
          assert data32 = C_EXPECTED32(sample_idx)
            report "xorshift32 mismatch at sample " &
              integer'image(sample_idx) &
              ": expected 0x" & to_hstring(C_EXPECTED32(sample_idx)) &
              ", received 0x" & to_hstring(data32)
            severity error;
          assert data128 = C_EXPECTED128(sample_idx)
            report "xoroshiro128+ mismatch at sample " &
              integer'image(sample_idx) &
              ": expected 0x" & to_hstring(C_EXPECTED128(sample_idx)) &
              ", received 0x" & to_hstring(data128)
            severity error;
          sample_idx := sample_idx + 1;
        end if;
        write(l, string'("xorshift32 :  "));
        hwrite(l, data32);
        write(l, string'("    xorshift128 :  "));
        hwrite(l, data128);
        writeline(output, l);
      end if;
    end if;
  end process;

  -- Run limit.  This is a final safety stop so an accidental clock or reset
  -- issue cannot leave the simulator running indefinitely.
  process
  begin
    wait for C_CLK_PERIOD * 25;  -- 2 reset + 23 active cycles
    report "Simulation complete." severity note;
    std.env.stop;
  end process;

end architecture;
