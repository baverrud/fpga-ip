-----------------------------------------------------------------------
--Filename         : axilite_io_tb.vhd
--Description      : Shared AXI4-Lite Register I/O Testbench.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
--                 : Permission to use, copy, modify, and/or distribute this
--                 : software for any purpose with or without fee is hereby granted.
-----------------------------------------------------------------------
-- =====================================================================
-- axilite_io_tb.vhd -- Shared AXI4-Lite Register I/O Testbench
-- =====================================================================
-- Tests the axilite_io DUT (VHDL or SV) via the axilite_io_th harness
-- which provides AXI-Stream loopback FIFOs and FIFO-status i_data.
-- AXI-Lite transactions use the BFM helpers from axilite_bfm_pkg.
-- =====================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;
use work.axilite_bfm_pkg.all;

entity axilite_io_tb is
end entity;

architecture sim of axilite_io_tb is

  constant NUM_ODATA        : natural := 2;
  constant GC_NUM_EXT_IDATA : natural := 2;
  constant NUM_OSTREAM      : natural := 2;
  constant NUM_ISTREAM      : natural := 2;
  constant TCLK             : time    := 10 ns;
  -- FIFO status base addr: 0x8000 + GC_NUM_EXT_IDATA*4 = 0x8008 (slot 2, after 2 external slots)
  -- ready(ch) at 0x8008 + ch*8, valid(ch) at 0x8008 + ch*8 + 4

  signal clk       : std_logic := '0';
  signal rstn      : std_logic := '0';
  signal test_done : std_logic := '0';

  -- AXI4-Lite (40-bit addr for axilite_bfm_pkg; DUT uses lower 16 bits)
  signal awaddr  : std_logic_vector(39 downto 0) := (others => '0');
  signal awprot  : std_logic_vector( 2 downto 0) := (others => '0');
  signal awvalid : std_logic := '0';
  signal awready : std_logic;
  signal wdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal wstrb   : std_logic_vector( 3 downto 0) := (others => '0');
  signal wvalid  : std_logic := '0';
  signal wready  : std_logic;
  signal bresp   : std_logic_vector( 1 downto 0);
  signal bvalid  : std_logic;
  signal bready  : std_logic := '0';
  signal araddr  : std_logic_vector(39 downto 0) := (others => '0');
  signal arprot  : std_logic_vector( 2 downto 0) := (others => '0');
  signal arvalid : std_logic := '0';
  signal arready : std_logic;
  signal rdata   : std_logic_vector(31 downto 0);
  signal rresp   : std_logic_vector( 1 downto 0);
  signal rvalid  : std_logic;
  signal rready  : std_logic := '0';

  -- Array-type ports (axilite_io_th interface)
  signal o_data        : t_slv32_array(0 to NUM_ODATA-1);
  signal i_data        : t_slv32_array(0 to GC_NUM_EXT_IDATA-1) := (others => (others => '0'));
  signal m_axis_tdata  : std_logic_vector(31 downto 0);
  signal m_axis_tvalid : std_logic_vector(NUM_OSTREAM-1 downto 0);
  signal s_axis_tdata  : t_slv32_array(0 to NUM_ISTREAM-1);
  signal s_axis_tready : std_logic_vector(NUM_ISTREAM-1 downto 0);

  procedure check(
    name : string;
    got  : std_logic_vector(31 downto 0);
    exp  : std_logic_vector(31 downto 0)
  ) is
  begin
    if got /= exp then
      report "FAIL: " & name & " -- got " & to_hstring(got) &
             ", exp " & to_hstring(exp) severity error;
    else
      report "PASS: " & name & " = " & to_hstring(got) severity note;
    end if;
  end procedure;

