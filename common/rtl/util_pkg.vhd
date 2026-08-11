-----------------------------------------------------------------------
--Filename         : util_pkg.vhd
--Description      : Shared utility package for fpga-ip cores.
--                 : Provides log2ceil and common array types (VHDL-2008).
--Author           : Rune Baeverrud
--Current Revision : 1.00
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
  -- Returns number of bits required to represent arg positive values.
  -- Uses division instead of multiplication to avoid any temporary
  -- integer overflow limits up to positive'high (2147483647).
  -----------------------------------------------------------------------
  function log2ceil (val : positive) return natural;

  -----------------------------------------------------------------------
  -- bin2gray / check_full: Gray-code pointer helpers for asynchronous
  -- FIFO / CDC designs (single-bit-crossing pointer transfer).
  -----------------------------------------------------------------------
  function bin2gray (bin : unsigned) return unsigned;
  function check_full (wptr_gray, rptr_gray : unsigned) return boolean;

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
    return bin xor ('0' & bin(bin'high downto 1));
  end function;

  -- Full condition detection for Gray-coded pointers.
  -- Full occurs when the top two MSBs are inverted and the lower bits match.
  function check_full (wptr_gray, rptr_gray : unsigned) return boolean is
    constant C_W : integer := wptr_gray'length;
  begin
    if C_W <= 2 then
      return wptr_gray = not rptr_gray;
    else
      return (wptr_gray(C_W-1 downto C_W-2) = not rptr_gray(C_W-1 downto C_W-2)) and
             (wptr_gray(C_W-3 downto 0) = rptr_gray(C_W-3 downto 0));
    end if;
  end function;

end package body;
