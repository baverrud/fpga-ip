-----------------------------------------------------------------------
--Filename         : mem_image_simple_tb.vhd
--Description      : The smallest possible mem_image example.
--                 :
--                 : Image file (tb/data/simple_image.hex):
--                 :   :08000000EFBEADDE78563412AC
--                 :   :00000001FF
--                 :
--                 :   address 0x0000: EF BE AD DE  -> 32 bit word 0xDEADBEEF
--                 :   address 0x0004: 78 56 34 12  -> 32 bit word 0x12345678
--                 :
--                 : The memory is little endian, so the byte order in the
--                 : file is the byte order on the bus: the first byte of
--                 : the record is the least significant byte of the word.
--                 :
--                 : Run it with:
--                 :   run axi_mem_image vhdl modelsim --tb simple
--                 :   run axi_mem_image vhdl xsim     --tb simple
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity mem_image_simple_tb is
end entity;

architecture sim of mem_image_simple_tb is

  signal addr  : std_logic_vector(31 downto 0) := (others => '0');
  signal data  : std_logic_vector(31 downto 0);
  signal hit   : std_logic;
  signal ready : std_logic;

  -- Small helper so the example can print progress to the transcript.
  procedure print(text : string) is
    variable l : line;
  begin
    write(l, string'(text));
    writeline(output, l);
  end procedure;

begin

  -- One instance, four bytes per read, reading simple_image.hex.  Reads
  -- outside the image drive zero (GC_OUTSIDE => "zero") instead of
  -- stopping the simulation.
  u_image : entity work.mem_image
    generic map (
      GC_DATA_BYTES => 4,
      GC_ADDR_WIDTH => 32,
      GC_FILE       => "axi_mem_image/tb/data/simple_image.hex",
      GC_OUTSIDE    => "zero"
    )
    port map (
      read_en => '1',
      addr    => addr,
      data    => data,
      hit     => hit,
      ready   => ready
    );

  p_example : process
  begin
    -- The image is read while the simulation is elaborated, so it is
    -- already loaded before the first wait.
    wait for 1 ns;
    assert ready = '1'
      report "simple example: the image file was not loaded"
      severity failure;
    print("simple example: image loaded");

    -- Read the first word.
    addr <= x"00000000";
    wait for 1 ns;
    assert hit = '1'
      report "simple example: 0x0000 is inside the image"
      severity failure;
    assert data = x"DEADBEEF"
      report "simple example: 0x0000 should read 0xDEADBEEF"
      severity failure;
    print("simple example: read 0x0000 -> 0xDEADBEEF");

    -- Read the second word.
    addr <= x"00000004";
    wait for 1 ns;
    assert hit = '1'
      report "simple example: 0x0004 is inside the image"
      severity failure;
    assert data = x"12345678"
      report "simple example: 0x0004 should read 0x12345678"
      severity failure;
    print("simple example: read 0x0004 -> 0x12345678");

    -- Past the end of the image: not a hit, and with GC_OUTSIDE = "zero"
    -- the data bus is zero for that read.
    addr <= x"00000008";
    wait for 1 ns;
    assert hit = '0'
      report "simple example: 0x0008 is outside the image, so hit must be low"
      severity failure;
    assert data = x"00000000"
      report "simple example: a read outside the image should give zero here"
      severity failure;
    print("simple example: read 0x0008 -> miss, data 0x00000000");

    print("simple example: SIMPLE EXAMPLE OK");
    wait;
  end process;

end architecture;
