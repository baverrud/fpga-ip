-----------------------------------------------------------------------
--Filename         : aes_tb.vhd
--Description      : Self-checking configurable AXI-Stream AES core TB.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;
use std.textio.all;

entity aes_tb is
end entity;

architecture sim of aes_tb is

  constant C_CLK_PERIOD : time := 10 ns;

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal sim_done : boolean := false;

  signal key_128_tdata  : std_logic_vector(127 downto 0);
  signal key_128_tlast  : std_logic;
  signal key_128_tvalid : std_logic;
  signal key_128_tready : std_logic;
  signal data_128_tdata  : std_logic_vector(127 downto 0);
  signal data_128_tlast  : std_logic;
  signal data_128_tvalid : std_logic;
  signal data_128_tready : std_logic;
  signal out_128_tdata  : std_logic_vector(127 downto 0);
  signal out_128_tlast  : std_logic;
  signal out_128_tvalid : std_logic;
  signal out_128_tready : std_logic;

  signal key_192_tdata  : std_logic_vector(191 downto 0);
  signal key_192_tlast  : std_logic;
  signal key_192_tvalid : std_logic;
  signal key_192_tready : std_logic;
  signal data_192_tdata  : std_logic_vector(127 downto 0);
  signal data_192_tlast  : std_logic;
  signal data_192_tvalid : std_logic;
  signal data_192_tready : std_logic;
  signal out_192_tdata  : std_logic_vector(127 downto 0);
  signal out_192_tlast  : std_logic;
  signal out_192_tvalid : std_logic;
  signal out_192_tready : std_logic;

  signal key_256_tdata  : std_logic_vector(255 downto 0);
  signal key_256_tlast  : std_logic;
  signal key_256_tvalid : std_logic;
  signal key_256_tready : std_logic;
  signal data_256_tdata  : std_logic_vector(127 downto 0);
  signal data_256_tlast  : std_logic;
  signal data_256_tvalid : std_logic;
  signal data_256_tready : std_logic;
  signal out_256_tdata  : std_logic_vector(127 downto 0);
  signal out_256_tlast  : std_logic;
  signal out_256_tvalid : std_logic;
  signal out_256_tready : std_logic;

  procedure wait_cycles(signal clk : in std_logic; count : in natural) is
  begin
    for index in 1 to count loop
      wait until rising_edge(clk);
    end loop;
  end procedure;

  procedure push(
    signal clk    : in std_logic;
    signal tdata  : out std_logic_vector;
    signal tlast  : out std_logic;
    signal tvalid : out std_logic;
    signal tready : in std_logic;
    constant data : in std_logic_vector;
    constant last : in std_logic
  ) is
  begin
    tdata  <= data;
    tlast  <= last;
    tvalid <= '1';
    loop
      wait until rising_edge(clk);
      exit when tready = '1';
    end loop;
    tvalid <= '0';
    tlast  <= '0';
  end procedure;

  procedure pop(
    signal clk    : in std_logic;
    signal tdata  : in std_logic_vector;
    signal tlast  : in std_logic;
    signal tvalid : in std_logic;
    signal tready : out std_logic;
    variable data : out std_logic_vector;
    variable last : out std_logic
  ) is
  begin
    tready <= '1';
    loop
      wait until rising_edge(clk);
      exit when tvalid = '1';
    end loop;
    data := tdata;
    last := tlast;
    tready <= '0';
  end procedure;

  procedure check_block(
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

begin

  aclk <= not aclk after C_CLK_PERIOD / 2 when not sim_done else '0';

  u_aes_128_iter : entity work.aes
    generic map (
      GC_KEY_BITS        => 128,
      GC_PIPELINE_STAGES => 0
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      s_axis_key_tdata  => key_128_tdata,
      s_axis_key_tlast  => key_128_tlast,
      s_axis_key_tvalid => key_128_tvalid,
      s_axis_key_tready => key_128_tready,
      s_axis_tdata      => data_128_tdata,
      s_axis_tlast      => data_128_tlast,
      s_axis_tvalid     => data_128_tvalid,
      s_axis_tready     => data_128_tready,
      m_axis_tdata      => out_128_tdata,
      m_axis_tlast      => out_128_tlast,
      m_axis_tvalid     => out_128_tvalid,
      m_axis_tready     => out_128_tready
    );

  u_aes_192_pipe : entity work.aes
    generic map (
      GC_KEY_BITS        => 192,
      GC_PIPELINE_STAGES => 2
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      s_axis_key_tdata  => key_192_tdata,
      s_axis_key_tlast  => key_192_tlast,
      s_axis_key_tvalid => key_192_tvalid,
      s_axis_key_tready => key_192_tready,
      s_axis_tdata      => data_192_tdata,
      s_axis_tlast      => data_192_tlast,
      s_axis_tvalid     => data_192_tvalid,
      s_axis_tready     => data_192_tready,
      m_axis_tdata      => out_192_tdata,
      m_axis_tlast      => out_192_tlast,
      m_axis_tvalid     => out_192_tvalid,
      m_axis_tready     => out_192_tready
    );

  u_aes_256_full : entity work.aes
    generic map (
      GC_KEY_BITS        => 256,
      GC_PIPELINE_STAGES => 14
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      s_axis_key_tdata  => key_256_tdata,
      s_axis_key_tlast  => key_256_tlast,
      s_axis_key_tvalid => key_256_tvalid,
      s_axis_key_tready => key_256_tready,
      s_axis_tdata      => data_256_tdata,
      s_axis_tlast      => data_256_tlast,
      s_axis_tvalid     => data_256_tvalid,
      s_axis_tready     => data_256_tready,
      m_axis_tdata      => out_256_tdata,
      m_axis_tlast      => out_256_tlast,
      m_axis_tvalid     => out_256_tvalid,
      m_axis_tready     => out_256_tready
    );

  p_stim : process
    variable l          : line;
    variable received   : std_logic_vector(127 downto 0);
    variable received_last : std_logic;
  begin
    key_128_tdata   <= (others => '0');
    key_128_tlast   <= '0';
    key_128_tvalid  <= '0';
    data_128_tdata  <= (others => '0');
    data_128_tlast  <= '0';
    data_128_tvalid <= '0';
    out_128_tready  <= '0';

    key_192_tdata   <= (others => '0');
    key_192_tlast   <= '0';
    key_192_tvalid  <= '0';
    data_192_tdata  <= (others => '0');
    data_192_tlast  <= '0';
    data_192_tvalid <= '0';
    out_192_tready  <= '0';

    key_256_tdata   <= (others => '0');
    key_256_tlast   <= '0';
    key_256_tvalid  <= '0';
    data_256_tdata  <= (others => '0');
    data_256_tlast  <= '0';
    data_256_tvalid <= '0';
    out_256_tready  <= '0';

    aresetn <= '0';
    wait_cycles(aclk, 3);
    aresetn <= '1';
    wait_cycles(aclk, 1);

    push(aclk, key_128_tdata, key_128_tlast, key_128_tvalid, key_128_tready,
         x"000102030405060708090a0b0c0d0e0f", '1');
    out_128_tready <= '0';
    push(aclk, data_128_tdata, data_128_tlast, data_128_tvalid, data_128_tready,
         x"00112233445566778899aabbccddeeff", '1');
    wait_cycles(aclk, 11);
    assert out_128_tvalid = '1'
      report "FAIL: iterative AES output did not wait in output register" severity failure;
    pop(aclk, out_128_tdata, out_128_tlast, out_128_tvalid, out_128_tready,
        received, received_last);
    check_block("AES-128 AXI-Stream output", received,
                x"69c4e0d86a7b0430d8cdb78070b4c55a");
    assert received_last = '1'
      report "FAIL: AES-128 tlast was not preserved" severity failure;

    push(aclk, key_192_tdata, key_192_tlast, key_192_tvalid, key_192_tready,
         x"000102030405060708090a0b0c0d0e0f1011121314151617", '1');
    push(aclk, data_192_tdata, data_192_tlast, data_192_tvalid, data_192_tready,
         x"00112233445566778899aabbccddeeff", '1');
    wait_cycles(aclk, 2);
    out_192_tready <= '0';
    wait_cycles(aclk, 2);
    assert out_192_tvalid = '1'
      report "FAIL: pipelined AES output was not held under backpressure" severity failure;
    pop(aclk, out_192_tdata, out_192_tlast, out_192_tvalid, out_192_tready,
        received, received_last);
    check_block("AES-192 AXI-Stream output", received,
                x"dda97ca4864cdfe06eaf70a0ec0d7191");

    push(aclk, key_256_tdata, key_256_tlast, key_256_tvalid, key_256_tready,
         x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", '1');
    out_256_tready <= '1';
    push(aclk, data_256_tdata, data_256_tlast, data_256_tvalid, data_256_tready,
         x"00112233445566778899aabbccddeeff", '0');
    push(aclk, data_256_tdata, data_256_tlast, data_256_tvalid, data_256_tready,
          x"00112233445566778899aabbccddeeff", '1');
    pop(aclk, out_256_tdata, out_256_tlast, out_256_tvalid, out_256_tready,
        received, received_last);
    check_block("AES-256 pipelined output 0", received,
                x"8ea2b7ca516745bfeafc49904b496089");
    assert received_last = '0'
      report "FAIL: AES-256 first tlast mismatch" severity failure;
    pop(aclk, out_256_tdata, out_256_tlast, out_256_tvalid, out_256_tready,
        received, received_last);
    check_block("AES-256 pipelined output 1", received,
          x"8ea2b7ca516745bfeafc49904b496089");
    assert received_last = '1'
      report "FAIL: AES-256 second tlast mismatch" severity failure;

    write(l, string'("All AES AXI-Stream tests passed."));
    writeline(output, l);
    sim_done <= true;
    wait;
  end process;

end architecture;
