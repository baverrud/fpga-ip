-----------------------------------------------------------------------
--Filename         : aes_pkg.vhd
--Description      : AES-128, AES-192, and AES-256 transformation package.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

package aes_pkg is

  -- AES always processes a 128-bit block arranged as four 32-bit columns.
  -- Key width changes Nk (input key words) and Nr (cipher rounds), not the
  -- state dimensions.
  constant C_AES_BLOCK_BITS    : positive := 128;
  constant C_AES_BYTE_BITS     : positive := 8;
  constant C_AES_WORD_BITS     : positive := 32;
  constant C_AES_NB            : positive := 4;
  constant C_AES_MAX_KEY_WORDS : positive := 60;

  subtype aes_byte_t  is std_logic_vector(C_AES_BYTE_BITS - 1 downto 0);
  subtype aes_word_t  is std_logic_vector(C_AES_WORD_BITS - 1 downto 0);
  subtype aes_block_t is std_logic_vector(C_AES_BLOCK_BITS - 1 downto 0);

  -- State indexing follows FIPS 197: state(row, column). Serialized blocks
  -- are column-major, with block_data(127 downto 120) at state(0, 0).
  type aes_state_t is array (0 to 3, 0 to 3) of aes_byte_t;

  -- Sixty words accommodate the largest AES-256 schedule: 4 * (14 + 1).
  -- Unused tail words are zero for the shorter key variants.
  type aes_key_schedule_t is array (0 to C_AES_MAX_KEY_WORDS - 1) of aes_word_t;

  -- Parameter helpers: Nk is 4/6/8 and Nr is 10/12/14.
  function aes_key_words(key_bits : positive) return positive;
  function aes_rounds(key_bits : positive) return positive;

  -- Convert between the external big-endian block vector and FIPS state.
  function aes_block_to_state(block_data : aes_block_t) return aes_state_t;
  function aes_state_to_block(state : aes_state_t) return aes_block_t;

  -- Primitive byte operations and substitution tables.
  function aes_sbox(value : aes_byte_t) return aes_byte_t;
  function aes_inv_sbox(value : aes_byte_t) return aes_byte_t;
  function aes_xtime(value : aes_byte_t) return aes_byte_t;
  function aes_gf_mul(left : aes_byte_t; right : aes_byte_t) return aes_byte_t;

  -- Forward and inverse state transformations. AddRoundKey is its own
  -- inverse because it is a bitwise XOR with the selected round key.
  function aes_sub_bytes(state : aes_state_t) return aes_state_t;
  function aes_inv_sub_bytes(state : aes_state_t) return aes_state_t;
  function aes_shift_rows(state : aes_state_t) return aes_state_t;
  function aes_inv_shift_rows(state : aes_state_t) return aes_state_t;
  function aes_mix_columns(state : aes_state_t) return aes_state_t;
  function aes_inv_mix_columns(state : aes_state_t) return aes_state_t;
  function aes_add_round_key(
    state        : aes_state_t;
    key_schedule : aes_key_schedule_t;
    round        : natural
  ) return aes_state_t;

  -- Key-schedule operations defined by FIPS 197 section 5.2.
  function aes_rot_word(word : aes_word_t) return aes_word_t;
  function aes_sub_word(word : aes_word_t) return aes_word_t;
  function aes_rcon(index : positive) return aes_word_t;
  function aes_expand_key(
    key      : std_logic_vector;
    key_bits : positive
  ) return aes_key_schedule_t;

  -- Combinational reference cipher functions. These are useful for package
  -- tests and constant evaluation; aes.vhd implements the clocked stream IP.
  function aes_cipher(
    input_block  : aes_block_t;
    key_schedule : aes_key_schedule_t;
    key_bits     : positive
  ) return aes_block_t;

  function aes_inv_cipher(
    input_block  : aes_block_t;
    key_schedule : aes_key_schedule_t;
    key_bits     : positive
  ) return aes_block_t;

end package;

