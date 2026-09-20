-----------------------------------------------------------------------
--Filename         : mem_image_tb.vhd
--Description      : Testbench for mem_image (file-backed image store).
--                 :
--                 : Fixtures (axi_mem_image/tb/data/):
--                 :   demo_image.hex  4 blocks of 64 bytes at 0x1000,
--                 :                  0x2000, 0x3000, 0x4000
--                 :   hole_image.hex  8 bytes 0xA0.. at 0x10000, an 8 byte
--                 :                  hole, 16 bytes 0xB0.. at 0x10010,
--                 :                  addressed through a type 04 record
--                 :
--                 : Fixture contents follow byte(A) = (A[7:0] + A[15:8])
--                 : mod 256, so every byte differs from its neighbour (a
--                 : lane swap or a wrong beat address cannot pass).
--                 :
--                 : Covered here:
--                 :   * the file's own addresses and sizes drive region
--                 :     count, region size and allocation (no size generic)
--                 :   * region split by address gaps (GC_GAP_BYTES)
--                 :   * regions merged into one when the gap is wider than
--                 :     the spacing between the blocks
--                 :   * byte assembly at 16 byte and 4 byte widths,
--                 :     including an unaligned start address
--                 :   * holes inside a region read as zero
--                 :   * a beat that runs past the region end is a miss
--                 :   * region-miss policy: zero and poison.  The third
--                 :     policy, "fail", is checked by a hands-on run (the
--                 :     README shows how); it cannot be exercised here
--                 :     because it ends the simulation.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity mem_image_tb is
  generic (
    GC_FILE_DEMO : string := "axi_mem_image/tb/data/demo_image.hex";
    GC_FILE_HOLE : string := "axi_mem_image/tb/data/hole_image.hex"
  );
end entity;

architecture sim of mem_image_tb is

  constant C_ADDR_WIDTH : positive := 32;
  constant C_NBYTES_W   : positive := 16;   -- wide store read width
  constant C_NBYTES_N   : positive := 4;    -- narrow store read width

  -- demo_image.hex: 4 blocks 4096 bytes apart, 64 bytes each.
  -- hole_image.hex: one 32 byte region at 0x10000 with an 8 byte hole.
  constant C_BLOCK : natural := 16#1000#;
  constant C_HOLE  : natural := 16#10000#;

  signal clk      : std_logic := '0';
  signal sim_done : boolean := false;

  -- A: gap 256 -> four separate regions, "fail" policy
  signal addr_a : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal rd_a   : std_logic := '0';
  signal data_a : std_logic_vector(8*C_NBYTES_W-1 downto 0);
  signal hit_a  : std_logic;
  signal rdy_a  : std_logic;

  -- B: single region (hole image), "zero" policy
  signal addr_b : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal data_b : std_logic_vector(8*C_NBYTES_W-1 downto 0);
  signal hit_b  : std_logic;
  signal rdy_b  : std_logic;

  -- C: same file, "poison" policy
  signal addr_c : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal data_c : std_logic_vector(8*C_NBYTES_W-1 downto 0);
  signal hit_c  : std_logic;
  signal rdy_c  : std_logic;

  -- D: 4 byte reads of the demo image, unaligned start addresses
  signal addr_d : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal data_d : std_logic_vector(8*C_NBYTES_N-1 downto 0);
  signal hit_d  : std_logic;
  signal rdy_d  : std_logic;

  -- E: gap 8192 -> the four demo blocks merge into one region
  signal addr_e : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal data_e : std_logic_vector(8*C_NBYTES_W-1 downto 0);
  signal hit_e  : std_logic;
  signal rdy_e  : std_logic;

  -- Expected byte value of the fixture images at one address.
  function exp_byte(addr : natural) return std_logic_vector is
    variable v_val : natural;
  begin
    v_val := ((addr mod 256) + ((addr / 256) mod 256)) mod 256;
    return std_logic_vector(to_unsigned(v_val, 8));
  end function;

