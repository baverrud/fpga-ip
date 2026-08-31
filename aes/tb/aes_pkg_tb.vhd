-----------------------------------------------------------------------
--Filename         : aes_pkg_tb.vhd
--Description      : Unit testbench for the AES transformation package.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;
use std.textio.all;
use work.aes_pkg.all;

entity aes_pkg_tb is
end entity;

architecture sim of aes_pkg_tb is

  constant C_PLAINTEXT : aes_block_t := x"00112233445566778899aabbccddeeff";
  constant C_KEY_128   : std_logic_vector(127 downto 0) :=
    x"000102030405060708090a0b0c0d0e0f";
  constant C_KEY_192   : std_logic_vector(191 downto 0) :=
    x"000102030405060708090a0b0c0d0e0f1011121314151617";
  constant C_KEY_256   : std_logic_vector(255 downto 0) :=
    x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

  procedure check_vector(
    constant name     : in string;
    constant got      : in std_logic_vector;
    constant expected : in std_logic_vector
  ) is
  begin
    assert got = expected
      report "FAIL: " & name & " got " & to_hstring(got) &
             " expected " & to_hstring(expected) severity failure;
    report "PASS: " & name severity note;
  end procedure;

  procedure check_bool(
    constant name : in string;
    constant got  : in boolean
  ) is
  begin
    assert got report "FAIL: " & name severity failure;
    report "PASS: " & name severity note;
  end procedure;

begin

  p_test : process
    variable l                : line;
    variable value            : aes_byte_t;
    variable state            : aes_state_t;
    variable transformed      : aes_state_t;
    variable schedule         : aes_key_schedule_t;
    variable ascending_key    : std_logic_vector(0 to 127);
    variable ascending_schedule : aes_key_schedule_t;
  begin
    check_bool("AES-128 Nk", aes_key_words(128) = 4);
    check_bool("AES-192 Nk", aes_key_words(192) = 6);
    check_bool("AES-256 Nk", aes_key_words(256) = 8);
    check_bool("AES-128 Nr", aes_rounds(128) = 10);
    check_bool("AES-192 Nr", aes_rounds(192) = 12);
    check_bool("AES-256 Nr", aes_rounds(256) = 14);

    check_vector("state round trip", aes_state_to_block(aes_block_to_state(C_PLAINTEXT)),
                 C_PLAINTEXT);

    for index in 0 to 255 loop
      value := std_logic_vector(to_unsigned(index, value'length));
      assert aes_inv_sbox(aes_sbox(value)) = value
        report "FAIL: S-box inverse at " & to_hstring(value) severity failure;
      assert aes_sbox(aes_inv_sbox(value)) = value
        report "FAIL: inverse S-box inverse at " & to_hstring(value) severity failure;
    end loop;
    report "PASS: all S-box inverse pairs" severity note;

    check_vector("SBOX(53)", aes_sbox(x"53"), x"ed");
    check_vector("INV_SBOX(ed)", aes_inv_sbox(x"ed"), x"53");
    check_vector("XTIMES(57)", aes_xtime(x"57"), x"ae");
    check_vector("XTIMES(83)", aes_xtime(x"83"), x"1d");
    check_vector("GF_MUL(57,13)", aes_gf_mul(x"57", x"13"), x"fe");

    state := aes_block_to_state(x"00102030405060708090a0b0c0d0e0f0");
    transformed := aes_sub_bytes(state);
    check_vector("SUBBYTES round 1", aes_state_to_block(transformed),
                 x"63cab7040953d051cd60e0e7ba70e18c");
    check_vector("INVSUBBYTES round trip",
                 aes_state_to_block(aes_inv_sub_bytes(transformed)),
                 x"00102030405060708090a0b0c0d0e0f0");

    transformed := aes_shift_rows(transformed);
    check_vector("SHIFTROWS round 1", aes_state_to_block(transformed),
                 x"6353e08c0960e104cd70b751bacad0e7");
    check_vector("INVSHIFTROWS round trip",
                 aes_state_to_block(aes_inv_shift_rows(transformed)),
                 x"63cab7040953d051cd60e0e7ba70e18c");

    transformed := aes_mix_columns(transformed);
    check_vector("MIXCOLUMNS round 1", aes_state_to_block(transformed),
                 x"5f72641557f5bc92f7be3b291db9f91a");
    check_vector("INVMIXCOLUMNS round trip",
                 aes_state_to_block(aes_inv_mix_columns(transformed)),
                 x"6353e08c0960e104cd70b751bacad0e7");

    check_vector("ROTWORD", aes_rot_word(x"09cf4f3c"), x"cf4f3c09");
    check_vector("SUBWORD", aes_sub_word(x"cf4f3c09"), x"8a84eb01");
    check_vector("RCON(1)", aes_rcon(1), x"01000000");
    check_vector("RCON(10)", aes_rcon(10), x"36000000");

    schedule := aes_expand_key(C_KEY_128, 128);
    check_vector("AES-128 key word 4", schedule(4), x"d6aa74fd");
    check_vector("AES-128 key word 43", schedule(43), x"4d2b30c5");
    check_vector("ADDROUNDKEY round 1",
                 aes_state_to_block(aes_add_round_key(transformed, schedule, 1)),
                 x"89d810e8855ace682d1843d8cb128fe4");
    check_vector("AES-128 cipher",
                 aes_cipher(C_PLAINTEXT, schedule, 128),
                 x"69c4e0d86a7b0430d8cdb78070b4c55a");
    check_vector("AES-128 inverse cipher",
                 aes_inv_cipher(x"69c4e0d86a7b0430d8cdb78070b4c55a", schedule, 128),
                 C_PLAINTEXT);

    ascending_key := C_KEY_128;
    ascending_schedule := aes_expand_key(ascending_key, 128);
    check_vector("ascending key range", ascending_schedule(43), schedule(43));

    schedule := aes_expand_key(C_KEY_192, 192);
    check_vector("AES-192 key word 51", schedule(51), x"e3a41d5d");
    check_vector("AES-192 cipher",
                 aes_cipher(C_PLAINTEXT, schedule, 192),
                 x"dda97ca4864cdfe06eaf70a0ec0d7191");
    check_vector("AES-192 inverse cipher",
                 aes_inv_cipher(x"dda97ca4864cdfe06eaf70a0ec0d7191", schedule, 192),
                 C_PLAINTEXT);

    schedule := aes_expand_key(C_KEY_256, 256);
    check_vector("AES-256 key word 59", schedule(59), x"6d68de36");
    check_vector("AES-256 cipher",
                 aes_cipher(C_PLAINTEXT, schedule, 256),
                 x"8ea2b7ca516745bfeafc49904b496089");
    check_vector("AES-256 inverse cipher",
                 aes_inv_cipher(x"8ea2b7ca516745bfeafc49904b496089", schedule, 256),
                 C_PLAINTEXT);

    write(l, string'("All AES package tests passed."));
    writeline(output, l);
    wait;
  end process;

end architecture;