package body aes_pkg is

  -- S-box tables are stored as hexadecimal text to keep the source compact
  -- and auditable against FIPS 197. Each pair of characters encodes one byte;
  -- aes_table_byte converts a table entry on demand.
  constant C_SBOX_HEX : string :=
    "637c777bf26b6fc53001672bfed7ab76" &
    "ca82c97dfa5947f0add4a2af9ca472c0" &
    "b7fd9326363ff7cc34a5e5f171d83115" &
    "04c723c31896059a071280e2eb27b275" &
    "09832c1a1b6e5aa0523bd6b329e32f84" &
    "53d100ed20fcb15b6acbbe394a4c58cf" &
    "d0efaafb434d338545f9027f503c9fa8" &
    "51a3408f929d38f5bcb6da2110fff3d2" &
    "cd0c13ec5f974417c4a77e3d645d1973" &
    "60814fdc222a908846eeb814de5e0bdb" &
    "e0323a0a4906245cc2d3ac629195e479" &
    "e7c8376d8dd54ea96c56f4ea657aae08" &
    "ba78252e1ca6b4c6e8dd741f4bbd8b8a" &
    "703eb5664803f60e613557b986c11d9e" &
    "e1f8981169d98e949b1e87e9ce5528df" &
    "8ca1890dbfe6426841992d0fb054bb16";

  constant C_INV_SBOX_HEX : string :=
    "52096ad53036a538bf40a39e81f3d7fb" &
    "7ce339829b2fff87348e4344c4dee9cb" &
    "547b9432a6c2233dee4c950b42fac34e" &
    "082ea16628d924b2765ba2496d8bd125" &
    "72f8f66486689816d4a45ccc5d65b692" &
    "6c704850fdedb9da5e154657a78d9d84" &
    "90d8ab008cbcd30af7e45805b8b34506" &
    "d02c1e8fca3f0f02c1afbd0301138a6b" &
    "3a9111414f67dcea97f2cfcef0b4e673" &
    "96ac7422e7ad3585e2f937e81c75df6e" &
    "47f11a711d29c5896fb7620eaa18be1b" &
    "fc563e4bc6d279209adbc0fe78cd5af4" &
    "1fdda8338807c731b11210592780ec5f" &
    "60517fa919b54a0d2de57a9f93c99cef" &
    "a0e03b4dae2af5b0c8ebbb3c83539961" &
    "172b047eba77d626e169146355210c7d";

  function aes_hex_value(value : character) return natural is
  begin
    case value is
      when '0' => return 0;
      when '1' => return 1;
      when '2' => return 2;
      when '3' => return 3;
      when '4' => return 4;
      when '5' => return 5;
      when '6' => return 6;
      when '7' => return 7;
      when '8' => return 8;
      when '9' => return 9;
      when 'a' | 'A' => return 10;
      when 'b' | 'B' => return 11;
      when 'c' | 'C' => return 12;
      when 'd' | 'D' => return 13;
      when 'e' | 'E' => return 14;
      when 'f' | 'F' => return 15;
      when others =>
        assert false report "Invalid AES hexadecimal table character" severity failure;
        return 0;
    end case;
  end function;

  function aes_table_byte(table : string; index : natural) return aes_byte_t is
    variable table_index : natural;
  begin
    table_index := 2 * index + table'low;
    return std_logic_vector(to_unsigned(
      16 * aes_hex_value(table(table_index)) + aes_hex_value(table(table_index + 1)), 8));
  end function;

  function aes_key_words(key_bits : positive) return positive is
  begin
    assert key_bits = 128 or key_bits = 192 or key_bits = 256
      report "AES key_bits must be 128, 192, or 256" severity failure;
    return key_bits / C_AES_WORD_BITS;
  end function;

  function aes_rounds(key_bits : positive) return positive is
  begin
    assert key_bits = 128 or key_bits = 192 or key_bits = 256
      report "AES key_bits must be 128, 192, or 256" severity failure;
    return (key_bits / C_AES_WORD_BITS) + 6;
  end function;

  function aes_block_to_state(block_data : aes_block_t) return aes_state_t is
    variable state : aes_state_t;
  begin
    -- The byte at serialized index 4*column+row maps to state(row,column).
    for column in 0 to 3 loop
      for row in 0 to 3 loop
        state(row, column) := block_data(127 - 8 * (row + 4 * column) downto
                                         120 - 8 * (row + 4 * column));
      end loop;
    end loop;
    return state;
  end function;

  function aes_state_to_block(state : aes_state_t) return aes_block_t is
    variable block_data : aes_block_t;
  begin
    for column in 0 to 3 loop
      for row in 0 to 3 loop
        block_data(127 - 8 * (row + 4 * column) downto
                   120 - 8 * (row + 4 * column)) := state(row, column);
      end loop;
    end loop;
    return block_data;
  end function;

  function aes_sbox(value : aes_byte_t) return aes_byte_t is
  begin
    return aes_table_byte(C_SBOX_HEX, to_integer(unsigned(value)));
  end function;

  function aes_inv_sbox(value : aes_byte_t) return aes_byte_t is
  begin
    return aes_table_byte(C_INV_SBOX_HEX, to_integer(unsigned(value)));
  end function;

  function aes_xtime(value : aes_byte_t) return aes_byte_t is
    variable result : unsigned(7 downto 0);
  begin
    -- Multiply by x in GF(2^8). If the old MSB was set, reduce modulo the
    -- AES irreducible polynomial x^8+x^4+x^3+x+1 (low byte 0x1b).
    result := shift_left(unsigned(value), 1);
    if value(7) = '1' then
      result := result xor to_unsigned(16#1b#, 8);
    end if;
    return std_logic_vector(result);
  end function;

  function aes_gf_mul(left : aes_byte_t; right : aes_byte_t) return aes_byte_t is
    variable a       : aes_byte_t := left;
    variable b       : aes_byte_t := right;
    variable product : aes_byte_t := (others => '0');
  begin
    -- Shift-and-add multiplication in GF(2^8). XOR is field addition;
    -- aes_xtime supplies the reduced multiply-by-two operation.
    for bit_index in 0 to 7 loop
      if b(0) = '1' then
        product := product xor a;
      end if;
      a := aes_xtime(a);
      b := std_logic_vector(shift_right(unsigned(b), 1));
    end loop;
    return product;
  end function;

  function aes_sub_bytes(state : aes_state_t) return aes_state_t is
    variable result : aes_state_t;
  begin
    for row in 0 to 3 loop
      for column in 0 to 3 loop
        result(row, column) := aes_sbox(state(row, column));
      end loop;
    end loop;
    return result;
  end function;

  function aes_inv_sub_bytes(state : aes_state_t) return aes_state_t is
    variable result : aes_state_t;
  begin
    for row in 0 to 3 loop
      for column in 0 to 3 loop
        result(row, column) := aes_inv_sbox(state(row, column));
      end loop;
    end loop;
    return result;
  end function;

  function aes_shift_rows(state : aes_state_t) return aes_state_t is
    variable result : aes_state_t;
  begin
    -- Row r is rotated left by r byte positions.
    for row in 0 to 3 loop
      for column in 0 to 3 loop
        result(row, column) := state(row, (column + row) mod 4);
      end loop;
    end loop;
    return result;
  end function;

  function aes_inv_shift_rows(state : aes_state_t) return aes_state_t is
    variable result : aes_state_t;
  begin
    -- Inverse ShiftRows rotates row r right by r byte positions.
    for row in 0 to 3 loop
      for column in 0 to 3 loop
        result(row, column) := state(row, (column + 4 - row) mod 4);
      end loop;
    end loop;
    return result;
  end function;

  function aes_mix_columns(state : aes_state_t) return aes_state_t is
    variable result : aes_state_t;
    variable s0     : aes_byte_t;
    variable s1     : aes_byte_t;
    variable s2     : aes_byte_t;
    variable s3     : aes_byte_t;
  begin
    -- Multiply each state column by the fixed forward-cipher matrix over
    -- GF(2^8), using coefficients 01, 02, and 03.
    for column in 0 to 3 loop
      s0 := state(0, column);
      s1 := state(1, column);
      s2 := state(2, column);
      s3 := state(3, column);
      result(0, column) := aes_gf_mul(x"02", s0) xor aes_gf_mul(x"03", s1) xor s2 xor s3;
      result(1, column) := s0 xor aes_gf_mul(x"02", s1) xor aes_gf_mul(x"03", s2) xor s3;
      result(2, column) := s0 xor s1 xor aes_gf_mul(x"02", s2) xor aes_gf_mul(x"03", s3);
      result(3, column) := aes_gf_mul(x"03", s0) xor s1 xor s2 xor aes_gf_mul(x"02", s3);
    end loop;
    return result;
  end function;

  function aes_inv_mix_columns(state : aes_state_t) return aes_state_t is
    variable result : aes_state_t;
    variable s0     : aes_byte_t;
    variable s1     : aes_byte_t;
    variable s2     : aes_byte_t;
    variable s3     : aes_byte_t;
  begin
    -- Multiply by the inverse matrix with coefficients 09, 0b, 0d, and 0e.
    for column in 0 to 3 loop
      s0 := state(0, column);
      s1 := state(1, column);
      s2 := state(2, column);
      s3 := state(3, column);
      result(0, column) := aes_gf_mul(x"0e", s0) xor aes_gf_mul(x"0b", s1) xor
                            aes_gf_mul(x"0d", s2) xor aes_gf_mul(x"09", s3);
      result(1, column) := aes_gf_mul(x"09", s0) xor aes_gf_mul(x"0e", s1) xor
                            aes_gf_mul(x"0b", s2) xor aes_gf_mul(x"0d", s3);
      result(2, column) := aes_gf_mul(x"0d", s0) xor aes_gf_mul(x"09", s1) xor
                            aes_gf_mul(x"0e", s2) xor aes_gf_mul(x"0b", s3);
      result(3, column) := aes_gf_mul(x"0b", s0) xor aes_gf_mul(x"0d", s1) xor
                            aes_gf_mul(x"09", s2) xor aes_gf_mul(x"0e", s3);
    end loop;
    return result;
  end function;

  function aes_add_round_key(
    state        : aes_state_t;
    key_schedule : aes_key_schedule_t;
    round        : natural
  ) return aes_state_t is
    variable result : aes_state_t;
  begin
    -- Four consecutive schedule words form one 128-bit round key. Word bytes
    -- map down a state column from row 0 (MSB) to row 3 (LSB).
    assert round <= 14 report "AES round index is out of range" severity failure;
    for column in 0 to 3 loop
      result(0, column) := state(0, column) xor key_schedule(4 * round + column)(31 downto 24);
      result(1, column) := state(1, column) xor key_schedule(4 * round + column)(23 downto 16);
      result(2, column) := state(2, column) xor key_schedule(4 * round + column)(15 downto 8);
      result(3, column) := state(3, column) xor key_schedule(4 * round + column)(7 downto 0);
    end loop;
    return result;
  end function;

  function aes_rot_word(word : aes_word_t) return aes_word_t is
  begin
    return word(23 downto 0) & word(31 downto 24);
  end function;

  function aes_sub_word(word : aes_word_t) return aes_word_t is
  begin
    return aes_sbox(word(31 downto 24)) & aes_sbox(word(23 downto 16)) &
           aes_sbox(word(15 downto 8)) & aes_sbox(word(7 downto 0));
  end function;

  function aes_rcon(index : positive) return aes_word_t is
    variable result : aes_byte_t := x"01";
  begin
    -- Rcon(i) is x^(i-1) in the most significant byte; the remaining three
    -- bytes are zero.
    assert index <= 10 report "AES round constant index is out of range" severity failure;
    for iteration in 2 to index loop
      result := aes_xtime(result);
    end loop;
    return result & x"000000";
  end function;

  function aes_expand_key(
    key      : std_logic_vector;
    key_bits : positive
  ) return aes_key_schedule_t is
    variable result : aes_key_schedule_t := (others => (others => '0'));
    variable nk     : positive;
    variable nr     : positive;
    variable total  : positive;
    variable temp   : aes_word_t;
    variable normalized_key : std_logic_vector(key_bits - 1 downto 0);
  begin
    assert key'length = key_bits
      report "AES key vector length does not match key_bits" severity failure;
    normalized_key := key;
    nk := aes_key_words(key_bits);
    nr := aes_rounds(key_bits);
    total := C_AES_NB * (nr + 1);

    -- Copy the original key into the first Nk words, most-significant word
    -- first, independent of the key vector's declared index direction.
    for index in 0 to nk - 1 loop
      result(index) := normalized_key(normalized_key'high - 32 * index downto
                                      normalized_key'high - 32 * index - 31);
    end loop;

    -- Expand until 4*(Nr+1) words are available. AES-256 has the additional
    -- SubWord branch at indices congruent to 4 modulo Nk.
    for index in nk to total - 1 loop
      temp := result(index - 1);
      if (index mod nk) = 0 then
        temp := aes_sub_word(aes_rot_word(temp)) xor aes_rcon(index / nk);
      elsif nk > 6 and (index mod nk) = 4 then
        temp := aes_sub_word(temp);
      end if;
      result(index) := result(index - nk) xor temp;
    end loop;
    return result;
  end function;

  function aes_cipher(
    input_block  : aes_block_t;
    key_schedule : aes_key_schedule_t;
    key_bits     : positive
  ) return aes_block_t is
    variable state : aes_state_t;
    constant nr    : positive := aes_rounds(key_bits);
  begin
    -- Initial key addition, Nr-1 full rounds, then the final round without
    -- MixColumns, exactly as specified by FIPS 197.
    state := aes_add_round_key(aes_block_to_state(input_block), key_schedule, 0);
    for round in 1 to nr - 1 loop
      state := aes_sub_bytes(state);
      state := aes_shift_rows(state);
      state := aes_mix_columns(state);
      state := aes_add_round_key(state, key_schedule, round);
    end loop;
    state := aes_sub_bytes(state);
    state := aes_shift_rows(state);
    state := aes_add_round_key(state, key_schedule, nr);
    return aes_state_to_block(state);
  end function;

  function aes_inv_cipher(
    input_block  : aes_block_t;
    key_schedule : aes_key_schedule_t;
    key_bits     : positive
  ) return aes_block_t is
    variable state : aes_state_t;
    variable round : natural;
    constant nr    : positive := aes_rounds(key_bits);
  begin
    -- Inverse cipher traverses round keys in reverse order and applies the
    -- inverse state transformations in their specified order.
    state := aes_add_round_key(aes_block_to_state(input_block), key_schedule, nr);
    for round_index in 1 to nr - 1 loop
      round := nr - round_index;
      state := aes_inv_shift_rows(state);
      state := aes_inv_sub_bytes(state);
      state := aes_add_round_key(state, key_schedule, round);
      state := aes_inv_mix_columns(state);
    end loop;
    state := aes_inv_shift_rows(state);
    state := aes_inv_sub_bytes(state);
    state := aes_add_round_key(state, key_schedule, 0);
    return aes_state_to_block(state);
  end function;

end package body;