begin

  clk <= not clk after TCLK/2 when test_done = '0' else '0';

  -- DUT via test harness (includes FIFO loopback and status i_data)
  dut : entity work.axilite_io_th
    generic map (
      GC_NUM_ODATA     => NUM_ODATA,
      GC_NUM_EXT_IDATA => GC_NUM_EXT_IDATA,
      GC_NUM_OSTREAM   => NUM_OSTREAM,
      GC_NUM_ISTREAM   => NUM_ISTREAM
    )
    port map (
      aclk          => clk,
      aresetn       => rstn,
      s_axi_awaddr  => awaddr(15 downto 0),
      s_axi_awprot  => awprot,
      s_axi_awvalid => awvalid,
      s_axi_awready => awready,
      s_axi_wdata   => wdata,
      s_axi_wstrb   => wstrb,
      s_axi_wvalid  => wvalid,
      s_axi_wready  => wready,
      s_axi_bresp   => bresp,
      s_axi_bvalid  => bvalid,
      s_axi_bready  => bready,
      s_axi_araddr  => araddr(15 downto 0),
      s_axi_arprot  => arprot,
      s_axi_arvalid => arvalid,
      s_axi_arready => arready,
      s_axi_rdata   => rdata,
      s_axi_rresp   => rresp,
      s_axi_rvalid  => rvalid,
      s_axi_rready  => rready,
      o_data        => o_data,
      i_data_ext    => i_data,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tready => s_axis_tready
    );

  -- ================================================================
  --  Stimulus
  -- ================================================================
  process is

    variable rd : std_logic_vector(31 downto 0);

    -- Thin wrappers around axilite_pkg BFM helpers
    procedure write_reg(
      addr : std_logic_vector(15 downto 0);
      data : std_logic_vector(31 downto 0);
      strb : std_logic_vector(3 downto 0) := x"F"
    ) is
    begin
      axilite_write(clk, awaddr, awprot, awvalid, awready,
                    wdata, wstrb, wvalid, wready,
                    bready, bvalid, addr, data, strb);
    end procedure;

    procedure read_reg(
      addr : std_logic_vector(15 downto 0);
      data : out std_logic_vector(31 downto 0)
    ) is
    begin
      axilite_read(clk, araddr, arprot, arvalid, arready,
                   rready, rvalid, rdata, addr, data);
    end procedure;

    -- Stream push: poll FIFO ready (i_data slot ready_base + ch*2) then write.
    procedure write_stream(
      channel : natural;
      data    : std_logic_vector(31 downto 0)
    ) is
      variable status : std_logic_vector(31 downto 0);
    begin
      loop
        read_reg(std_logic_vector(to_unsigned(16#8008# + channel*8, 16)), status);
        exit when status(0) = '1';
      end loop;
      write_reg(std_logic_vector(to_unsigned(16#4000# + channel*4, 16)), data, x"F");
    end procedure;

    -- Stream pop: poll FIFO valid (i_data slot ready_base + ch*2 + 1) then read.
    procedure read_stream(
      channel : natural;
      data    : out std_logic_vector(31 downto 0)
    ) is
      variable status : std_logic_vector(31 downto 0);
    begin
      loop
        read_reg(std_logic_vector(to_unsigned(16#8008# + channel*8 + 4, 16)), status);
        exit when status(0) = '1';
      end loop;
      read_reg(std_logic_vector(to_unsigned(16#C000# + channel*4, 16)), data);
    end procedure;

  begin
    report "=== axilite_io -- Shared Testbench ===" severity note;

    -- Reset
    rstn <= '0';
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    rstn <= '1';
    wait until rising_edge(clk);

    -- Test 1: Write/Read o_data[0]
    report "=== Test 1: Write/Read o_data[0] ===" severity note;
    write_reg(x"0000", x"A5A5A5A5", x"F");
    check("o_data[0]", o_data(0), x"A5A5A5A5");
    read_reg(x"0000", rd); check("rdata[0]", rd, x"A5A5A5A5");

    -- Test 2: Byte-strobe o_data[1] byte0
    report "=== Test 2: byte-strobe o_data[1] byte0 ===" severity note;
    write_reg(x"0004", x"FFFF00FF", x"1");
    check("o_data[1]", o_data(1), x"000000FF");
    read_reg(x"0004", rd); check("rdata[1]", rd, x"000000FF");

    -- Test 3: Byte-strobe o_data[0] bytes0+2
    report "=== Test 3: byte-strobe o_data[0] bytes0+2 ===" severity note;
    write_reg(x"0000", x"12345678", x"5");
    check("o_data[0]", o_data(0), x"A534A578");
    read_reg(x"0000", rd); check("rdata[0]", rd, x"A534A578");

    -- Test 4: Read i_data ports
    report "=== Test 4: Read i_data ports ===" severity note;
    i_data(0) <= x"DEADBEEF";
    i_data(1) <= x"CAFEBABE";
    wait until rising_edge(clk);
    read_reg(x"8000", rd); check("i_data[0]", rd, x"DEADBEEF");
    read_reg(x"8004", rd); check("i_data[1]", rd, x"CAFEBABE");

    -- Test 5-6: Stream push (FIFO loopback from m_axis through FIFO to s_axis)
    report "=== Test 5: Stream push [0] ===" severity note;
    write_stream(0, x"AABBCCDD");
    report "=== Test 6: Stream push [1] ===" severity note;
    write_stream(1, x"11223344");

    -- Test 7-8: Stream pop (read back from FIFO loopback)
    report "=== Test 7: Stream pop [0] ===" severity note;
    read_stream(0, rd); check("pop[0]", rd, x"AABBCCDD");
    report "=== Test 8: Stream pop [1] ===" severity note;
    read_stream(1, rd); check("pop[1]", rd, x"11223344");

    -- Test 9: Read-after-write
    report "=== Test 9: Read-after-write ===" severity note;
    write_reg(x"0000", x"FEDCBA98", x"F");
    read_reg(x"0000", rd); check("read-after-write", rd, x"FEDCBA98");

    -- Test 10: Unmapped read
    report "=== Test 10: Unmapped read ===" severity note;
    read_reg(x"5000", rd); check("unmapped", rd, x"00000000");

    -- Test 11: Reset state (o_data defaults to zero)
    report "=== Test 11: Reset state ===" severity note;
    rstn <= '0';
    for i in 1 to 4 loop wait until rising_edge(clk); end loop;
    rstn <= '1';
    wait until rising_edge(clk);
    check("o_data[0] after reset", o_data(0), x"00000000");
    check("o_data[1] after reset", o_data(1), x"00000000");

    -- Test 12: wstrb = x"0" (no bytes written, register unchanged)
    report "=== Test 12: wstrb = 0 ===" severity note;
    write_reg(x"0000", x"FFFFFFFF", x"0");
    check("o_data[0] after wstrb=0", o_data(0), x"00000000");

    -- Test 13: Full overwrite after strobe
    report "=== Test 13: Full overwrite ===" severity note;
    write_reg(x"0000", x"DEADBEEF", x"F");
    check("o_data[0] full overwrite", o_data(0), x"DEADBEEF");
    read_reg(x"0000", rd); check("rdata full overwrite", rd, x"DEADBEEF");

    -- Test 14: Back-to-back writes to different registers
    report "=== Test 14: Back-to-back writes ===" severity note;
    write_reg(x"0000", x"AAAA0000", x"F");
    write_reg(x"0004", x"BBBB0000", x"F");
    check("o_data[0] b2b", o_data(0), x"AAAA0000");
    check("o_data[1] b2b", o_data(1), x"BBBB0000");

    -- Test 15: i_data toggle (change after previous read)
    report "=== Test 15: i_data toggle ===" severity note;
    i_data(0) <= x"CAFEBABE";
    wait until rising_edge(clk);
    read_reg(x"8000", rd); check("i_data[0] toggled", rd, x"CAFEBABE");

    -- Test 16: Write then read same register (already done in test 9, repeat on new data)
    report "=== Test 16: Write/Read back ===" severity note;
    write_reg(x"0000", x"12345678", x"F");
    read_reg(x"0000", rd); check("write/read back", rd, x"12345678");

    -- Test 17: Unmapped write (should not affect anything)
    report "=== Test 17: Unmapped write ===" severity note;
    write_reg(x"9000", x"DEADC0DE", x"F");
    read_reg(x"0000", rd); check("o_data after unmapped write", rd, x"12345678");

    -- Test 18: Individual byte strobes x"2", x"4", x"8"
    report "=== Test 18: Byte strobes x2, x4, x8 ===" severity note;
    write_reg(x"0000", x"00000000", x"F");
    write_reg(x"0004", x"00000000", x"F");
    -- Strobe byte1 only (x"2")
    write_reg(x"0004", x"0000FF00", x"2");
    check("o_data[1] byte1", o_data(1), x"0000FF00");
    read_reg(x"0004", rd); check("rdata[1] byte1", rd, x"0000FF00");
    -- Strobe byte2 only (x"4")
    write_reg(x"0000", x"00FF0000", x"4");
    check("o_data[0] byte2", o_data(0), x"00FF0000");
    read_reg(x"0000", rd); check("rdata[0] byte2", rd, x"00FF0000");
    -- Strobe byte3 only (x"8")
    write_reg(x"0004", x"FF000000", x"8");
    check("o_data[1] byte3", o_data(1), x"FF00FF00");
    read_reg(x"0004", rd); check("rdata[1] byte3", rd, x"FF00FF00");

    -- Test 19: Multiple stream pushes to same channel (FIFO ordering)
    report "=== Test 19: Multiple stream pushes same channel ===" severity note;
    write_stream(0, x"AAA00001");
    write_stream(0, x"BBB00002");
    write_stream(0, x"CCC00003");
    read_stream(0, rd); check("pop[0] #1", rd, x"AAA00001");
    read_stream(0, rd); check("pop[0] #2", rd, x"BBB00002");
    read_stream(0, rd); check("pop[0] #3", rd, x"CCC00003");

    -- Test 20: Stream FIFO near-full (backpressure)
    report "=== Test 20: Stream FIFO near-full ===" severity note;
    -- Fill FIFO to 15/16 capacity
    for i in 0 to 14 loop
      write_stream(0, std_logic_vector(to_unsigned(i, 32)));
    end loop;
    -- Pop 1 to make room
    read_stream(0, rd); check("pop[0] near-full 0", rd, x"00000000");
    -- Push one more (completes because room was made)
    write_stream(0, x"FEDCBA98");
    -- Pop remaining 14 items (1..14) + the new item
    for i in 1 to 14 loop
      read_stream(0, rd);
      check("pop[0] near-full " & integer'image(i), rd, std_logic_vector(to_unsigned(i, 32)));
    end loop;
    read_stream(0, rd); check("pop[0] near-full 16", rd, x"FEDCBA98");

    -- Test 21: Consecutive reads of same register (stability)
    report "=== Test 21: Consecutive reads (stability) ===" severity note;
    write_reg(x"0000", x"DEADBEEF", x"F");
    read_reg(x"0000", rd); check("read[0] stability", rd, x"DEADBEEF");
    read_reg(x"0000", rd); check("read[1] stability", rd, x"DEADBEEF");
    read_reg(x"0000", rd); check("read[2] stability", rd, x"DEADBEEF");

    -- Summary
    wait until rising_edge(clk);
    report "================================" severity note;
    report "*** ALL TESTS PASSED ***" severity note;
    test_done <= '1';
    wait;
  end process;

end architecture;
