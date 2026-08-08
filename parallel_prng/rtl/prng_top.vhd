-----------------------------------------------------------------------
--Filename         : prng_top.vhd
--Description      : Top wrapper exporting all parallel_prng modules.
--                 : Instantiates xorshift32 and xorshift128.
--                 : Both run free-running (tie step internally) or
--                 : accept external step control via dedicated ports.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity prng_top is
  port (
    -- Clock and reset
    clk  : in std_logic;
    rstn : in std_logic;

    -- xorshift32 control and output
    step32 : in  std_logic;
    data32 : out std_logic_vector(31 downto 0);

    -- xorshift128 control and output
    step128 : in  std_logic;
    data128 : out std_logic_vector(63 downto 0)
  );
end entity;

architecture rtl of prng_top is
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
