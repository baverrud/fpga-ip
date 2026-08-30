-----------------------------------------------------------------------
--Filename         : axis_cdc_tb.vhd
--Description      : Self-checking testbench for axis_cdc.
--                 :  - Two unrelated (coprime) clocks: 100 MHz source,
--                 :    76.9 MHz destination -> constant phase drift.
--                 :  - Phase A: LINE-RATE proof. Default run (source
--                 :    faster): the destination must accept one word per
--                 :    destination clock. Reverse run ([tb:rev], destination
--                 :    faster): the source must accept one word per source
--                 :    clock with no backpressure.
--                 :  - Phase B: order + integrity with destination
--                 :    backpressure. The destination stalls until the FIFO
--                 :    fills, then uses a ready 3-of-4 cycle pattern.
--                 :  - Phase C: queued-data reset recovery. Reset is
--                 :    asserted while output valid is stalled and source
--                 :    valid remains high. Queued data must be flushed and
--                 :    the link must resume cleanly.
--                 :  - Phase D: source-side valid gaps - a 1-in-4 valid
--                 :    gap pattern must not lose or reorder words.
--                 :  - Output data/valid stability is checked throughout
--                 :    every destination stall.
--                 :  - Watchdog to catch deadlocks instead of hanging.
--Author           : Rune Baeverrud
--Current Revision : 2.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity axis_cdc_tb is
  generic (
    -- Parameters for the device under test and the two clock domains. The
    -- The manifest runs this testbench over payload-width, FIFO-depth,
    -- synchronizer-stage, and clock-ratio boundary configurations.
    -- The [tb:*] sections override these generics via the 'generics'
    -- metadata, which run.py passes to the simulator.
    GC_TDATA_WIDTH : positive := 16;  -- payload width under test
    GC_CDC_DEPTH   : positive := 8;   -- FIFO depth under test (power of two)
    GC_SYNC_STAGES : positive := 2;   -- synchronizer stages under test (2..4)
    GC_TS          : time := 10 ns;   -- source clock period (100 MHz)
    GC_TM          : time := 13 ns;   -- destination clock period (~76.9 MHz)
    -- Depth 2 and 4 are safe but may insert bubbles because synchronized
    -- pointers make their usable capacity too small for sustained line rate.
    GC_EXPECT_LINE_RATE : boolean := true
  );
end entity;

architecture sim of axis_cdc_tb is

  -- DUT and clock parameters are aliases of the generics so the body is
  -- identical in every configuration. The default periods (10 ns and 13 ns)
  -- are intentionally coprime so the clock edges drift continuously,
  -- exercising a real asynchronous clock relationship rather than a fixed
  -- phase offset.
  constant C_TDATA_WIDTH : positive := GC_TDATA_WIDTH;
  constant C_CDC_DEPTH   : positive := GC_CDC_DEPTH;
  constant C_SYNC_STAGES : positive := GC_SYNC_STAGES;
  constant TS            : time := GC_TS;               -- source clock period
  constant TM            : time := GC_TM;               -- destination clock period

  constant C_NUM_WORDS    : natural := 128;  -- phase A (line-rate) count
  constant C_NUM_WORDS_B  : natural := 4*C_CDC_DEPTH + 32;  -- phase B count
  constant C_RESET_WORD_INDEX : natural := 255;  -- distinct pre-reset marker
  constant C_RESUME_WORDS : natural := 16;   -- phase C (recovery) count
  constant C_GAP_WORDS    : natural := 32;   -- phase D (source gaps) count

  -- Source domain signals
  signal s_clk    : std_logic := '0';
  signal aresetn  : std_logic := '0';
  signal s_tdata  : std_logic_vector(C_TDATA_WIDTH-1 downto 0) := (others => '0');
  signal s_tvalid : std_logic := '0';
  signal s_tready : std_logic;

  -- Destination domain signals
  signal m_clk : std_logic := '0';
  signal m_tdata  : std_logic_vector(C_TDATA_WIDTH-1 downto 0);
  signal m_tvalid : std_logic;
  signal m_tready : std_logic := '0';

  -- Cross-domain TB control (see the reset controller below).
  signal phase_a_done  : std_logic := '0';  -- phase A received (m domain)
  signal phase_b_done  : std_logic := '0';  -- phase B received (m domain)
  signal phase_b       : std_logic := '0';  -- enables backpressure pattern
  signal phase_reset_fill  : std_logic := '0';  -- holds destination stalled
  signal phase_reset_start : std_logic := '0';  -- starts queued-data reset setup
  signal source_backpressure_seen : std_logic := '0';  -- FIFO reached backpressure
  signal reset_data_queued : std_logic := '0';  -- source accepted pre-reset data
  signal phase_c_start : std_logic := '0';  -- permission to start phase C
  signal phase_c_done  : std_logic := '0';  -- phase C received (m domain)
  signal phase_d_start : std_logic := '0';  -- permission to start phase D

  -- Completion flag: stops both clocks so batch simulation can end.
  signal test_done : std_logic := '0';

  -- Expected word for index i. Every payload bit varies over the sequence,
  -- and widths down to one bit are legal. For widths of at least eight bits,
  -- each byte contains the counter or its complement.
  function f_word(i : natural) return std_logic_vector is
    variable v : std_logic_vector(C_TDATA_WIDTH-1 downto 0) := (others => '0');
  begin
    for bit_index in v'range loop
      if (((i / (2 ** (bit_index mod 8))) + (bit_index / 8)) mod 2) = 1 then
        v(bit_index) := '1';
      end if;
    end loop;
    return v;
  end function;

