-----------------------------------------------------------------------
--Filename         : mem_image_examples_tb.vhd
--Description      : Testbench for mem_image that verifies every example
--                 : Intel HEX image shipped in tb/data.
--                 :
--                 : The point of this testbench is that the image files
--                 : are documentation, and documentation that is executed
--                 : cannot rot: each file is loaded and its bytes are
--                 : compared against the same byte map that is printed in
--                 : the README.  Regenerate the files with
--                 :   python tb/data/make_images.py
--                 :
--                 : Files covered:
--                 :   minimal_image.hex  one word at 0x0000
--                 :   ascii_image.hex    32 bytes of text at 0x1000
--                 :   hole_image.hex     region 0x10000..0x1001F, 8 byte hole
--                 :   seg_image.hex      same image, addressed with type 02
--                 :   partial_image.hex  unaligned 3 byte and 1 byte records
--                 :   two_regions.hex    regions at 0x00000 and 0x10000
--                 :
--                 : Every instance that has to tell a zone of zeros from a
--                 : miss uses GC_OUTSIDE = "poison", so a miss cannot pass
--                 : as "the byte happens to be zero".
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.mem_image_pkg.all;

entity mem_image_examples_tb is
  generic (
    GC_DIR : string := "axi_mem_image/tb/data/"
  );
end entity;

architecture sim of mem_image_examples_tb is

  constant C_AW : positive := 32;   -- address width
  constant C_W  : positive := 16;   -- wide read, bytes
  constant C_N  : positive := 4;    -- narrow read, bytes

  constant C_TEXT_BASE  : natural := 16#1000#;   -- ascii_image.hex
  constant C_HOLE_BASE  : natural := 16#10000#;  -- hole / seg image
  constant C_LO_REGION  : natural := 16#00000#;  -- two_regions.hex
  constant C_HI_REGION  : natural := 16#10000#;  -- two_regions.hex
  constant C_MID_TEXT   : string := "HELLO FROM A HEX";

  signal clk      : std_logic := '0';
  signal sim_done : boolean := false;

  -- minimal_image.hex
  signal a_min : std_logic_vector(C_AW-1 downto 0) := (others => '0');
  signal d_min : std_logic_vector(8*C_N-1 downto 0);
  signal h_min : std_logic;
  signal r_min : std_logic;

  -- Single-byte read of minimal_image.hex
  signal a_byte : std_logic_vector(C_AW-1 downto 0) := (others => '0');
  signal d_byte : std_logic_vector(7 downto 0);
  signal h_byte : std_logic;
  signal r_byte : std_logic;

  -- Empty image and non-multiple-of-four poison width
  signal a_empty5 : std_logic_vector(C_AW-1 downto 0) := (others => '0');
  signal d_empty5 : std_logic_vector(39 downto 0);
  signal h_empty5 : std_logic;
  signal r_empty5 : std_logic;

  -- Empty image and a second non-multiple-of-four poison width
  signal a_empty7 : std_logic_vector(C_AW-1 downto 0) := (others => '0');
  signal d_empty7 : std_logic_vector(55 downto 0);
  signal h_empty7 : std_logic;
  signal r_empty7 : std_logic;

  -- ascii_image.hex
  signal a_asc : std_logic_vector(C_AW-1 downto 0) := (others => '0');
  signal d_asc : std_logic_vector(8*C_W-1 downto 0);
  signal h_asc : std_logic;
  signal r_asc : std_logic;

  -- hole_image.hex
  signal a_hol : std_logic_vector(C_AW-1 downto 0) := (others => '0');
  signal d_hol : std_logic_vector(8*C_N-1 downto 0);
  signal h_hol : std_logic;
  signal r_hol : std_logic;

  -- seg_image.hex
  signal a_seg : std_logic_vector(C_AW-1 downto 0) := (others => '0');
  signal d_seg : std_logic_vector(8*C_N-1 downto 0);
  signal h_seg : std_logic;
  signal r_seg : std_logic;

  -- partial_image.hex
  signal a_par : std_logic_vector(C_AW-1 downto 0) := (others => '0');
  signal d_par : std_logic_vector(8*C_N-1 downto 0);
  signal h_par : std_logic;
  signal r_par : std_logic;

  -- two_regions.hex
  signal a_two : std_logic_vector(C_AW-1 downto 0) := (others => '0');
  signal d_two : std_logic_vector(8*C_N-1 downto 0);
  signal h_two : std_logic;
  signal r_two : std_logic;

