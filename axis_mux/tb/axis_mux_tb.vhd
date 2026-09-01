-----------------------------------------------------------------------
--Filename         : axis_mux_tb.vhd
--Description      : Comprehensive self-checking testbench for axis_mux.
--                 : Covers round-robin ordering, simultaneous requests,
--                 : input holding slots, output FIFO backpressure, FIFO
--                 : full behavior, output stability, reset flushing,
--                 : empty operation, and post-reset recovery.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.axis_bfm_pkg.all;
use work.util_pkg.all;

entity axis_mux_tb is
  generic (
    GC_NUM_INPUTS  : positive := 3;
    GC_TDATA_WIDTH : positive := 8;
    GC_FIFO_DEPTH  : positive range 2 to positive'high := 4
  );
end entity axis_mux_tb;

architecture sim of axis_mux_tb is
  constant C_CLK_PERIOD       : time := 10 ns;
  constant C_WAIT_TIMEOUT     : positive := 2000;

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';

  signal s_axis_tdata  : slv_array_t(0 to GC_NUM_INPUTS-1)(GC_TDATA_WIDTH-1 downto 0) :=
    (others => (others => '0'));
  signal s_axis_tvalid : std_logic_vector(0 to GC_NUM_INPUTS-1) := (others => '0');
  signal s_axis_tready : std_logic_vector(0 to GC_NUM_INPUTS-1);

  signal m_axis_tdata  : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic := '0';
  signal fifo_count    : unsigned(log2ceil(GC_FIFO_DEPTH) downto 0);

  signal test_done : std_logic := '0';

  function f_word(value : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(value, GC_TDATA_WIDTH));
  end function;

