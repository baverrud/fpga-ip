-----------------------------------------------------------------------
--Filename         : jitter_gen.vhd
--Description      : CDF-based jitter generator with selectable built-in PRNG.
--                 : GC_USE_XORSHIFT128 selects xorshift32 (false) or
--                 : xorshift128 (true). Takes the lowest 8 bits of the
--                 : PRNG output and compares against cumulative thresholds.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jitter_gen is
  generic (
    GC_JITTER_WIDTH     : positive := 8;

    -- PRNG selection: false = xorshift32, true = xorshift128
    GC_USE_XORSHIFT128  : boolean  := false;

    -- PRNG seeds (xorshift32 uses GC_SEED; xorshift128 uses GC_SEED0/1)
    GC_SEED             : std_logic_vector(31 downto 0) := x"DEADBEEF";
    GC_SEED0            : std_logic_vector(63 downto 0) := x"DEADBEEFCAFEBABE";
    GC_SEED1            : std_logic_vector(63 downto 0) := x"0123456789ABCDEF";

    -- 4 target jitter values
    GC_VAL_0            : integer := 0;
    GC_VAL_1            : integer := 1;
    GC_VAL_2            : integer := 3;
    GC_VAL_3            : integer := 7;

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

  -- PRNG output bus (width 64 accommodates both xorshift32 and xorshift128).
  -- xorshift32 drives only the lower 32 bits; upper bits are unused.
  signal rand_val  : std_logic_vector(63 downto 0);

  -- Registered jitter output. Updated only on a rising clock edge where
  -- rstn=1, enable=1, and step=1. Holds its value between step pulses.
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

  -- Core jitter sampling process.
  -- Priority (highest to lowest):
  --   1. Reset (rstn=0)           -> force output to zero
  --   2. Enable low (enable=0)     -> force output to zero (gating)
  --   3. Step pulse (step=1)      -> sample PRNG output, apply CDF mapping
  --   4. Otherwise                -> hold current r_jitter value
  process(clk)
    variable v_slice : unsigned(7 downto 0);
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        r_jitter <= (others => '0');
      elsif enable = '0' then
        r_jitter <= (others => '0');
      elsif step = '1' then
        -- Take lowest 8 bits of PRNG output as the probability axis (0-255)
        v_slice := unsigned(rand_val(7 downto 0));

        -- CDF comparison: v_slice is compared against three cumulative
        -- thresholds. Each threshold defines the upper bound of a probability
        -- bucket. The thresholds are strictly ascending and span 0-255.
        --
        --   Bucket 0: [0,       GC_TH_0)  -> GC_VAL_0  (~50%  at defaults)
        --   Bucket 1: [GC_TH_0, GC_TH_1)  -> GC_VAL_1  (~25%  at defaults)
        --   Bucket 2: [GC_TH_1, GC_TH_2)  -> GC_VAL_2  (~19%  at defaults)
        --   Bucket 3: [GC_TH_2, 256)      -> GC_VAL_3  (~6%   at defaults)
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
