-----------------------------------------------------------------------
--Filename         : parallel_prng_inst.vhd
--Description      : Instantiation template for prng_top.
--                 : Instantiates xorshift32 and xorshift128.
--                 : Both run free-running (tie step internally) or
--                 : accept external step control via dedicated ports.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity parallel_prng_inst is
end entity;

architecture rtl of parallel_prng_inst is
  signal clk : std_logic;
  signal rstn : std_logic;
  signal step32 : std_logic;
  signal data32 : std_logic_vector(31 downto 0);
  signal step128 : std_logic;
  signal data128 : std_logic_vector(63 downto 0);

begin

  u_xorshift32 : entity work.xorshift32
    generic map (
      GC_SEED => x"DEADBEEF"
    )
    port map (
      -- Clock, reset, and xorshift32 control
      clk  => clk,
      rstn => rstn,
      step => step32,
      data => data32
    );

  u_xorshift128 : entity work.xorshift128
    generic map (
      GC_SEED0 => x"DEADBEEFCAFEBABE",
      GC_SEED1 => x"0123456789ABCDEF"
    )
    port map (
      -- Clock, reset, and xorshift128 control
      clk  => clk,
      rstn => rstn,
      step => step128,
      data => data128
    );

end architecture;