begin

  clk <= not clk after 5 ns when not sim_done else '0';

  u_min : entity work.mem_image
    generic map (
      GC_DATA_BYTES => C_N, GC_ADDR_WIDTH => C_AW,
      GC_FILE => GC_DIR & "minimal_image.hex",
      GC_MAX_REGIONS => 1, GC_GAP_BYTES => 4096, GC_REGION_WORDS => 1,
      GC_OUTSIDE => "zero"
    )
    port map (read_en => '1', addr => a_min, data => d_min, hit => h_min,
              ready => r_min);

  u_byte : entity work.mem_image
    generic map (
      GC_DATA_BYTES => 1, GC_ADDR_WIDTH => C_AW,
      GC_FILE => GC_DIR & "minimal_image.hex",
      GC_MAX_REGIONS => 1, GC_GAP_BYTES => 4096, GC_REGION_WORDS => 1,
      GC_OUTSIDE => "zero"
    )
    port map (read_en => '1', addr => a_byte, data => d_byte, hit => h_byte,
              ready => r_byte);

  u_empty5 : entity work.mem_image
    generic map (
      GC_DATA_BYTES => 5, GC_ADDR_WIDTH => C_AW, GC_FILE => "",
      GC_MAX_REGIONS => 1, GC_GAP_BYTES => 4096, GC_REGION_WORDS => 1,
      GC_OUTSIDE => "poison"
    )
    port map (read_en => '1', addr => a_empty5, data => d_empty5,
              hit => h_empty5, ready => r_empty5);

  u_empty7 : entity work.mem_image
    generic map (
      GC_DATA_BYTES => 7, GC_ADDR_WIDTH => C_AW, GC_FILE => "",
      GC_MAX_REGIONS => 1, GC_GAP_BYTES => 4096, GC_REGION_WORDS => 1,
      GC_OUTSIDE => "poison"
    )
    port map (read_en => '1', addr => a_empty7, data => d_empty7,
              hit => h_empty7, ready => r_empty7);

  u_asc : entity work.mem_image
    generic map (
      GC_DATA_BYTES => C_W, GC_ADDR_WIDTH => C_AW,
      GC_FILE => GC_DIR & "ascii_image.hex",
      GC_MAX_REGIONS => 1, GC_GAP_BYTES => 4096, GC_OUTSIDE => "zero"
    )
    port map (read_en => '1', addr => a_asc, data => d_asc, hit => h_asc,
              ready => r_asc);

  u_hol : entity work.mem_image
    generic map (
      GC_DATA_BYTES => C_N, GC_ADDR_WIDTH => C_AW,
      GC_FILE => GC_DIR & "hole_image.hex",
      GC_MAX_REGIONS => 1, GC_GAP_BYTES => 4096, GC_OUTSIDE => "poison"
    )
    port map (read_en => '1', addr => a_hol, data => d_hol, hit => h_hol,
              ready => r_hol);

  u_seg : entity work.mem_image
    generic map (
      GC_DATA_BYTES => C_N, GC_ADDR_WIDTH => C_AW,
      GC_FILE => GC_DIR & "seg_image.hex",
      GC_MAX_REGIONS => 1, GC_GAP_BYTES => 4096, GC_OUTSIDE => "poison"
    )
    port map (read_en => '1', addr => a_seg, data => d_seg, hit => h_seg,
              ready => r_seg);

  u_par : entity work.mem_image
    generic map (
      GC_DATA_BYTES => C_N, GC_ADDR_WIDTH => C_AW,
      GC_FILE => GC_DIR & "partial_image.hex",
      GC_MAX_REGIONS => 1, GC_GAP_BYTES => 4096, GC_OUTSIDE => "poison"
    )
    port map (read_en => '1', addr => a_par, data => d_par, hit => h_par,
              ready => r_par);

  u_two : entity work.mem_image
    generic map (
      GC_DATA_BYTES => C_N, GC_ADDR_WIDTH => C_AW,
      GC_FILE => GC_DIR & "two_regions.hex",
      GC_MAX_REGIONS => 2, GC_GAP_BYTES => 4096, GC_OUTSIDE => "zero"
    )
    port map (read_en => '1', addr => a_two, data => d_two, hit => h_two,
              ready => r_two);

  p_stim : process

    -- Compare a beat against an expected byte list, slot i being byte i.
    procedure check_bytes(
      constant tag  : in string;
      constant beat : in std_logic_vector;
      constant exp  : in byte_array_t) is
    begin
      for i in exp'range loop
        assert beat(8*i+7 downto 8*i) = exp(i)
          report tag & ": byte " & integer'image(i) & " expected 0x" &
                 to_hstring(exp(i)) & " got 0x" & to_hstring(beat(8*i+7 downto 8*i))
          severity failure;
      end loop;
    end procedure;

    procedure check_zero(
      constant tag    : in string;
      constant beat   : in std_logic_vector;
      constant nbytes : in natural) is
    begin
      for i in 0 to nbytes - 1 loop
        assert beat(8*i+7 downto 8*i) = x"00"
          report tag & ": byte " & integer'image(i) & " should be zero"
          severity failure;
      end loop;
    end procedure;

    procedure check_poison(
      constant tag    : in string;
      constant beat   : in std_logic_vector;
      constant nbytes : in natural) is
    begin
      for i in 0 to nbytes/4 - 1 loop
        assert beat(32*i+31 downto 32*i) = x"DEADBEEF"
          report tag & ": word " & integer'image(i) & " should be poison"
          severity failure;
      end loop;
    end procedure;

    procedure note(text : string) is
      variable l : line;
    begin
      write(l, string'(text));
      writeline(output, l);
    end procedure;

    variable v_addr : std_logic_vector(C_AW-1 downto 0);

  begin
    wait until rising_edge(clk);
    assert r_min = '1' and r_byte = '1' and r_empty5 = '1' and
           r_empty7 = '1' and r_asc = '1' and r_hol = '1' and
           r_seg = '1' and r_par = '1' and r_two = '1'
      report "mem_image_examples_tb: an example image did not load"
      severity failure;

    -- Empty images are valid: ready rises, every read misses, and the
    -- configured poison value is deterministic for arbitrary byte widths.
    assert h_empty5 = '0' and d_empty5 = x"EFDEADBEEF"
      report "empty image: 5-byte poison mismatch"
      severity failure;
    assert h_empty7 = '0' and d_empty7 = x"ADBEEFDEADBEEF"
      report "empty image: 7-byte poison mismatch"
      severity failure;
    note("examples_tb: empty image and non-multiple poison widths checked");

    -- ----------------------------------------------------------------
    -- minimal_image.hex: the whole image is one word at 0x0000
    -- ----------------------------------------------------------------
    a_min <= (others => '0');
    wait until rising_edge(clk);
    assert h_min = '1' report "minimal: 0x0 is loaded" severity failure;
    check_bytes("minimal 0x0", d_min,
                (0 => x"11", 1 => x"22", 2 => x"33", 3 => x"44"));

    -- 0x0001 is not loaded: the region is 0x0000..0x0003, so a 4 byte read
    -- that starts at 0x0001 does not fit and is a miss.
    a_min <= std_logic_vector(to_unsigned(1, C_AW));
    wait until rising_edge(clk);
    assert h_min = '0' report "minimal: 0x1 must not be a hit" severity failure;
    check_zero("minimal 0x1", d_min, C_N);

    a_min <= std_logic_vector(to_unsigned(4, C_AW));
    wait until rising_edge(clk);
    assert h_min = '0' report "minimal: 0x4 must not be a hit" severity failure;
    note("examples_tb: minimal_image.hex checked");

    -- A one-byte port reads the same byte-addressed image without word
    -- alignment requirements.
    a_byte <= (others => '0');
    wait until rising_edge(clk);
    assert h_byte = '1' and d_byte = x"11"
      report "single-byte: address 0x0 mismatch"
      severity failure;
    a_byte <= std_logic_vector(to_unsigned(3, C_AW));
    wait until rising_edge(clk);
    assert h_byte = '1' and d_byte = x"44"
      report "single-byte: address 0x3 mismatch"
      severity failure;
    a_byte <= std_logic_vector(to_unsigned(4, C_AW));
    wait until rising_edge(clk);
    assert h_byte = '0' and d_byte = x"00"
      report "single-byte: address 0x4 should miss"
      severity failure;
    note("examples_tb: single-byte reads checked");

    -- ----------------------------------------------------------------
    -- ascii_image.hex: readable text, 16 byte reads
    -- ----------------------------------------------------------------
    a_asc <= std_logic_vector(to_unsigned(C_TEXT_BASE, C_AW));
    wait until rising_edge(clk);
    assert h_asc = '1' report "ascii: 0x1000 is loaded" severity failure;
    check_bytes("ascii +0", d_asc, (
      0 => x"48", 1 => x"45", 2 => x"4C", 3 => x"4C",   -- H E L L
      4 => x"4F", 5 => x"20", 6 => x"46", 7 => x"52",   -- O ' ' F R
      8 => x"4F", 9 => x"4D", 10 => x"20", 11 => x"41", -- O M ' ' A
      12 => x"20", 13 => x"48", 14 => x"45", 15 => x"58")); -- ' ' H E X

    a_asc <= std_logic_vector(to_unsigned(C_TEXT_BASE + 16, C_AW));
    wait until rising_edge(clk);
    assert h_asc = '1' report "ascii: 0x1010 is loaded" severity failure;
    check_bytes("ascii +16", d_asc, (
      0 => x"20", 1 => x"46", 2 => x"49", 3 => x"4C",   -- ' ' F I L
      4 => x"45", 5 => x"0A", 6 => x"00", 7 => x"00",   -- E LF NUL NUL
      8 => x"00", 9 => x"00", 10 => x"00", 11 => x"00",
      12 => x"00", 13 => x"00", 14 => x"00", 15 => x"00"));

    a_asc <= std_logic_vector(to_unsigned(C_TEXT_BASE + 32, C_AW));
    wait until rising_edge(clk);
    assert h_asc = '0' report "ascii: 0x1020 is past the end" severity failure;
    note("examples_tb: ascii_image.hex checked (text is read byte for byte)");

    -- ----------------------------------------------------------------
    -- hole_image.hex: loaded, hole, loaded
    -- ----------------------------------------------------------------
    a_hol <= std_logic_vector(to_unsigned(C_HOLE_BASE, C_AW));
    wait until rising_edge(clk);
    assert h_hol = '1' report "hole: 0x10000 is loaded" severity failure;
    check_bytes("hole +0", d_hol, (0 => x"A0", 1 => x"A1", 2 => x"A2", 3 => x"A3"));

    a_hol <= std_logic_vector(to_unsigned(C_HOLE_BASE + 4, C_AW));
    wait until rising_edge(clk);
    check_bytes("hole +4", d_hol, (0 => x"A4", 1 => x"A5", 2 => x"A6", 3 => x"A7"));

    -- the hole is inside the region, so it is a hit that reads zero, and
    -- the poison policy proves it is not a miss
    a_hol <= std_logic_vector(to_unsigned(C_HOLE_BASE + 8, C_AW));
    wait until rising_edge(clk);
    assert h_hol = '1'
      report "hole: 0x10008 is inside the region, so it must be a hit"
      severity failure;
    check_zero("hole +8", d_hol, C_N);

    a_hol <= std_logic_vector(to_unsigned(C_HOLE_BASE + 12, C_AW));
    wait until rising_edge(clk);
    check_zero("hole +12", d_hol, C_N);

    a_hol <= std_logic_vector(to_unsigned(C_HOLE_BASE + 16, C_AW));
    wait until rising_edge(clk);
    assert h_hol = '1' report "hole: 0x10010 is loaded" severity failure;
    check_bytes("hole +16", d_hol, (0 => x"B0", 1 => x"B1", 2 => x"B2", 3 => x"B3"));

    a_hol <= std_logic_vector(to_unsigned(C_HOLE_BASE + 28, C_AW));
    wait until rising_edge(clk);
    assert h_hol = '1'
      report "hole: 0x1001C is the last word of the region"
      severity failure;
    check_bytes("hole +28", d_hol, (0 => x"BC", 1 => x"BD", 2 => x"BE", 3 => x"BF"));

    a_hol <= std_logic_vector(to_unsigned(C_HOLE_BASE + 32, C_AW));
    wait until rising_edge(clk);
    assert h_hol = '0'
      report "hole: 0x10020 is past the region end"
      severity failure;
    check_poison("hole +32", d_hol, C_N);
    note("examples_tb: hole_image.hex checked (hole reads zero, miss poisons)");

    -- ----------------------------------------------------------------
    -- seg_image.hex: type 02 records must give exactly the same image as
    -- the type 04 records in hole_image.hex
    -- ----------------------------------------------------------------
    for off in 0 to 8 loop
      v_addr := std_logic_vector(to_unsigned(C_HOLE_BASE + 4*off, C_AW));
      a_hol <= v_addr;
      a_seg <= v_addr;
      wait until rising_edge(clk);
      assert h_seg = h_hol
        report "seg: hit differs from hole_image at 0x" & to_hstring(v_addr)
        severity failure;
      assert d_seg = d_hol
        report "seg: data differs from hole_image at 0x" & to_hstring(v_addr)
        severity failure;
    end loop;
    assert h_seg = '0'
      report "seg: the last probe (0x10020) must be a miss"
      severity failure;
    note("examples_tb: seg_image.hex checked (type 02 == type 04)");

    -- ----------------------------------------------------------------
    -- partial_image.hex: byte exact, not word aligned
    -- ----------------------------------------------------------------
    a_par <= std_logic_vector(to_unsigned(16#0004#, C_AW));
    wait until rising_edge(clk);
    assert h_par = '1'
      report "partial: 0x0004 is inside 0x0003..0x0007"
      severity failure;
    -- 0x0006 was never loaded but is inside the region: it reads zero, and
    -- the poison policy shows that this is a hit and not a miss
    check_bytes("partial 0x0004", d_par, (0 => x"BB", 1 => x"CC", 2 => x"00", 3 => x"DD"));

    a_par <= std_logic_vector(to_unsigned(16#0007#, C_AW));
    wait until rising_edge(clk);
    assert h_par = '0'
      report "partial: a 4 byte read at 0x0007 does not fit in 0x0003..0x0007"
      severity failure;
    check_poison("partial 0x0007", d_par, C_N);

    a_par <= (others => '0');
    wait until rising_edge(clk);
    assert h_par = '0'
      report "partial: 0x0000 is before the first loaded byte"
      severity failure;
    check_poison("partial 0x0000", d_par, C_N);
    note("examples_tb: partial_image.hex checked (byte exact, unaligned)");

    -- ----------------------------------------------------------------
    -- two_regions.hex: two regions 64 KiB apart
    -- ----------------------------------------------------------------
    a_two <= (others => '0');
    wait until rising_edge(clk);
    assert h_two = '1' report "two: 0x00000 is loaded" severity failure;
    check_bytes("two low", d_two, (0 => x"10", 1 => x"20", 2 => x"30", 3 => x"40"));

    a_two <= std_logic_vector(to_unsigned(C_HI_REGION, C_AW));
    wait until rising_edge(clk);
    assert h_two = '1' report "two: 0x10000 is loaded" severity failure;
    check_bytes("two high", d_two, (0 => x"50", 1 => x"60", 2 => x"70", 3 => x"80"));

    a_two <= std_logic_vector(to_unsigned(16#08000#, C_AW));
    wait until rising_edge(clk);
    assert h_two = '0'
      report "two: 0x08000 is between the two regions"
      severity failure;
    check_zero("two middle", d_two, C_N);

    a_two <= std_logic_vector(to_unsigned(C_HI_REGION + 4, C_AW));
    wait until rising_edge(clk);
    assert h_two = '0'
      report "two: 0x10004 is past the high region"
      severity failure;
    note("examples_tb: two_regions.hex checked (two regions, gap outside)");

    report "mem_image_examples_tb: ALL EXAMPLES CHECKED" severity note;
    sim_done <= true;
    wait;
  end process;

end architecture;
