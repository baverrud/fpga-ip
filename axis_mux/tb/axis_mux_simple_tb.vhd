-----------------------------------------------------------------------
--Filename         : axis_mux_simple_tb.vhd
--Description      : Small hand-editable smoke test for axis_mux.
--                 : Keeps the stimulus intentionally simple so a user can
--                 : extend it while watching the waveform window.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axis_bfm_pkg.all;
use work.util_pkg.all;

entity axis_mux_simple_tb is
end entity axis_mux_simple_tb;

architecture sim of axis_mux_simple_tb is
  constant C_CLK_PERIOD : time := 10 ns;
  constant C_WIDTH      : positive := 8;
  constant C_INPUTS     : positive := 2;
  constant C_DEPTH      : positive := 4;

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';

  signal s_axis_tdata  : slv_array_t(0 to C_INPUTS-1)(C_WIDTH-1 downto 0) :=
    (others => (others => '0'));
  signal s_axis_tvalid : std_logic_vector(0 to C_INPUTS-1) := (others => '0');
  signal s_axis_tready : std_logic_vector(0 to C_INPUTS-1);

  signal m_axis_tdata  : std_logic_vector(C_WIDTH-1 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic := '0';
  signal fifo_count    : unsigned(log2ceil(C_DEPTH) downto 0);
  signal test_done     : std_logic := '0';
begin

  -- USER SMOKE-TEST AREA: keep the clock and reset below, then add stimulus
  -- to the process. The DUT signal names intentionally match the ports.
  aclk <= not aclk after C_CLK_PERIOD / 2 when test_done = '0' else '0';

  dut : entity work.axis_mux
    generic map (
      GC_NUM_INPUTS  => C_INPUTS,
      GC_TDATA_WIDTH => C_WIDTH,
      GC_FIFO_DEPTH  => C_DEPTH
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,
      fifo_count    => fifo_count
    );

  process
    variable received_word : std_logic_vector(C_WIDTH-1 downto 0);
  begin
    aresetn <= '0';
    m_axis_tready <= '0';
    wait for C_CLK_PERIOD * 2;
    aresetn <= '1';
    wait until rising_edge(aclk);

    -- One beat from each source demonstrates the basic mux data path.
    axis_write(aclk, s_axis_tdata(0), s_axis_tvalid(0), s_axis_tready(0), x"11");
    axis_write(aclk, s_axis_tdata(1), s_axis_tvalid(1), s_axis_tready(1), x"22");

    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, received_word);
    assert received_word = x"11"
      report "FAIL: simple test expected source zero first"
      severity failure;
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, received_word);
    assert received_word = x"22"
      report "FAIL: simple test expected source one second"
      severity failure;

    report "axis_mux simple smoke test passed";
    test_done <= '1';
    wait;
  end process;

end architecture sim;
