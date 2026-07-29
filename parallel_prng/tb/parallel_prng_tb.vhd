-----------------------------------------------------------------------
--Filename         : parallel_prng_tb.vhd
--Description      : Testbench for xorshift32 and xorshift128 PRNG modules.
--                 : Instantiates both, runs free-running for 20 cycles,
--                 : prints output values for visual inspection.
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity parallel_prng_tb is
end entity;

architecture sim of parallel_prng_tb is

  constant C_CLK_PERIOD : time := 10 ns;

  signal clk  : std_logic := '0';
  signal rstn : std_logic := '0';
  signal step : std_logic := '1';  -- free-running

  signal data32  : std_logic_vector(31 downto 0);
  signal data128 : std_logic_vector(63 downto 0);

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

  -- Clock
  clk <= not clk after C_CLK_PERIOD / 2;

  -- Reset
  process
  begin
    rstn <= '0';
    wait for C_CLK_PERIOD * 2;
    rstn <= '1';
    wait;
  end process;

  -- DUT : xorshift32
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

  -- DUT : xorshift128
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

  -- Monitor
  process(clk)
    variable l : line;
  begin
    if rising_edge(clk) then
      if rstn = '1' then
        write(l, string'("xorshift32 :  "));
        hwrite(l, data32);
        write(l, string'("    xorshift128 :  "));
        hwrite(l, data128);
        writeline(output, l);
      end if;
    end if;
  end process;

  -- Run limit
  process
  begin
    wait for C_CLK_PERIOD * 25;  -- 2 reset + 23 active cycles
    report "Simulation complete." severity note;
    std.env.stop;
  end process;

end architecture;