begin

  -- ==================================================================
  -- Device under test
  -- ==================================================================
  u_dut : entity work.axis_cdc
    generic map (
      GC_TDATA_WIDTH => C_TDATA_WIDTH,
      GC_CDC_DEPTH   => C_CDC_DEPTH,
      GC_SYNC_STAGES => C_SYNC_STAGES
    )
    port map (
      s_axis_aclk   => s_clk,
      aresetn       => aresetn,
      s_axis_tdata  => s_tdata,
      s_axis_tvalid => s_tvalid,
      s_axis_tready => s_tready,
      m_axis_aclk   => m_clk,
      m_axis_tdata  => m_tdata,
      m_axis_tvalid => m_tvalid,
      m_axis_tready => m_tready
    );

  -- ==================================================================
  -- Clock generators (gated on test_done so 'run -all' terminates)
  -- ==================================================================
  s_clk_gen : process
  begin
    s_clk <= '0';
    wait for TS * 2;  -- hold low before the first rising edge
    loop
      if test_done = '1' then
        s_clk <= '0';
        wait;
      end if;
      s_clk <= not s_clk;
      wait for TS / 2;
    end loop;
  end process;

  m_clk_gen : process
  begin
    m_clk <= '0';
    wait for TM * 2;
    loop
      if test_done = '1' then
        m_clk <= '0';
        wait;
      end if;
      m_clk <= not m_clk;
      wait for TM / 2;
    end loop;
  end process;

  -- ==================================================================
  -- Shared reset / phase controller (m domain)
  -- ==================================================================
  -- Orchestrates the three phases:
  --   * Releases the shared reset at start.
  --   * After phase A completes, enables the backpressure pattern.
  --   * After phase B completes, pulses the shared reset to prove
  --     the link recovers, then allows phase C to begin.
  p_reset_ctrl : process
  begin
    aresetn       <= '0';
    phase_b       <= '0';
    phase_reset_fill  <= '0';
    phase_reset_start <= '0';
    phase_c_start <= '0';
    wait until rising_edge(m_clk);
    wait until rising_edge(m_clk);
    assert s_tready = '0'
      report "FAIL: source ready asserted during reset"
      severity failure;
    assert m_tvalid = '0'
      report "FAIL: destination valid asserted during reset"
      severity failure;

    for i in 1 to 5 loop          -- initial release
      wait until rising_edge(m_clk);
    end loop;
    aresetn <= '1';

    wait until phase_a_done = '1';
    wait until rising_edge(m_clk);
    assert m_tvalid = '0'
      report "FAIL: destination valid remained asserted after FIFO drained"
      severity failure;
    phase_b <= '1';               -- enable backpressure for phase B

    wait until phase_b_done = '1';
    phase_b <= '0';
    phase_reset_fill <= '1';       -- stall output while queuing reset data
    wait until rising_edge(m_clk);
    phase_reset_start <= '1';
    wait until reset_data_queued = '1';
    wait until m_tvalid = '1';
    aresetn <= '0';               -- flush queued and stalled-valid data
    wait for 1 ps;
    assert s_tready = '0'
      report "FAIL: source ready did not clear asynchronously"
      severity failure;
    assert m_tvalid = '0'
      report "FAIL: destination valid did not clear asynchronously"
      severity failure;
    wait until rising_edge(m_clk);
    wait until rising_edge(m_clk);
    assert s_tready = '0'
      report "FAIL: source ready asserted during reset pulse"
      severity failure;
    assert m_tvalid = '0'
      report "FAIL: destination valid asserted during reset pulse"
      severity failure;
    for i in 1 to 5 loop
      wait until rising_edge(m_clk);
    end loop;
    aresetn <= '1';
    phase_reset_fill <= '0';

    phase_c_start <= '1';         -- allow phase C

    wait until phase_c_done = '1';
    phase_d_start <= '1';         -- allow phase D (source gaps)
    wait;
  end process;

  -- ==================================================================
  -- Source stimulus (s domain)
  -- ==================================================================
  p_stim : process
    variable v_sent   : natural := 0;
    variable v_cycles : natural := 0;
    variable v_gap    : natural := 0;
    variable v_backpressure_seen : boolean := false;
    variable l : line;
  begin
    -- Wait for the shared reset controller to release both domains.
    s_tvalid  <= '0';
    s_tdata   <= (others => '0');
    wait until aresetn = '1';
    wait until rising_edge(s_clk);
    wait until rising_edge(s_clk);

    -- Phase A: continuous streaming at the source's maximum rate.
    --  * Default direction (source faster): the sustained source rate is
    --    destination-limited; the line-rate proof runs on the DESTINATION
    --    side (see p_check), which must drain one word per destination
    --    clock while being fed by a faster producer.
    --  * Reverse direction (destination faster): the source is the
    --    bottleneck and must accept one word per source clock - any
    --    tready deassertion here is a failure.
    v_sent   := 0;
    v_cycles := 0;
    s_tvalid <= '1';
    while v_sent < C_NUM_WORDS loop
      s_tdata <= f_word(v_sent);
      wait until rising_edge(s_clk);
      if s_tready = '1' then
        v_sent := v_sent + 1;
      end if;
      if GC_EXPECT_LINE_RATE and (GC_TM < GC_TS) and (s_tready = '0') then
        report "FAIL: source back-pressured during line-rate phase (reverse direction)"
          severity failure;
      end if;
      v_cycles := v_cycles + 1;
    end loop;
    s_tvalid <= '0';

    if GC_TM < GC_TS then
      write(l, string'("Stim: phase A sent " & integer'image(v_sent) &
                       " words in " & integer'image(v_cycles) &
                       " src cycles (source line rate)"));
    else
      write(l, string'("Stim: phase A sent " & integer'image(v_sent) &
                       " words in " & integer'image(v_cycles) &
                       " src cycles (dest-limited)"));
    end if;
    writeline(output, l);

    -- Phase B: continue the sequence under destination backpressure.
    wait until phase_b = '1';
    wait until rising_edge(s_clk);

    v_sent := C_NUM_WORDS;
    v_backpressure_seen := false;
    source_backpressure_seen <= '0';
    s_tvalid <= '1';
    while v_sent < C_NUM_WORDS + C_NUM_WORDS_B loop
      s_tdata <= f_word(v_sent);
      wait until rising_edge(s_clk);
      if s_tready = '1' then
        v_sent := v_sent + 1;
      else
        v_backpressure_seen := true;
        source_backpressure_seen <= '1';
      end if;
    end loop;
    s_tvalid <= '0';
    assert v_backpressure_seen
      report "FAIL: source never observed full-FIFO backpressure"
      severity failure;
    write(l, string'("Stim: phase B sent " & integer'image(v_sent) & " words"));
    writeline(output, l);

    -- Queue data while the destination is held stalled. Keep source valid
    -- asserted with the next word until reset is observed, so reset occurs
    -- with both queued data and active source traffic.
    wait until phase_reset_start = '1';
    s_tvalid <= '1';
    s_tdata  <= f_word(C_RESET_WORD_INDEX);
    loop
      wait until rising_edge(s_clk);
      if s_tready = '1' then
        reset_data_queued <= '1';
        exit;
      end if;
    end loop;
    wait until aresetn = '0';
    s_tvalid <= '0';

    -- Phase C: after the queued-data reset pulse, restart a small sequence
    -- from word zero and verify that pre-reset data was flushed.
    wait until phase_c_start = '1';
    wait until rising_edge(s_clk);

    v_sent := 0;
    s_tvalid <= '1';
    while v_sent < C_RESUME_WORDS loop
      s_tdata <= f_word(v_sent);
      wait until rising_edge(s_clk);
      if s_tready = '1' then
        v_sent := v_sent + 1;
      end if;
    end loop;
    s_tvalid <= '0';
    write(l, string'("Stim: phase C sent " & integer'image(v_sent) & " words"));
    writeline(output, l);

    -- Phase D: source-side valid gaps. The source deasserts tvalid one
    -- cycle in four while the destination drains freely; the FIFO must
    -- neither lose nor reorder words across the gaps.
    wait until phase_d_start = '1';
    wait until rising_edge(s_clk);

    v_sent := C_RESUME_WORDS;
    v_gap  := 0;
    s_tvalid <= '1';
    while v_sent < C_RESUME_WORDS + C_GAP_WORDS loop
      s_tdata <= f_word(v_sent);
      wait until rising_edge(s_clk);
      if (s_tvalid = '1') and (s_tready = '1') then
        v_sent := v_sent + 1;
      end if;
      v_gap := v_gap + 1;
      if (v_gap mod 4) = 3 then
        s_tvalid <= '0';
      else
        s_tvalid <= '1';
      end if;
    end loop;
    s_tvalid <= '0';
    write(l, string'("Stim: phase D sent " & integer'image(v_sent) & " words with source gaps"));
    writeline(output, l);

    wait;
  end process;

  -- ==================================================================
  -- Consumer backpressure generator (m domain)
  -- ==================================================================
  -- In phases A, C and D the consumer is always ready. Phase B initially
  -- holds ready low until the source observes full-FIFO backpressure, then
  -- uses a deterministic 3-of-4 ready pattern. phase_reset_fill holds ready
  -- low while reset data is queued.
  p_backpressure : process(m_clk)
    variable v_cnt : natural := 0;
  begin
    if rising_edge(m_clk) then
      if aresetn = '0' then
        v_cnt := 0;
        m_tready <= '0';
      else
        if phase_reset_fill = '1' then
          m_tready <= '0';
          v_cnt := 0;
        elsif phase_b = '1' then
          if source_backpressure_seen = '0' then
            m_tready <= '0';
          elsif (v_cnt mod 4) = 3 then
            m_tready <= '0';
          else
            m_tready <= '1';
          end if;
          v_cnt := v_cnt + 1;
        else
          m_tready <= '1';
          v_cnt := 0;
        end if;
      end if;
    end if;
  end process;

  -- ==================================================================
  -- Destination checker (m domain)
  -- ==================================================================
  p_check : process(m_clk)
    variable v_recv    : natural := 0;
    variable v_meas    : natural := 0;      -- dest cycles since first word
    variable v_meas_on : boolean := false;  -- measuring line rate
    variable v_was_stalled : boolean := false;
    variable v_stalled_data : std_logic_vector(C_TDATA_WIDTH-1 downto 0);
    variable v_phase_b_stall_seen : boolean := false;
    variable l : line;
  begin
    if rising_edge(m_clk) then
      if aresetn = '0' then
        v_recv    := 0;
        v_meas    := 0;
        v_meas_on := false;
        v_was_stalled := false;
        v_phase_b_stall_seen := false;
      else
        if v_was_stalled then
          assert m_tvalid = '1'
            report "FAIL: destination valid dropped while stalled"
            severity failure;
          assert m_tdata = v_stalled_data
            report "FAIL: destination data changed while stalled"
            severity failure;
        end if;

        v_was_stalled := (m_tvalid = '1') and (m_tready = '0');
        if v_was_stalled then
          v_stalled_data := m_tdata;
          if phase_b = '1' then
            v_phase_b_stall_seen := true;
          end if;
        end if;

        -- Count destination clock cycles while measuring line rate.
        if v_meas_on then
          v_meas := v_meas + 1;
        end if;

        -- Verify order and integrity on every accepted word.
        if (m_tvalid = '1') and (m_tready = '1') then
          if m_tdata /= f_word(v_recv) then
            write(l, string'("FAIL: word " & integer'image(v_recv) &
                             " got 0x" & to_hstring(unsigned(m_tdata)) &
                             " expected 0x" & to_hstring(unsigned(f_word(v_recv)))));
            writeline(output, l);
            report "data mismatch" severity failure;
          end if;
          if v_recv = 0 then
            v_meas_on := true;  -- start measuring on the first word
            v_meas    := 1;
          end if;
          v_recv := v_recv + 1;
        end if;

        -- Phase A completion (set once, survives the reset pulse).
        -- LINE-RATE PROOF: only when the source is not slower than the
        -- destination (GC_TM >= GC_TS) is the destination the bottleneck
        -- and must accept one word per destination clock (no bubbles). In
        -- the reverse run the destination idles waiting for the source, so
        -- no bound applies here - the source line-rate proof is in p_stim.
        if (phase_a_done = '0') and (v_recv = C_NUM_WORDS) then
          phase_a_done <= '1';
          if GC_EXPECT_LINE_RATE and (GC_TM >= GC_TS) then
            if v_meas > C_NUM_WORDS + 4 then
              report "FAIL: destination did not sustain line rate (" &
                     integer'image(v_meas) & " m-cycles for " &
                     integer'image(C_NUM_WORDS) & " words)"
                severity failure;
            end if;
            write(l, string'("Check: phase A received " & integer'image(v_recv) &
                             " words in " & integer'image(v_meas) &
                             " m-cycles (dest line rate)"));
          elsif GC_EXPECT_LINE_RATE then
            write(l, string'("Check: phase A received " & integer'image(v_recv) &
                             " words (source line rate checked)"));
          else
            write(l, string'("Check: phase A received " & integer'image(v_recv) &
                             " words (line-rate assertion disabled)"));
          end if;
          writeline(output, l);
        end if;

        if (phase_b_done = '0') and (v_recv = C_NUM_WORDS + C_NUM_WORDS_B) then
          assert v_phase_b_stall_seen
            report "FAIL: destination stall stability was not exercised"
            severity failure;
          phase_b_done <= '1';
          write(l, string'("Check: phase B received " & integer'image(v_recv) & " words"));
          writeline(output, l);
        end if;

        -- Phase C completion (then phase D may start).
        if (phase_c_done = '0') and (phase_c_start = '1') and
           (v_recv = C_RESUME_WORDS) then
          phase_c_done <= '1';
          write(l, string'("Check: phase C received " & integer'image(v_recv) & " words"));
          writeline(output, l);
        end if;

        -- Phase D completion -> success.
        if (phase_d_start = '1') and
           (v_recv = C_RESUME_WORDS + C_GAP_WORDS) then
          write(l, string'("Check: phase D received " & integer'image(v_recv) & " words"));
          writeline(output, l);
          report "ALL CDC CHECKS PASSED";
          test_done <= '1';
        end if;
      end if;
    end if;
  end process;

  -- ==================================================================
  -- Watchdog (prevents a deadlock from hanging the batch run)
  -- ==================================================================
  p_watchdog : process
  begin
    wait for 1 ms;
    if test_done = '0' then
      report "FAIL: watchdog timeout (possible CDC deadlock)" severity failure;
    end if;
    wait;
  end process;

end architecture;
