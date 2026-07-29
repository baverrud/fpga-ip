-----------------------------------------------------------------------
--Filename         : jitter_gen.vhd
--Description      : CDF-based jitter generator with built-in PRNG.
--                 : Select PRNG by commenting/uncommenting below.
--                 : Takes the lowest 8 bits of the PRNG output and
--                 : compares them against cumulative thresholds.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jitter_gen is
  generic (
    GC_JITTER_WIDTH     : positive := 16;

    -- PRNG selection: false = xorshift32, true = xorshift128
    GC_USE_XORSHIFT128  : boolean  := false;

    -- PRNG seeds (xorshift32 uses GC_SEED; xorshift128 uses GC_SEED0/1)
    GC_SEED             : std_logic_vector(31 downto 0) := x"DEADBEEF";
    GC_SEED0            : std_logic_vector(63 downto 0) := x"DEADBEEFCAFEBABE";
    GC_SEED1            : std_logic_vector(63 downto 0) := x"0123456789ABCDEF";

    -- 4 target jitter values
    GC_VAL_0            : integer := 0;
    GC_VAL_1            : integer := 1;
    GC_VAL_2            : integer := 5;
    GC_VAL_3            : integer := 20;

    -- 3 cumulative thresholds (8-bit, strictly ascending, 0..255)
    GC_TH_0             : integer := 128;
    GC_TH_1             : integer := 192;
    GC_TH_2             : integer := 240
  );
  port (
    clk            : in  std_logic;
    rstn           : in  std_logic;

    step           : in  std_logic;
    enable         : in  std_logic;

    jitter         : out unsigned(GC_JITTER_WIDTH-1 downto 0)
  );
end entity;

architecture rtl of jitter_gen is

  constant C_TH_ORDER_OK : boolean := (GC_TH_0 < GC_TH_1) and
                                      (GC_TH_1 < GC_TH_2);
  constant C_TH_LIMIT_OK : boolean := (GC_TH_2 < 256) and (GC_TH_0 >= 0);

  signal rand_val  : std_logic_vector(63 downto 0);
  signal r_jitter  : unsigned(GC_JITTER_WIDTH-1 downto 0) := (others => '0');

begin

  assert C_TH_ORDER_OK
    report "DESIGN ERROR: Generics GC_TH_0 through GC_TH_2 must be strictly ascending!"
    severity failure;

  assert C_TH_LIMIT_OK
    report "DESIGN ERROR: Generics GC_TH must be in range [0, 255] for 8-bit resolution!"
    severity failure;

  -- ================================================================
  -- PRNG selection (controlled by GC_USE_XORSHIFT128 generic)
  --   false = xorshift32  (32-bit output, uses GC_SEED)
  --   true  = xorshift128 (64-bit output, uses GC_SEED0/GC_SEED1)
  -- ================================================================

  gen_xorshift32 : if not GC_USE_XORSHIFT128 generate
    u_prng : entity work.xorshift32
      generic map (GC_SEED => GC_SEED)
      port map (clk => clk, rstn => rstn, step => step, data => rand_val(31 downto 0));
  end generate;

  gen_xorshift128 : if GC_USE_XORSHIFT128 generate
    u_prng : entity work.xorshift128
      generic map (GC_SEED0 => GC_SEED0, GC_SEED1 => GC_SEED1)
      port map (clk => clk, rstn => rstn, step => step, data => rand_val);
  end generate;

  jitter <= r_jitter;

  process(clk)
    variable v_slice : unsigned(7 downto 0);
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        r_jitter <= (others => '0');
      elsif enable = '0' then
        r_jitter <= (others => '0');
      elsif step = '1' then
        v_slice := unsigned(rand_val(7 downto 0));

        if    v_slice < to_unsigned(GC_TH_0, 8) then
          r_jitter <= to_unsigned(GC_VAL_0, GC_JITTER_WIDTH);
        elsif v_slice < to_unsigned(GC_TH_1, 8) then
          r_jitter <= to_unsigned(GC_VAL_1, GC_JITTER_WIDTH);
        elsif v_slice < to_unsigned(GC_TH_2, 8) then
          r_jitter <= to_unsigned(GC_VAL_2, GC_JITTER_WIDTH);
        else
          r_jitter <= to_unsigned(GC_VAL_3, GC_JITTER_WIDTH);
        end if;
      end if;
    end if;
  end process;

end architecture;
