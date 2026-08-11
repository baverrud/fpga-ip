-----------------------------------------------------------------------
--Filename         : util_pkg.vhd
--Description      : Shared utility package for fpga-ip cores.
--                 : Array types, log2ceil, Gray-code CDC pointer helpers,
--                 : and small conversion/math/predicate utilities (VHDL-2008).
--Author           : Rune Baeverrud
--Current Revision : 1.01
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package util_pkg is

  -- Generic array of std_logic_vectors, each element arbitrarily wide.
  -- Signal declaration example:
  --   signal my_sig : slv_array_t(0 to 7)(31 downto 0);  -- 8x 32-bit
  type slv_array_t is array(natural range <>) of std_logic_vector;

  -- Convenience subtypes: arrays of fixed-width std_logic_vectors.
  subtype slv64_array_t is slv_array_t(open)(63 downto 0);
  subtype slv32_array_t is slv_array_t(open)(31 downto 0);
  subtype slv16_array_t is slv_array_t(open)(15 downto 0);
  subtype slv8_array_t  is slv_array_t(open)(7 downto 0);
  subtype slv2_array_t  is slv_array_t(open)(1 downto 0);

  -----------------------------------------------------------------------
  -- log2ceil:
  -- Returns the number of bits required to represent 'val' distinct
  -- positive values, i.e. ceil(log2(val)). Examples:
  --   log2ceil(1)  = 0      log2ceil(2)  = 1
  --   log2ceil(3)  = 2      log2ceil(16) = 4
  -- Typical use: address-bus width for a FIFO / RAM of depth 'val'.
  -- Uses division instead of multiplication to avoid any temporary
  -- integer overflow up to positive'high.
  -- Note: VHDL-2008 has no built-in log2, so this stays a helper.
  -----------------------------------------------------------------------
  function log2ceil (val : positive) return natural;

  -----------------------------------------------------------------------
  -- Gray-code pointer helpers for asynchronous FIFO / CDC designs.
  -- These functions operate on GRAY-encoded pointers. Gray encoding
  -- changes exactly one bit per increment. This limits a synchronized
  -- sample to an old or adjacent pointer value, provided the design
  -- also uses synchronizer stages and appropriate CDC timing constraints.
  -- The helpers below use the repository convention unsigned(N downto 0).
  -----------------------------------------------------------------------

  -- bin2gray: convert a binary pointer to Gray code.
  --   g(msb) = b(msb),  g(i) = b(i) xor b(i+1)
  -- The input must be a non-null descending unsigned range.
  function bin2gray (bin : unsigned) return unsigned;

  -- gray2bin: convert a Gray pointer back to binary (inverse of
  -- bin2gray). Needed on the receiving side of a synchronized pointer
  -- when computing occupancy / watermarks, e.g.
  --   words_in_fifo := wptr_bin - gray2bin(rptr_gray_sync);
  -- The input must be a non-null descending unsigned range.
  function gray2bin (gray : unsigned) return unsigned;

  -- is_gray_full: full flag for Gray pointers. Full is reached when
  -- the write pointer has lapped the read pointer by one full turn:
  -- the top two MSBs are inverted and the lower bits match
  --   wptr_gray = (not rptr_gray(msb downto msb-1)) & rptr_gray(low)
  -- Both arguments must have equal, non-null descending ranges with at
  -- least two bits. The two-bit case (depth 2) degenerates to
  -- wptr_gray = not rptr_gray.
  function is_gray_full (wptr_gray, rptr_gray : unsigned) return boolean;

  -- is_gray_empty: empty flag for Gray pointers. Empty is simply
  --   wptr_gray = rptr_gray   (both pointers at the same Gray value)
  -- Both arguments must have equal, non-null descending ranges.
  function is_gray_empty (wptr_gray, rptr_gray : unsigned) return boolean;

  -----------------------------------------------------------------------
  -- is_power_of_two: predicate for generic validation. Use with a
  -- static assert to reject illegal generics at elaboration time:
  --   assert is_power_of_two(GC_FIFO_DEPTH)
  --     report "GC_FIFO_DEPTH must be a power of 2" severity failure;
  -----------------------------------------------------------------------
  function is_power_of_two (n : positive) return boolean;

  -----------------------------------------------------------------------
  -- to_std_logic: convert a boolean to '1'/'0'. Compact way to build
  -- a single-bit flag from a condition:
  --   tready <= to_std_logic(not full);
  -----------------------------------------------------------------------
  function to_std_logic (b : boolean) return std_logic;

  -----------------------------------------------------------------------
  -- sel: two-input mux as a function. Overloads for unsigned and
  -- std_logic_vector. Gives the same result as a VHDL-2008 conditional
  -- expression (a when cond else b), but is callable inside larger
  -- expressions and aggregates:
  --   next_ptr <= sel(handshake, ptr + 1, ptr);
  -----------------------------------------------------------------------
  function sel (cond : boolean; a, b : unsigned) return unsigned;
  function sel (cond : boolean; a, b : std_logic_vector) return std_logic_vector;

  -----------------------------------------------------------------------
  -- ceil_div: natural division rounded UP. Useful for burst / beat
  -- math, e.g. number of AXI bursts to move a byte count:
  --   num_bursts := ceil_div(byte_count, beats_per_burst * bytes_per_beat);
  -- A zero numerator returns zero; the denominator must be positive.
  -- Implemented as (a - 1) / b + 1 to avoid (a + b - 1) overflowing.
  -----------------------------------------------------------------------
  function ceil_div (a : natural; b : positive) return natural;

  -----------------------------------------------------------------------
  -- count_ones: population count of a std_logic_vector. Useful for
  -- credit counters and tag/bitmask accounting:
  --   pending := count_ones(credit_mask);
  -- Only '1' contributes to the count. '0', 'X', 'U', 'Z', and other
  -- values are treated as zero, which keeps the helper synthesizable.
  -- (numeric_std only has this for unsigned/signed, not std_logic_vector.)
  -----------------------------------------------------------------------
  function count_ones (v : std_logic_vector) return natural;

  -----------------------------------------------------------------------
  -- VHDL-2008 BUILT-IN ALTERNATIVES -- no functions defined here,
  -- use the language / library features directly instead:
  --
  --  * maximum / minimum (scalar types, incl. integer/natural):
  --        c := maximum(a, b);   d := minimum(a, b);
  --    Built into the language; do NOT add max/min functions.
  --
  --  * resize (unsigned / signed in numeric_std):
  --        wide := resize(narrow, wide'length);      -- zero/sign extend
  --        slv  := std_logic_vector(resize(u, 16));  -- to 16 bits
  --    Handles BOTH extension and truncation; use instead of
  --    hand-rolled zero_extend / sign_extend helpers.
  --
  --  * to_hstring / to_ostring / to_string (numeric_std and
  --    std_logic_1164, VHDL-2008) for report / debug formatting:
  --        report "addr = " & to_hstring(addr);       -- hex
  --        report "cnt  = " & to_string(cnt);        -- decimal (int)
  --    No hand-rolled hex-print helpers required.
  --
  --  * Conditional / selected expressions (VHDL-2008):
  --        y <= a when sel else b;                    -- conditional
  --        y <= a when sel0 else b when sel1 else c;  -- multi-way
  --        y <= a when sel = "00" else b when ...;    -- like a case
  --    The sel() functions above are only for use inside larger
  --    expressions where the ?: syntax is not convenient.
  -----------------------------------------------------------------------

end package;

package body util_pkg is

  -- Log2 Ceil computation for calculating minimum address bit-widths
  function log2ceil (val : positive) return natural is
    variable temp : natural := val - 1;
    variable log2 : natural := 0;
  begin
    while temp > 0 loop
      log2 := log2 + 1;
      temp := temp / 2;
    end loop;
    return log2;
  end function;

  -- Binary to Gray Code converter for safe CDC pointer transfer.
  function bin2gray (bin : unsigned) return unsigned is
  begin
    assert bin'length > 0
      report "bin2gray requires a non-null unsigned argument"
      severity failure;
    assert not bin'ascending
      report "bin2gray requires an unsigned(N downto 0) argument"
      severity failure;
    -- g(msb) = b(msb); g(i) = b(i) xor b(i+1). The concat '0' & ...
    -- places the '0' at the MSB, so the MSB of the result is unchanged.
    return bin xor ('0' & bin(bin'high downto bin'low + 1));
  end function;

  -- Gray to Binary converter: inverse of bin2gray. Each bit is the
  -- running XOR of the Gray bits above it (XOR is its own inverse).
  function gray2bin (gray : unsigned) return unsigned is
    variable bin : unsigned(gray'range);
  begin
    assert gray'length > 0
      report "gray2bin requires a non-null unsigned argument"
      severity failure;
    assert not gray'ascending
      report "gray2bin requires an unsigned(N downto 0) argument"
      severity failure;
    bin := gray;
    for i in bin'high - 1 downto bin'low loop
      bin(i) := bin(i + 1) xor gray(i);
    end loop;
    return bin;
  end function;

  -- Full condition detection for Gray-coded pointers.
  -- Full occurs when the top two MSBs are inverted and the lower bits match.
  function is_gray_full (wptr_gray, rptr_gray : unsigned) return boolean is
    constant C_W : natural := wptr_gray'length;
  begin
    assert wptr_gray'length = rptr_gray'length
      report "is_gray_full requires equal-width Gray pointers"
      severity failure;
    assert C_W >= 2
      report "is_gray_full requires Gray pointers with at least two bits"
      severity failure;
    assert not wptr_gray'ascending and not rptr_gray'ascending
      report "is_gray_full requires unsigned(N downto 0) pointers"
      severity failure;
    if C_W <= 2 then
      return wptr_gray = not rptr_gray;
    else
      return (wptr_gray(wptr_gray'high downto wptr_gray'high - 1) =
              not rptr_gray(rptr_gray'high downto rptr_gray'high - 1)) and
             (wptr_gray(wptr_gray'high - 2 downto wptr_gray'low) =
              rptr_gray(rptr_gray'high - 2 downto rptr_gray'low));
    end if;
  end function;

  -- Empty condition detection for Gray-coded pointers.
  -- Empty is just both pointers at the same Gray value.
  function is_gray_empty (wptr_gray, rptr_gray : unsigned) return boolean is
  begin
    assert wptr_gray'length = rptr_gray'length
      report "is_gray_empty requires equal-width Gray pointers"
      severity failure;
    assert wptr_gray'length > 0
      report "is_gray_empty requires non-null Gray pointers"
      severity failure;
    assert not wptr_gray'ascending and not rptr_gray'ascending
      report "is_gray_empty requires unsigned(N downto 0) pointers"
      severity failure;
    return wptr_gray = rptr_gray;
  end function;

  -- Predicate: is n a power of two? Divides down, checking each step
  -- for an odd remainder. 1 is a power of two (2**0).
  function is_power_of_two (n : positive) return boolean is
    variable v : natural := n;
  begin
    if v = 1 then
      return true;
    end if;
    while v > 1 loop
      if (v mod 2) = 1 then
        return false;
      end if;
      v := v / 2;
    end loop;
    return true;
  end function;

  -- Boolean to std_logic: true -> '1', false -> '0'.
  -- Note: uses if/else rather than a conditional expression because
  -- ModelSim (and some other tools) do not accept conditional
  -- expressions directly in return statements.
  function to_std_logic (b : boolean) return std_logic is
  begin
    if b then
      return '1';
    else
      return '0';
    end if;
  end function;

  -- Two-input mux on unsigned. Selects a when cond is true, else b.
  -- if/else form (see to_std_logic note re: return statements).
  function sel (cond : boolean; a, b : unsigned) return unsigned is
  begin
    if cond then
      return a;
    else
      return b;
    end if;
  end function;

  -- Two-input mux on std_logic_vector. Selects a when cond is true, else b.
  function sel (cond : boolean; a, b : std_logic_vector) return std_logic_vector is
  begin
    if cond then
      return a;
    else
      return b;
    end if;
  end function;

  -- Integer division rounded up. (a - 1) / b + 1 avoids the overflow
  -- risk of (a + b - 1) / b when a + b - 1 exceeds positive'high.
  function ceil_div (a : natural; b : positive) return natural is
  begin
    if a = 0 then
      return 0;
    end if;
    return (a - 1) / b + 1;
  end function;

  -- Population count: number of '1' bits in v. Uses v'range so it
  -- works on both ascending and descending slices. Unknown values are
  -- intentionally ignored; see the package declaration for the contract.
  function count_ones (v : std_logic_vector) return natural is
    variable cnt : natural := 0;
  begin
    for i in v'range loop
      if v(i) = '1' then
        cnt := cnt + 1;
      end if;
    end loop;
    return cnt;
  end function;

end package body;
