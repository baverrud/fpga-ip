-----------------------------------------------------------------------
--Filename         : xorshift128.vhd
--Description      : xoroshiro128+ PRNG (Vigna 2016).
--                 :   s0 = rotl(s0, 24) ^ s1 ^ (s1 << 16)
--                 :   s1 = rotl(s1, 37)
--                 :   result = s0 + s1
--                 : Passes Crush (fails BigCrush).
--                 : Ref: D. Blackman & S. Vigna, "xoroshiro128+", 2016.
--                 :
--                 : Zero DSP — add + XOR + shift + rotate only.
--                 : 128-bit state (2x64), 64-bit output per cycle.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity xorshift128 is
  generic (
    GC_SEED0 : std_logic_vector(63 downto 0) := x"DEADBEEFCAFEBABE";
    GC_SEED1 : std_logic_vector(63 downto 0) := x"0123456789ABCDEF"
  );
  port (
    clk     : in  std_logic;
    rstn    : in  std_logic;           -- Synchronous reset (active low)
    step    : in  std_logic;           -- Advance by one iteration
    data    : out std_logic_vector(63 downto 0)
  );
end entity;

architecture rtl of xorshift128 is

  signal s0, s1 : unsigned(63 downto 0) := (others => '0');

  -- rotl(v, n) = v(63-n downto 0) & v(63 downto 64-n)
  pure function rotl(v : unsigned; n : natural) return unsigned is
  begin
    return v(63-n downto 0) & v(63 downto 64-n);
  end function;

begin

  process(clk)
    variable v0, v1 : unsigned(63 downto 0);
    variable result : unsigned(63 downto 0);
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        s0 <= unsigned(GC_SEED0);
        s1 <= unsigned(GC_SEED1);
      elsif step = '1' then
        v0     := s0;
        v1     := s1;
        result := v0 + v1;
        v1     := v1 xor v0;
        s0     <= rotl(v0, 24) xor v1 xor (v1 sll 16);
        s1     <= rotl(v1, 37);
        data   <= std_logic_vector(result);
      end if;
    end if;
  end process;

end architecture;
