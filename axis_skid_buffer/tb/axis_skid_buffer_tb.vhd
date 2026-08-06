-----------------------------------------------------------------------
--Filename         : axis_skid_buffer_tb.vhd
--Description      : Lean functional testbench for axis_skid_buffer.
--                 : Covers pass-through, skid ordering, prolonged stall,
--                 : overlap throughput, and in-flight reset.
--Author           : Rune Baeverrud
--Current Revision : 3.0
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axis_skid_buffer_tb is
end entity;

architecture sim of axis_skid_buffer_tb is
  -- Testbench clock period.
  -- 100 MHz keeps simulations fast while still human-readable in logs.
  constant TCLK          : time     := 10 ns;

  -- Data width used for both DUT interfaces in this TB.
  -- Keep small to simplify visual inspection of hex values in reports.
  constant C_TDATA_WIDTH : positive := 8;

  -- Global DUT clock and active-low synchronous reset.
  signal aclk          : std_logic := '0';
  signal aresetn       : std_logic := '0';

  -- AXI-Stream slave-side (input) channel to DUT.
  signal s_axis_tdata  : std_logic_vector(C_TDATA_WIDTH-1 downto 0) := (others => '0');
  signal s_axis_tvalid : std_logic := '0';
  signal s_axis_tready : std_logic;

  -- AXI-Stream master-side (output) channel from DUT.
  signal m_axis_tdata  : std_logic_vector(C_TDATA_WIDTH-1 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic := '0';

  -- Test completion flag: also used to stop free-running clock at end.
  signal test_done     : std_logic := '0';

  -- Convenience array type for short expected-data sequences.
  type t_data_vec_array is array (natural range <>) of std_logic_vector(C_TDATA_WIDTH-1 downto 0);

  -- -----------------------------------------------------------------
  -- AXI write helper
  --
  -- Drives one word on slave side and holds tvalid high until DUT
  -- accepts the transfer (tready=1 on a rising edge).
  -- -----------------------------------------------------------------
  procedure axis_write(
    signal   clk    : in  std_logic;
    signal   tdata  : out std_logic_vector;
    signal   tvalid : out std_logic;
    signal   tready : in  std_logic;
    constant data   : in  std_logic_vector
  ) is
  begin
    -- Present payload and request transfer.
    tdata  <= data;
    tvalid <= '1';

    -- Wait for handshake completion.
    loop
      wait until rising_edge(clk);
      exit when tready = '1';
    end loop;

    -- Release valid after accepted beat.
    tvalid <= '0';
  end procedure;

  -- -----------------------------------------------------------------
  -- AXI read helper
  --
  -- Raises master tready, waits for DUT to assert tvalid, then captures
  -- one accepted word and deasserts tready.
  -- -----------------------------------------------------------------
  procedure axis_read(
    signal   clk    : in  std_logic;
    signal   tready : out std_logic;
    signal   tvalid : in  std_logic;
    signal   tdata  : in  std_logic_vector;
    variable data   : out std_logic_vector
  ) is
  begin
    -- Signal sink availability.
    tready <= '1';

    -- Wait until source presents a valid beat.
    loop
      wait until rising_edge(clk);
      exit when tvalid = '1';
    end loop;

    -- Sample payload and stop consuming further data.
    data   := tdata;
    tready <= '0';
  end procedure;

  -- -----------------------------------------------------------------
  -- Data equality checker
  --
  -- Uses severity failure to stop immediately on mismatch so debug is
  -- localized to the first failing scenario.
  -- -----------------------------------------------------------------
  procedure check(
    constant name : in string;
    constant got  : in std_logic_vector;
    constant exp  : in std_logic_vector
  ) is
  begin
    if got /= exp then
      report "FAIL: " & name & " -- got 0x" & to_hstring(got) &
             ", exp 0x" & to_hstring(exp) severity failure;
    else
      report "PASS: " & name & " = 0x" & to_hstring(got) severity note;
    end if;
  end procedure;

  -- -----------------------------------------------------------------
  -- Boolean condition checker
  --
  -- Helper for flag/state assertions (valid/ready conditions, emptiness,
  -- reset postconditions, etc).
  -- -----------------------------------------------------------------
  procedure check_bool(
    constant name : in string;
    constant got  : in boolean
  ) is
  begin
    if not got then
      report "FAIL: " & name severity failure;
    else
      report "PASS: " & name severity note;
    end if;
  end procedure;

begin

  -- Free-running clock while tests are active.
  -- Once test_done is set, clock is forced low so sim naturally idles.
  aclk <= not aclk after TCLK / 2 when test_done = '0' else '0';

  -- DUT instantiation under test.
  -- Same interface is used for both SV and VHDL implementation runs.
  dut : entity work.axis_skid_buffer
    generic map (
      GC_TDATA_WIDTH => C_TDATA_WIDTH
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready
    );

  -- -----------------------------------------------------------------
  -- Main stimulus process
  --
  -- Sequence philosophy:
  --   1) Establish reset baseline.
  --   2) Verify straight-through operation.
  --   3) Verify skid behavior under backpressure.
  --   4) Verify sustained full condition.
  --   5) Verify overlap and reset robustness.
  -- -----------------------------------------------------------------
  p_test : process
    -- Generic readback scratch variable for axis_read helper.
    variable rd : std_logic_vector(C_TDATA_WIDTH-1 downto 0);

    constant C_OVERLAP : t_data_vec_array(0 to 3) := (x"30", x"31", x"32", x"33");

    -- Convenience wrapper for a simple request/response transfer.
    -- This is intentionally sequential: write completes before read.
    procedure push_pop(constant data : in std_logic_vector(C_TDATA_WIDTH-1 downto 0)) is
    begin
      axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, data);
      axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, rd);
      check("push_pop", rd, data);
    end procedure;

    -- Fill both storage slots while output is stalled.
    -- "older" enters first, then "newer" overwrites the pipeline slot.
    procedure fill_two(
      constant older : in std_logic_vector(C_TDATA_WIDTH-1 downto 0);
      constant newer : in std_logic_vector(C_TDATA_WIDTH-1 downto 0)
    ) is
    begin
      axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, older);
      axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, newer);
    end procedure;

    -- Drain two buffered words and verify expected order.
    procedure drain_two_check(
      constant name_prefix : in string;
      constant first_exp   : in std_logic_vector(C_TDATA_WIDTH-1 downto 0);
      constant second_exp  : in std_logic_vector(C_TDATA_WIDTH-1 downto 0)
    ) is
    begin
      axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, rd);
      check(name_prefix & ": first", rd, first_exp);
      axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, rd);
      check(name_prefix & ": second", rd, second_exp);
    end procedure;

    -- Verify sustained full condition and that output data does not glitch
    -- while valid is held and ready is deasserted.
    procedure check_full_stall(
      constant cycles   : in positive;
      constant exp_data : in std_logic_vector(C_TDATA_WIDTH-1 downto 0)
    ) is
    begin
      for i in 0 to cycles - 1 loop
        wait until rising_edge(aclk);
        wait for 1 ps;
        check_bool("full stall: s_ready low", s_axis_tready = '0');
        check_bool("full stall: m_valid high", m_axis_tvalid = '1');
        check("full stall: m_data stable", m_axis_tdata, exp_data);
      end loop;
    end procedure;

    -- One overlap cycle: consume current output and present next input in
    -- the same clock, then verify post-edge output/handshake behavior.
    procedure overlap_step(
      constant next_in : in std_logic_vector(C_TDATA_WIDTH-1 downto 0);
      constant exp_out : in std_logic_vector(C_TDATA_WIDTH-1 downto 0)
    ) is
    begin
      s_axis_tdata  <= next_in;
      s_axis_tvalid <= '1';
      m_axis_tready <= '1';
      wait until rising_edge(aclk);
      wait for 1 ps;
      check_bool("overlap: s_ready high", s_axis_tready = '1');
      check_bool("overlap: m_valid high", m_axis_tvalid = '1');
      check("overlap: output sequence", m_axis_tdata, exp_out);
    end procedure;

    -- Constrained-random stress phase with an in-process reference model.
    -- The model mirrors the DUT's EMPTY/ONE/TWO behavior and checks
    -- handshake outputs + payload on every cycle.
    procedure stress_random_reference(
      constant cycles : in positive;
      constant seed0  : in unsigned(15 downto 0)
    ) is
      variable prng        : unsigned(15 downto 0);
      variable drive_valid : std_logic;
      variable drive_ready : std_logic;
      variable drive_data  : std_logic_vector(C_TDATA_WIDTH-1 downto 0);

      variable model_state : std_logic_vector(1 downto 0);
      variable model_pipe  : std_logic_vector(C_TDATA_WIDTH-1 downto 0);
      variable model_skid  : std_logic_vector(C_TDATA_WIDTH-1 downto 0);
    begin
      prng        := seed0;
      model_state := "10"; -- EMPTY
      model_pipe  := (others => '0');
      model_skid  := (others => '0');

      s_axis_tvalid <= '0';
      m_axis_tready <= '0';
      wait until rising_edge(aclk);
      wait for 1 ps;
      if m_axis_tvalid /= '0' then
        report "FAIL: stress: initial empty" severity failure;
      end if;

      for i in 0 to cycles - 1 loop
        -- 16-bit LFSR taps: 16,14,13,11
        prng := prng(14 downto 0) & (prng(15) xor prng(13) xor prng(12) xor prng(10));

        drive_valid := prng(0);
        drive_ready := prng(1);
        drive_data  := std_logic_vector(prng(7 downto 0));

        -- Light constraints to hit push/stall combinations frequently.
        if (i mod 17) = 0 then
          drive_valid := '1';
        end if;
        if (i mod 19) = 0 then
          drive_ready := '0';
        end if;

        s_axis_tdata  <= drive_data;
        s_axis_tvalid <= drive_valid;
        m_axis_tready <= drive_ready;

        wait until rising_edge(aclk);
        wait for 1 ps;

        -- The DUT registers the next state at this edge, so update the
        -- reference model before checking the post-edge outputs.
        case model_state is
          when "10" => -- EMPTY
            if drive_valid = '1' then
              model_pipe  := drive_data;
              model_state := "11";
            end if;

          when "11" => -- ONE
            if drive_ready = '1' then
              if drive_valid = '1' then
                model_pipe  := drive_data;
                model_state := "11";
              else
                model_state := "10";
              end if;
            else
              if drive_valid = '1' then
                model_skid  := model_pipe;
                model_pipe  := drive_data;
                model_state := "01";
              end if;
            end if;

          when "01" => -- TWO
            if drive_ready = '1' then
              model_pipe  := model_skid;
              model_state := "11";
            end if;

          when others =>
            model_state := "10";
        end case;

        if s_axis_tready /= model_state(1) then
          report "FAIL: stress: s_ready mismatch" severity failure;
        end if;
        if m_axis_tvalid /= model_state(0) then
          report "FAIL: stress: m_valid mismatch" severity failure;
        end if;
        if model_state(0) = '1' and m_axis_tdata /= model_pipe then
          report "FAIL: stress: m_data mismatch -- got 0x" & to_hstring(m_axis_tdata) &
                 ", exp 0x" & to_hstring(model_pipe) severity failure;
        end if;
      end loop;

      -- Drain any residual model content.
      s_axis_tvalid <= '0';
      m_axis_tready <= '1';
      while model_state /= "10" loop
        wait for 1 ps;

        if m_axis_tvalid /= '1' then
          report "FAIL: stress drain: m_valid low while model non-empty" severity failure;
        end if;
        if m_axis_tdata /= model_pipe then
          report "FAIL: stress drain: m_data mismatch -- got 0x" & to_hstring(m_axis_tdata) &
                 ", exp 0x" & to_hstring(model_pipe) severity failure;
        end if;

        wait until rising_edge(aclk);
        wait for 1 ps;

        case model_state is
          when "11" =>
            model_state := "10";
          when "01" =>
            model_pipe  := model_skid;
            model_state := "11";
          when others =>
            model_state := "10";
        end case;
      end loop;

      wait until rising_edge(aclk);
      s_axis_tvalid <= '0';
      m_axis_tready <= '0';
      wait for 1 ps;
      if m_axis_tvalid /= '0' then
        report "FAIL: stress: final empty" severity failure;
      end if;
    end procedure;

    -- Utility to assert output channel is empty.
    -- 1 ps wait allows combinational outputs to settle after control
    -- changes in the same simulation time step.
    procedure expect_empty(constant name : in string) is
    begin
      wait for 1 ps;
      check_bool(name, m_axis_tvalid = '0');
    end procedure;

  begin
    -- Initialize interface controls before releasing reset.
    aresetn <= '0';
    s_axis_tvalid <= '0';
    m_axis_tready <= '0';

    -- Hold reset for a few cycles to guarantee deterministic startup.
    for i in 0 to 3 loop
      wait until rising_edge(aclk);
    end loop;

    -- Release reset and verify empty baseline.
    aresetn <= '1';
    wait until rising_edge(aclk);
    expect_empty("reset: empty");

    -- ---------------------------------------------------------------
    -- Test 1: basic pass-through smoke test
    --
    -- No intentional backpressure. Each payload must be returned intact.
    -- ---------------------------------------------------------------
    report "=== Test 1: passthrough smoke ===";
    push_pop(x"AB");
    push_pop(x"CD");

    -- ---------------------------------------------------------------
    -- Test 2: ordering while output is stalled
    --
    -- With m_ready low, second write causes skid capture behavior.
    -- Expected read order for this DUT architecture:
    --   first  = newest word in pipeline
    --   second = older word moved from skid
    -- ---------------------------------------------------------------
    report "=== Test 2: skid ordering under stall ===";
    m_axis_tready <= '0';
    fill_two(x"AA", x"BB");
    drain_two_check("stall order", x"BB", x"AA");
    expect_empty("stall order: empty");

    -- ---------------------------------------------------------------
    -- Test 3: prolonged full stall
    --
    -- Fill internal storage to max depth, keep sink blocked, and verify
    -- interface flags remain stable across multiple cycles.
    -- ---------------------------------------------------------------
    report "=== Test 3: prolonged full stall ===";
    m_axis_tready <= '0';
    fill_two(x"A1", x"B2");
    check_full_stall(5, x"B2");
    drain_two_check("full stall", x"B2", x"A1");
    expect_empty("full stall: empty");

    -- ---------------------------------------------------------------
    -- Test 4: overlap throughput (steady ONE->ONE behavior)
    --
    -- Prime ONE state with first word, then on each cycle consume current
    -- output while presenting next input. Full sequence order is checked.
    -- ---------------------------------------------------------------
    report "=== Test 4: overlap throughput (ONE->ONE) ===";
    m_axis_tready <= '0';
    axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready, C_OVERLAP(0));
    overlap_step(C_OVERLAP(1), C_OVERLAP(1));
    overlap_step(C_OVERLAP(2), C_OVERLAP(2));
    overlap_step(C_OVERLAP(3), C_OVERLAP(3));

    -- Stop source, then drain/check final retained word.
    s_axis_tvalid <= '0';
    axis_read(aclk, m_axis_tready, m_axis_tvalid, m_axis_tdata, rd);
    check("overlap: final word", rd, C_OVERLAP(3));
    expect_empty("overlap: empty");

    -- ---------------------------------------------------------------
    -- Test 5: in-flight reset
    --
    -- Assert reset while data is buffered, verify state clears, then
    -- verify DUT still accepts and forwards data post-reset.
    -- ---------------------------------------------------------------
    report "=== Test 5: in-flight reset ===";
    m_axis_tready <= '0';
    fill_two(x"99", x"88");

    -- Trigger reset while potentially non-empty.
    aresetn <= '0';
    wait until rising_edge(aclk);
    wait until rising_edge(aclk);

    -- Release reset and check clean restart behavior.
    aresetn <= '1';
    wait until rising_edge(aclk);
    expect_empty("reset mid-flight: empty");
    check_bool("reset mid-flight: s_ready high", s_axis_tready = '1');
    push_pop(x"77");
    expect_empty("reset mid-flight: functional");

    -- ---------------------------------------------------------------
    -- Test 6: constrained-random stress + cycle-accurate reference
    --
    -- Runs randomized valid/ready traffic and checks every cycle
    -- against a local reference model of EMPTY/ONE/TWO behavior.
    -- ---------------------------------------------------------------
    report "=== Test 6: constrained-random stress ===";
    stress_random_reference(300, to_unsigned(16#ACE1#, 16));

    -- End-of-test marker and clean stop.
    report "*** ALL TESTS PASSED ***" severity note;
    test_done <= '1';
    wait;
  end process;

end architecture;