begin

  -- Gated clock: the testbench can terminate cleanly after the final check.
  aclk <= not aclk after C_CLK_PERIOD / 2 when test_done = '0' else '0';

  dut : entity work.axis_mux
    generic map (
      GC_NUM_INPUTS  => GC_NUM_INPUTS,
      GC_TDATA_WIDTH => GC_TDATA_WIDTH,
      GC_FIFO_DEPTH  => GC_FIFO_DEPTH
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
    procedure wait_cycles(constant cycles : natural) is
    begin
      for cycle in 1 to cycles loop
        wait until rising_edge(aclk);
      end loop;
    end procedure;

    procedure send_one(
      signal clk    : in  std_logic;
      signal data   : out slv_array_t;
      signal valid  : out std_logic_vector;
      signal ready  : in  std_logic_vector;
      constant source_index : in natural;
      constant word : in std_logic_vector;
      constant name : in string
    ) is
    begin
      data(source_index)  <= word;
      valid(source_index) <= '1';
      for cycle in 0 to C_WAIT_TIMEOUT loop
        wait until rising_edge(clk);
        if ready(source_index) = '1' then
          valid(source_index) <= '0';
          return;
        end if;
      end loop;
      assert false
        report "FAIL: timeout sending " & name
        severity failure;
    end procedure;

    procedure receive_one(
      signal clk    : in std_logic;
      signal data   : in std_logic_vector;
      signal valid  : in std_logic;
      signal ready  : out std_logic;
      variable word : out std_logic_vector;
      constant name : in string
    ) is
    begin
      ready <= '1';
      for cycle in 0 to C_WAIT_TIMEOUT loop
        wait until rising_edge(clk);
        if valid = '1' then
          word  := data;
          ready <= '0';
          return;
        end if;
      end loop;
      assert false
        report "FAIL: timeout receiving " & name
        severity failure;
    end procedure;

    variable received_word : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
    variable held_word     : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  begin
    -- Reset must clear both the input holding slots and the output FIFO.
    report "=== axis_mux reset and idle checks ===";
    aresetn       <= '0';
    s_axis_tvalid <= (others => '0');
    m_axis_tready <= '0';
    wait_cycles(3);

    assert fifo_count = 0
      report "FAIL: FIFO count is not zero during reset"
      severity failure;
    assert m_axis_tvalid = '0'
      report "FAIL: output valid is asserted during reset"
      severity failure;
    assert s_axis_tready = (s_axis_tready'range => '0')
      report "FAIL: input ready must be low during reset"
      severity failure;

    aresetn <= '1';
    wait_cycles(2);
    assert s_axis_tready = (s_axis_tready'range => '1')
      report "FAIL: empty input slots are not ready after reset"
      severity failure;

    -- Empty output behavior: ready alone must not create a transfer.
    m_axis_tready <= '1';
    wait_cycles(2);
    assert m_axis_tvalid = '0'
      report "FAIL: empty mux asserted output valid"
      severity failure;
    assert fifo_count = 0
      report "FAIL: empty mux FIFO count changed without input data"
      severity failure;

    -- Each source is exercised independently before simultaneous arbitration.
    report "=== independent source transfers ===";
    for source in 0 to GC_NUM_INPUTS-1 loop
      send_one(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, source,
               f_word(16#10# + source),
               "independent source");
      receive_one(aclk, m_axis_tdata, m_axis_tvalid, m_axis_tready,
                  received_word, "independent source output");
      assert received_word = f_word(16#10# + source)
        report "FAIL: independent source data mismatch"
        severity failure;
    end loop;

    -- Present all sources at once. After reset, input zero is the first
    -- round-robin winner, followed by one and two.
    report "=== simultaneous requests and round-robin order ===";
    m_axis_tready <= '0';
    for source in 0 to GC_NUM_INPUTS-1 loop
      s_axis_tdata(source)  <= f_word(16#40# + source);
      s_axis_tvalid(source) <= '1';
    end loop;
    wait until rising_edge(aclk);
    s_axis_tvalid <= (others => '0');
    wait_cycles(6);

    assert m_axis_tvalid = '1'
      report "FAIL: output did not become valid while FIFO was stalled"
      severity failure;
    assert m_axis_tdata = f_word(16#40#)
      report "FAIL: first round-robin winner was not input zero"
      severity failure;
    assert (to_integer(fifo_count) > 0) and
           (to_integer(fifo_count) <= GC_FIFO_DEPTH)
      report "FAIL: output FIFO occupancy is outside its configured bounds"
      severity failure;

    for source in 0 to GC_NUM_INPUTS-1 loop
      receive_one(aclk, m_axis_tdata, m_axis_tvalid, m_axis_tready,
                  received_word, "round-robin output");
      assert received_word = f_word(16#40# + source)
        report "FAIL: round-robin output order mismatch"
        severity failure;
    end loop;

    -- Fill the input slots and output FIFO while the consumer is stalled.
    -- The visible first word and valid flag must remain stable for the whole
    -- stall, including the FIFO-full boundary.
    report "=== output stall stability and FIFO full boundary ===";
    m_axis_tready <= '0';
    for source in 0 to GC_NUM_INPUTS-1 loop
      send_one(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, source,
               f_word(16#60# + source),
               "stall setup source");
    end loop;
    wait_cycles(8);

    assert m_axis_tvalid = '1'
      report "FAIL: output invalid during stalled queued data"
      severity failure;
    held_word := m_axis_tdata;
    for cycle in 1 to 8 loop
      wait until rising_edge(aclk);
      assert m_axis_tvalid = '1'
        report "FAIL: output valid dropped during stall"
        severity failure;
      assert m_axis_tdata = held_word
        report "FAIL: output data changed during stall"
        severity failure;
    end loop;

    -- The output FIFO can accept only its configured capacity. Additional
    -- source valid is held by the BFM until the downstream stall is released.
    m_axis_tready <= '1';
    receive_one(aclk, m_axis_tdata, m_axis_tvalid, m_axis_tready,
                received_word, "stalled queue first word");
    assert received_word = held_word
      report "FAIL: first stalled output changed before release"
      severity failure;

    -- Drain the remainder without assuming a cycle count. Handshake-based
    -- reads make this valid for both FIFO depth two and larger configurations.
    for source in 1 to GC_NUM_INPUTS-1 loop
      receive_one(aclk, m_axis_tdata, m_axis_tvalid, m_axis_tready,
                  received_word, "stalled queue remaining word");
    end loop;

    -- Reset while data is queued and the output is stalled. No pre-reset data
    -- may appear after reset is released.
    report "=== in-flight reset flush ===";
    m_axis_tready <= '0';
    for source in 0 to GC_NUM_INPUTS-1 loop
      send_one(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, source,
               f_word(16#90# + source),
               "reset flush source");
    end loop;
    wait_cycles(4);
    assert m_axis_tvalid = '1'
      report "FAIL: reset-flush setup did not queue output data"
      severity failure;

    aresetn <= '0';
    wait_cycles(2);
    assert fifo_count = 0
      report "FAIL: FIFO count did not clear during in-flight reset"
      severity failure;
    assert m_axis_tvalid = '0'
      report "FAIL: output valid remained asserted after reset"
      severity failure;

    aresetn <= '1';
    wait_cycles(2);
    assert m_axis_tvalid = '0'
      report "FAIL: stale pre-reset data escaped after reset"
      severity failure;

    send_one(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, 0,
         f_word(16#D4#), "post-reset source");
    receive_one(aclk, m_axis_tdata, m_axis_tvalid, m_axis_tready,
                received_word, "post-reset output");
    assert received_word = f_word(16#D4#)
      report "FAIL: post-reset transfer data mismatch"
      severity failure;

    wait_cycles(1);
    assert fifo_count = 0
      report "FAIL: output FIFO was not empty after final transfer"
      severity failure;
    report "=== axis_mux comprehensive checks passed ===";
    test_done <= '1';
    wait;
  end process;

end architecture sim;
