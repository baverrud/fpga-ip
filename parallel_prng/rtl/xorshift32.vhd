-----------------------------------------------------------------------
--Filename         : xorshift32.vhd
--Description      : Marsaglia xorshift32 PRNG (2003).
--                 :   x ^= x << 13; x ^= x >> 17; x ^= x << 5;
--                 : Full period 2^32-1.
--                 : Ref: G. Marsaglia, "Xorshift RNGs", J. Stat. Soft. 2003.
--                 :
--                 : Zero DSP -- pure XOR + shift. 32-bit state, 32-bit output.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity xorshift32 is
  generic (
    GC_SEED : std_logic_vector(31 downto 0) := x"DEADBEEF"
  );
  port (
    clk     : in  std_logic;
    rstn    : in  std_logic;           -- Synchronous reset (active low)
    step    : in  std_logic;           -- Advance by one iteration
    data    : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of xorshift32 is

  signal x : unsigned(31 downto 0) := unsigned(GC_SEED);

begin

  process(clk)
    variable v : unsigned(31 downto 0);
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        x <= unsigned(GC_SEED);
      elsif step = '1' then
        v  := x;
        v  := v xor (v sll 13);
        v  := v xor (v srl 17);
        v  := v xor (v sll 5);
        x  <= v;
      end if;
    end if;
  end process;

  data <= std_logic_vector(x);

end architecture;
