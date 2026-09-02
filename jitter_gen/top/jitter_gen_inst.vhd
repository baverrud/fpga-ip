-----------------------------------------------------------------------
--Filename         : jitter_gen_inst.vhd
--Description      : Instantiation template for jitter_gen_top.
--                 : Passes all generics through to the CDF-based jitter
--                 : generator with its selectable internal PRNG.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jitter_gen_inst is
  generic (
    -- Jitter generator and PRNG configuration
    GC_JITTER_WIDTH    : positive := 8;
    GC_USE_XORSHIFT128 : boolean := false;
    GC_SEED            : std_logic_vector(31 downto 0) := x"DEADBEEF";
    GC_SEED0           : std_logic_vector(63 downto 0) := x"DEADBEEFCAFEBABE";
    GC_SEED1           : std_logic_vector(63 downto 0) := x"0123456789ABCDEF";
    GC_VAL_0           : integer := 0;
    GC_VAL_1           : integer := 1;
    GC_VAL_2           : integer := 3;
    GC_VAL_3           : integer := 7;
    GC_TH_0            : integer := 128;
    GC_TH_1            : integer := 192;
    GC_TH_2            : integer := 240
  );
end entity;

architecture rtl of jitter_gen_inst is
  signal clk : std_logic;
  signal rstn : std_logic;
  signal step : std_logic;
  signal enable : std_logic;
  signal jitter : unsigned(GC_JITTER_WIDTH-1 downto 0);

begin

  u_jitter : entity work.jitter_gen
    generic map (
      GC_JITTER_WIDTH    => GC_JITTER_WIDTH,
      GC_USE_XORSHIFT128 => GC_USE_XORSHIFT128,
      GC_SEED            => GC_SEED,
      GC_SEED0           => GC_SEED0,
      GC_SEED1           => GC_SEED1,
      GC_VAL_0           => GC_VAL_0,
      GC_VAL_1           => GC_VAL_1,
      GC_VAL_2           => GC_VAL_2,
      GC_VAL_3           => GC_VAL_3,
      GC_TH_0            => GC_TH_0,
      GC_TH_1            => GC_TH_1,
      GC_TH_2            => GC_TH_2
    )
    port map (
      -- Clock, reset, and controls
      clk    => clk,
      rstn   => rstn,
      step   => step,
      enable => enable,

      -- Generated jitter value
      jitter => jitter
    );

end architecture;