begin

  clk <= not clk after 5 ns when not sim_done else '0';

  -- A: the four demo blocks split by GC_GAP_BYTES = 256
  u_a : entity work.mem_image
    generic map (
      GC_DATA_BYTES  => C_NBYTES_W,
      GC_ADDR_WIDTH  => C_ADDR_WIDTH,
      GC_FILE        => GC_FILE_DEMO,
      GC_MAX_REGIONS => 4,
      GC_GAP_BYTES   => 256,
      GC_OUTSIDE     => "fail"
    )
    port map (
      read_en => rd_a, addr => addr_a, data => data_a, hit => hit_a,
      ready => rdy_a
    );

  -- B: hole image, misses read as zero
  u_b : entity work.mem_image
    generic map (
      GC_DATA_BYTES  => C_NBYTES_W,
      GC_ADDR_WIDTH  => C_ADDR_WIDTH,
      GC_FILE        => GC_FILE_HOLE,
      GC_MAX_REGIONS => 4,
      GC_GAP_BYTES   => 4096,
      GC_OUTSIDE     => "zero"
    )
    port map (
      read_en => '1', addr => addr_b, data => data_b, hit => hit_b,
      ready => rdy_b
    );

  -- C: hole image, misses read as the poison word
  u_c : entity work.mem_image
    generic map (
      GC_DATA_BYTES  => C_NBYTES_W,
      GC_ADDR_WIDTH  => C_ADDR_WIDTH,
      GC_FILE        => GC_FILE_HOLE,
      GC_MAX_REGIONS => 4,
      GC_GAP_BYTES   => 4096,
      GC_OUTSIDE     => "poison"
    )
    port map (
      read_en => '1', addr => addr_c, data => data_c, hit => hit_c,
      ready => rdy_c
    );

  -- D: 4 byte reads, unaligned addresses resolved by the byte assembly
  u_d : entity work.mem_image
    generic map (
      GC_DATA_BYTES  => C_NBYTES_N,
      GC_ADDR_WIDTH  => C_ADDR_WIDTH,
      GC_FILE        => GC_FILE_DEMO,
      GC_MAX_REGIONS => 4,
      GC_GAP_BYTES   => 256,
      GC_OUTSIDE     => "zero"
    )
    port map (
      read_en => '1', addr => addr_d, data => data_d, hit => hit_d,
      ready => rdy_d
    );

  -- E: same file with a gap wider than the block spacing -> one region
  u_e : entity work.mem_image
    generic map (
      GC_DATA_BYTES  => C_NBYTES_W,
      GC_ADDR_WIDTH  => C_ADDR_WIDTH,
      GC_FILE        => GC_FILE_DEMO,
      GC_MAX_REGIONS => 4,
      GC_GAP_BYTES   => 8192,
      GC_OUTSIDE     => "zero"
    )
    port map (
      read_en => '1', addr => addr_e, data => data_e, hit => hit_e,
      ready => rdy_e
    );

  p_stim : process

    -- Compare a beat against the fixture pattern (the byte(A) rule).
    procedure check_pattern(
      constant tag    : in string;
      constant base   : in natural;
      constant beat   : in std_logic_vector;
      constant nbytes : in natural) is
    begin
      for i in 0 to nbytes - 1 loop
        assert beat(8*i+7 downto 8*i) = exp_byte(base + i)
          report tag & ": byte " & integer'image(i) & " at 0x" &
                 to_hstring(to_unsigned(base + i, 32)) & " expected 0x" &
                 to_hstring(exp_byte(base + i)) & " got 0x" &
                 to_hstring(beat(8*i+7 downto 8*i))
          severity failure;
      end loop;
    end procedure;

    procedure check_zero(
      constant tag    : in string;
      constant beat   : in std_logic_vector;
      constant nbytes : in natural;
      constant lsb    : in natural := 0) is
    begin
      for i in 0 to nbytes - 1 loop
        assert beat(lsb + 8*i + 7 downto lsb + 8*i) = x"00"
          report tag & ": byte " & integer'image(i) & " is not zero"
          severity failure;
      end loop;
    end procedure;

    procedure check_poison(
      constant tag    : in string;
      constant beat   : in std_logic_vector;
      constant nwords : in natural) is
    begin
      for w in 0 to nwords - 1 loop
        assert beat(32*w+31 downto 32*w) = x"DEADBEEF"
          report tag & ": word " & integer'image(w) & " is not poison"
          severity failure;
      end loop;
    end procedure;

    procedure note(text : string) is
      variable l : line;
    begin
      write(l, string'(text));
      writeline(output, l);
    end procedure;

    variable v_base : natural;
    variable v_wait : natural := 0;
  begin
    note("mem_image_tb: waiting for the images to load");

    -- The loader runs at time 0; all five instances must report ready.
    wait until rising_edge(clk);
    assert rdy_a = '1' and rdy_b = '1' and rdy_c = '1' and
           rdy_d = '1' and rdy_e = '1'
      report "mem_image_tb: an image did not load (ready low)"
      severity failure;

    -- ----------------------------------------------------------------
    -- A: four separate regions, 16 byte reads of every block
    -- ----------------------------------------------------------------
    for blk in 0 to 3 loop
      for step in 0 to 3 loop
        v_base := C_BLOCK * (blk + 1) + step * C_NBYTES_W;
        addr_a <= std_logic_vector(to_unsigned(v_base, C_ADDR_WIDTH));
        wait until rising_edge(clk);
        rd_a <= '1';
        wait until rising_edge(clk);
        assert hit_a = '1'
          report "mem_image_tb: block " & integer'image(blk) & " offset " &
                 integer'image(step) & " must be inside the image"
          severity failure;
        check_pattern("A block " & integer'image(blk), v_base, data_a,
                      C_NBYTES_W);
        rd_a <= '0';
      end loop;
    end loop;
    note("mem_image_tb: A (4 regions, 16 byte reads) checked");

    -- Between the blocks is outside the image.  "fail" is applied only
    -- when a beat is consumed, so pointing there with read_en low is
    -- harmless - that is what makes the policy usable mid-burst.
    addr_a <= std_logic_vector(to_unsigned(C_BLOCK + 16#800#, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    assert hit_a = '0'
      report "mem_image_tb: 0x1800 lies between blocks and must be a miss"
      severity failure;

    -- ----------------------------------------------------------------
    -- B: hole inside the region reads as zero
    -- ----------------------------------------------------------------
    addr_b <= std_logic_vector(to_unsigned(C_HOLE, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    assert hit_b = '1'
      report "mem_image_tb: the hole image start must be a hit"
      severity failure;
    for i in 0 to 7 loop
      assert data_b(8*i+7 downto 8*i) =
             std_logic_vector(to_unsigned(16#A0# + i, 8))
        report "mem_image_tb: hole image byte " & integer'image(i) & " wrong"
        severity failure;
    end loop;
    check_zero("B hole", data_b, C_NBYTES_W - 8, 64);

    -- the tail block reads back in full (it is inside the region)
    addr_b <= std_logic_vector(to_unsigned(C_HOLE + 16, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    assert hit_b = '1'
      report "mem_image_tb: the hole image tail must be a hit"
      severity failure;
    for i in 0 to 15 loop
      assert data_b(8*i+7 downto 8*i) =
             std_logic_vector(to_unsigned(16#B0# + i, 8))
        report "mem_image_tb: hole image tail byte " & integer'image(i) & " wrong"
        severity failure;
    end loop;

    -- a beat that starts inside but ends past the region is a miss
    addr_b <= std_logic_vector(to_unsigned(C_HOLE + 28, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    assert hit_b = '0'
      report "mem_image_tb: 0x1001C + 16 bytes runs past the region end " &
             "and must be a miss"
      severity failure;
    check_zero("B past end", data_b, C_NBYTES_W);

    addr_b <= std_logic_vector(to_unsigned(16#30000#, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    assert hit_b = '0'
      report "mem_image_tb: 0x30000 is outside the image"
      severity failure;
    check_zero("B outside", data_b, C_NBYTES_W);
    note("mem_image_tb: B (holes read as zero) checked");

    -- ----------------------------------------------------------------
    -- C: the same miss with the poison policy
    -- ----------------------------------------------------------------
    addr_c <= std_logic_vector(to_unsigned(C_HOLE, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    assert hit_c = '1'
      report "mem_image_tb: poison store start must be a hit"
      severity failure;
    addr_c <= std_logic_vector(to_unsigned(16#30000#, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    assert hit_c = '0'
      report "mem_image_tb: 0x30000 is outside the image"
      severity failure;
    check_poison("C outside", data_c, C_NBYTES_W / 4);
    note("mem_image_tb: C (poison on miss) checked");

    -- ----------------------------------------------------------------
    -- D: 4 byte reads, including unaligned start addresses
    -- ----------------------------------------------------------------
    v_base := C_BLOCK + 1;
    addr_d <= std_logic_vector(to_unsigned(v_base, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    assert hit_d = '1'
      report "mem_image_tb: unaligned 4 byte read must be a hit"
      severity failure;
    check_pattern("D unaligned", v_base, data_d, C_NBYTES_N);

    v_base := 3 * C_BLOCK + 60;
    addr_d <= std_logic_vector(to_unsigned(v_base, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    assert hit_d = '1'
      report "mem_image_tb: a 4 byte read ending at the region end must hit"
      severity failure;
    check_pattern("D block 3", v_base, data_d, C_NBYTES_N);

    addr_d <= std_logic_vector(to_unsigned(16#8000#, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    assert hit_d = '0'
      report "mem_image_tb: 0x8000 is outside the image"
      severity failure;
    check_zero("D outside", data_d, C_NBYTES_N);
    note("mem_image_tb: D (4 byte unaligned reads) checked");

    -- ----------------------------------------------------------------
    -- E: with a gap wider than the block spacing the four blocks form
    -- one region, so the space between them is inside and reads zero
    -- ----------------------------------------------------------------
    addr_e <= std_logic_vector(to_unsigned(C_BLOCK, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    check_pattern("E block 1", C_BLOCK, data_e, C_NBYTES_W);

    addr_e <= std_logic_vector(to_unsigned(4 * C_BLOCK, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    check_pattern("E block 4", 4 * C_BLOCK, data_e, C_NBYTES_W);

    addr_e <= std_logic_vector(to_unsigned(C_BLOCK + 16#800#, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    assert hit_e = '1'
      report "mem_image_tb: with GC_GAP_BYTES=8192 the blocks merge into " &
             "one region, so 0x1800 must be a hit"
      severity failure;
    check_zero("E merged hole", data_e, C_NBYTES_W);

    addr_e <= std_logic_vector(to_unsigned(16#8000#, C_ADDR_WIDTH));
    wait until rising_edge(clk);
    assert hit_e = '0'
      report "mem_image_tb: 0x8000 is outside the merged region"
      severity failure;
    note("mem_image_tb: E (gap merge) checked");

    report "mem_image_tb: ALL CHECKS PASSED" severity note;
    sim_done <= true;
    wait;
  end process;

end architecture;
