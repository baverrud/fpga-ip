-----------------------------------------------------------------------
--Filename         : util_pkg.vhd
--Description      : Shared utility package for fpga-ip cores.
--                 : Provides log2ceil and common array types.
--Author           : Rune Bæverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package util_pkg is

  -- Generic array of std_logic_vectors, each element arbitrarily wide.
  -- Signal declaration example:
  --   signal my_sig : t_slv_array(0 to 7)(31 downto 0);  -- 8× 32-bit
  type t_slv_array is array(natural range <>) of std_logic_vector;

  -- Convenience subtype: array of 32-bit words.
  subtype t_slv32_array is t_slv_array(open)(31 downto 0);

  -----------------------------------------------------------------------
  -- log2ceil:
  -- Returns number of bits required to represent arg positive values.
  -- Uses division instead of multiplication to avoid any temporary
  -- integer overflow limits up to positive'high (2147483647).
  -----------------------------------------------------------------------
  function log2ceil (arg : positive) return natural;

end package;

package body util_pkg is

  function log2ceil (arg : positive) return natural is
    variable tmp : natural;
    variable log : natural;
  begin
    tmp := arg - 1;
    log := 0;
    while tmp > 0 loop
      tmp := tmp / 2;
      log := log + 1;
    end loop;
    return log;
  end function;

end package body;
