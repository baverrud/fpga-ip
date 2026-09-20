-----------------------------------------------------------------------
--Filename         : mem_image_pkg.vhd
--Description      : Types and Intel HEX parsing for file-backed memory
--                 : images used by mem_image.
--                 :
--                 : An image is a set of disjoint byte-address ranges
--                 : ("regions").  How many there are and how large they
--                 : are comes from the image file, not from generics.
--                 :
--                 : Intel HEX (the common byte-addressed hex format):
--                 :   :LLAAAATT[DD..]CC
--                 :     LL   = payload byte count
--                 :     AAAA = 16-bit address, big endian
--                 :     TT   = 00 data, 01 EOF, 02 ext. segment,
--                 :            03 start segment, 04 ext. linear address,
--                 :            05 start linear address
--                 :     DD   = payload
--                 :     CC   = two's complement of the byte sum
--                 : Type 02/04 records reposition the address; 03/05 are
--                 : ignored (they carry a start address we do not use).
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package mem_image_pkg is

  -- Backing store granularity.  The image is byte addressed, but stored as
  -- 32-bit words: 4x fewer array objects than a byte array, and any bus
  -- width is assembled from byte lanes of those words.
  constant C_WORD_BYTES : positive := 4;

  subtype byte_t      is std_logic_vector(7 downto 0);
  subtype word_t      is std_logic_vector(31 downto 0);
  subtype byte_addr_t is unsigned(63 downto 0);

  type byte_array_t is array (natural range <>) of byte_t;
  type word_array_t is array (natural range <>) of word_t;

  -- Cleared word, used to initialise and to fill image storage.
  constant C_WORD_ZERO : word_t := (others => '0');

  -- An address range as read from the image.
  type extent_t is record
    lo : byte_addr_t;             -- first byte address covered
    hi : byte_addr_t;             -- last byte address covered
  end record;

  constant C_EXTENT_EMPTY : extent_t :=
    (lo => (others => '0'), hi => (others => '0'));

  type extent_array_t is array (natural range <>) of extent_t;

  -- Decoded Intel HEX record.
  type hex_rec_t is record
    valid : boolean;                     -- start byte, fields and sum are OK
    rtype : natural;                     -- 0..5
    addr  : byte_addr_t;                 -- absolute address (rtype 0)
    count : natural;                     -- payload bytes (rtype 0)
    data  : byte_array_t(0 to 255);
  end record;

  -- Value of one hex digit, or -1 when the character is not a hex digit.
  function hex_value(c : character) return integer;

  -- Two hex digits at s(pos) and s(pos+1) as a byte value, or -1 when the
  -- position is out of range or either digit is invalid.
  function hex_pair(s : string; pos : natural) return integer;

  -- Decode one Intel HEX record.  line must start at index 1 with ':'
  -- (already stripped of any trailing CR/whitespace).  upper carries the
  -- extended address across records: it is updated by type 02/04 records
  -- (whose value lives in the payload) and used to form rec.addr for
  -- type 00 records.
  procedure parse_hex_record(
    constant line  : in    string;
    variable upper : inout byte_addr_t;
    variable rec   : out   hex_rec_t);

end package;

package body mem_image_pkg is

  function hex_value(c : character) return integer is
  begin
    case c is
      when '0' to '9' => return character'pos(c) - character'pos('0');
      when 'A' to 'F' => return character'pos(c) - character'pos('A') + 10;
      when 'a' to 'f' => return character'pos(c) - character'pos('a') + 10;
      when others     => return -1;
    end case;
  end function;

  function hex_pair(s : string; pos : natural) return integer is
    variable v_hi : integer;
    variable v_lo : integer;
  begin
    if pos < s'left or pos + 1 > s'right then
      return -1;
    end if;
    v_hi := hex_value(s(pos));
    v_lo := hex_value(s(pos + 1));
    if v_hi < 0 or v_lo < 0 then
      return -1;
    end if;
    return v_hi * 16 + v_lo;
  end function;

  procedure parse_hex_record(
    constant line  : in    string;
    variable upper : inout byte_addr_t;
    variable rec   : out   hex_rec_t) is

    variable v_count  : integer;
    variable v_addr   : integer;
    variable v_addr_hi : integer;
    variable v_addr_lo : integer;
    variable v_type   : integer;
    variable v_byte   : integer;
    variable v_sum    : integer;
    variable v_upval  : integer;
  begin
    rec.valid := false;
    rec.rtype := 0;
    rec.addr  := (others => '0');
    rec.count := 0;
    rec.data  := (others => (others => '0'));

    -- Shortest legal record is ":00000001FF".
    if line'length < 11 then
      return;
    end if;
    if line(line'left) /= ':' then
      return;
    end if;

    v_count   := hex_pair(line, line'left + 1);
    v_addr_hi := hex_pair(line, line'left + 3);
    v_addr_lo := hex_pair(line, line'left + 5);
    v_type    := hex_pair(line, line'left + 7);
    if v_count < 0 or v_addr_hi < 0 or v_addr_lo < 0 or v_type < 0 then
      return;
    end if;
    -- AAAA is a 16 bit big endian address.
    v_addr := v_addr_hi * 256 + v_addr_lo;

    -- Expected length: ':' + LL + AAAA + TT + payload + CC.
    if line'length /= 11 + 2 * v_count then
      return;
    end if;

    v_sum := v_count + (v_addr / 256) + (v_addr mod 256) + v_type;
    for i in 0 to v_count - 1 loop
      v_byte := hex_pair(line, line'left + 9 + 2 * i);
      if v_byte < 0 then
        return;
      end if;
      rec.data(i) := std_logic_vector(to_unsigned(v_byte, 8));
      v_sum := v_sum + v_byte;
    end loop;

    v_byte := hex_pair(line, line'left + 9 + 2 * v_count);
    if v_byte < 0 then
      return;
    end if;
    v_sum := v_sum + v_byte;
    if (v_sum mod 256) /= 0 then
      return;                          -- checksum mismatch
    end if;

    rec.rtype := v_type;
    rec.count := v_count;

    case v_type is
      when 0 =>
        rec.addr := upper + to_unsigned(v_addr, 64);
      when 2 | 4 =>
        -- The address field of these records is zero: the upper address
        -- is carried in the 16 bit big endian payload instead.
        if v_count /= 2 then
          rec.valid := false;
          return;
        end if;
        v_upval := to_integer(unsigned(rec.data(0))) * 256 +
                   to_integer(unsigned(rec.data(1)));
        if v_type = 2 then
          -- Extended segment address: (SSSS << 4)
          upper := shift_left(to_unsigned(v_upval, 64), 4);
        else
          -- Extended linear address: (UUUU << 16)
          upper := shift_left(to_unsigned(v_upval, 64), 16);
        end if;
      when others =>
        null;                          -- 01 EOF, 03/05 start address
    end case;

    rec.valid := true;
  end procedure;

end package body;
