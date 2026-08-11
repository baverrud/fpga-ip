-----------------------------------------------------------------------
--Filename         : util_pkg_tb.vhd
--Description      : Regression testbench for shared util_pkg helpers.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity util_pkg_tb is
end entity;

architecture test of util_pkg_tb is
begin
  p_test : process
    variable r2, w2          : unsigned(1 downto 0);
    variable b2, g2, next_g2 : unsigned(1 downto 0);
    variable b3, g3, next_g3 : unsigned(2 downto 0);
    variable b4, g4, next_g4 : unsigned(3 downto 0);
    variable b5, g5, next_g5 : unsigned(4 downto 0);
    variable r3, w3          : unsigned(2 downto 0);
    variable r4, w4          : unsigned(3 downto 0);
    variable u_a, u_b       : unsigned(3 downto 0);
    variable v_a, v_b       : std_logic_vector(3 downto 0);
  begin
    -- Check every Gray-code round-trip for four representative widths.
    for k in 0 to 3 loop
      b2 := to_unsigned(k, b2'length);
      g2 := bin2gray(b2);
      assert gray2bin(g2) = b2 report "2-bit Gray round-trip failed" severity failure;
      if k < 3 then
        next_g2 := bin2gray(to_unsigned(k + 1, b2'length));
        assert count_ones(std_logic_vector(g2 xor next_g2)) = 1
          report "2-bit Gray transition changed more than one bit" severity failure;
      end if;
    end loop;

    for k in 0 to 7 loop
      b3 := to_unsigned(k, b3'length);
      g3 := bin2gray(b3);
      assert gray2bin(g3) = b3 report "3-bit Gray round-trip failed" severity failure;
      if k < 7 then
        next_g3 := bin2gray(to_unsigned(k + 1, b3'length));
        assert count_ones(std_logic_vector(g3 xor next_g3)) = 1
          report "3-bit Gray transition changed more than one bit" severity failure;
      end if;
    end loop;

    for k in 0 to 15 loop
      b4 := to_unsigned(k, b4'length);
      g4 := bin2gray(b4);
      assert gray2bin(g4) = b4 report "4-bit Gray round-trip failed" severity failure;
      if k < 15 then
        next_g4 := bin2gray(to_unsigned(k + 1, b4'length));
        assert count_ones(std_logic_vector(g4 xor next_g4)) = 1
          report "4-bit Gray transition changed more than one bit" severity failure;
      end if;
    end loop;

    for k in 0 to 31 loop
      b5 := to_unsigned(k, b5'length);
      g5 := bin2gray(b5);
      assert gray2bin(g5) = b5 report "5-bit Gray round-trip failed" severity failure;
      if k < 31 then
        next_g5 := bin2gray(to_unsigned(k + 1, b5'length));
        assert count_ones(std_logic_vector(g5 xor next_g5)) = 1
          report "5-bit Gray transition changed more than one bit" severity failure;
      end if;
    end loop;

    -- Depth 2: two-bit pointers use the inverted-pointer full rule.
    r2 := "00";
    w2 := "11";
    assert is_gray_full(w2, r2) report "2-deep full was not detected" severity failure;
    w2 := "01";
    assert not is_gray_full(w2, r2) report "2-deep false full" severity failure;

    -- Depth 4: full is four binary increments beyond the read pointer.
    r3 := bin2gray(to_unsigned(1, r3'length));
    w3 := bin2gray(to_unsigned(5, w3'length));
    assert is_gray_full(w3, r3) report "4-deep full with nonzero read pointer" severity failure;
    assert not is_gray_empty(w3, r3) report "4-deep false empty" severity failure;

    -- Depth 8: repeat the nonzero read-pointer full check at a wider size.
    r4 := bin2gray(to_unsigned(3, r4'length));
    w4 := bin2gray(to_unsigned(11, w4'length));
    assert is_gray_full(w4, r4) report "8-deep full with nonzero read pointer" severity failure;
    assert is_gray_empty(r4, r4) report "Gray empty was not detected" severity failure;

    -- Generic validation and scalar helpers.
    assert is_power_of_two(1) report "1 must be a power of two" severity failure;
    assert is_power_of_two(16) report "16 must be a power of two" severity failure;
    assert not is_power_of_two(6) report "6 must not be a power of two" severity failure;
    assert to_std_logic(true) = '1' report "true conversion failed" severity failure;
    assert to_std_logic(false) = '0' report "false conversion failed" severity failure;

    u_a := "1010";
    u_b := "0101";
    assert sel(true, u_a, u_b) = u_a report "unsigned true select failed" severity failure;
    assert sel(false, u_a, u_b) = u_b report "unsigned false select failed" severity failure;
    v_a := "1100";
    v_b := "0011";
    assert sel(true, v_a, v_b) = v_a report "vector true select failed" severity failure;
    assert sel(false, v_a, v_b) = v_b report "vector false select failed" severity failure;

    -- Zero is a valid transfer count; unknown bits are intentionally ignored.
    assert ceil_div(0, 4) = 0 report "ceil_div zero numerator failed" severity failure;
    assert ceil_div(1, 4) = 1 report "ceil_div 1/4 failed" severity failure;
    assert ceil_div(5, 2) = 3 report "ceil_div 5/2 failed" severity failure;
    assert count_ones("1011") = 3 report "count_ones known bits failed" severity failure;
    assert count_ones("1XUZ") = 1 report "count_ones unknown-bit contract failed" severity failure;

    report "ALL UTIL_PKG CHECKS PASSED";
    wait;
  end process;
end architecture;
