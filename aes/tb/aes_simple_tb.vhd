-----------------------------------------------------------------------
--Filename         : aes_simple_tb.vhd
--Description      : Hand-editable AXI-Stream AES smoke-test TB.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;
use std.textio.all;

entity aes_simple_tb is
end entity;

architecture sim of aes_simple_tb is

  constant C_CLK_PERIOD : time := 10 ns;

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal sim_done : boolean := false;

  signal s_axis_key_tdata  : std_logic_vector(127 downto 0);
  signal s_axis_key_tlast  : std_logic;
  signal s_axis_key_tvalid : std_logic;
  signal s_axis_key_tready : std_logic;
  signal s_axis_tdata  : std_logic_vector(127 downto 0);
  signal s_axis_tlast  : std_logic;
  signal s_axis_tvalid : std_logic;
  signal s_axis_tready : std_logic;
  signal m_axis_tdata  : std_logic_vector(127 downto 0);
  signal m_axis_tlast  : std_logic;
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic;

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
    constant data : in std_logic_vector
  ) is
  begin
    tdata  <= data;
    tlast  <= '1';
    tvalid <= '1';
    loop
      wait until rising_edge(clk);
      exit when tready = '1';
    end loop;
    tvalid <= '0';
    tlast  <= '0';
  end procedure;

begin

  aclk <= not aclk after C_CLK_PERIOD / 2 when not sim_done else '0';

  u_dut : entity work.aes
    generic map (
      GC_KEY_BITS        => 128,
      GC_PIPELINE_STAGES => 0
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      s_axis_key_tdata  => s_axis_key_tdata,
      s_axis_key_tlast  => s_axis_key_tlast,
      s_axis_key_tvalid => s_axis_key_tvalid,
      s_axis_key_tready => s_axis_key_tready,
      s_axis_tdata      => s_axis_tdata,
      s_axis_tlast      => s_axis_tlast,
      s_axis_tvalid     => s_axis_tvalid,
      s_axis_tready     => s_axis_tready,
      m_axis_tdata      => m_axis_tdata,
      m_axis_tlast      => m_axis_tlast,
      m_axis_tvalid     => m_axis_tvalid,
      m_axis_tready     => m_axis_tready
    );

  p_stim : process
    variable l : line;
  begin
    s_axis_key_tdata  <= (others => '0');
    s_axis_key_tlast  <= '0';
    s_axis_key_tvalid <= '0';
    s_axis_tdata      <= (others => '0');
    s_axis_tlast      <= '0';
    s_axis_tvalid     <= '0';
    m_axis_tready     <= '0';

    aresetn <= '0';
    wait_cycles(aclk, 3);
    aresetn <= '1';

    push(aclk, s_axis_key_tdata, s_axis_key_tlast, s_axis_key_tvalid,
         s_axis_key_tready, x"000102030405060708090a0b0c0d0e0f");

    -- USER SMOKE-TEST AREA: add AXI-Stream transactions and waveform checks here.
    push(aclk, s_axis_tdata, s_axis_tlast, s_axis_tvalid, s_axis_tready,
         x"00112233445566778899aabbccddeeff");
    m_axis_tready <= '1';
    loop
      wait until rising_edge(aclk);
      exit when m_axis_tvalid = '1';
    end loop;
    assert m_axis_tdata = x"69c4e0d86a7b0430d8cdb78070b4c55a"
      report "FAIL: AES smoke-test mismatch" severity failure;

    write(l, string'("AES smoke test passed."));
    writeline(output, l);
    sim_done <= true;
    wait;
  end process;

end architecture;
