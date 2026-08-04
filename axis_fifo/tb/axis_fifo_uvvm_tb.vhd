---------------------------------------------------------------------------------------------------
-- Filename         : axis_fifo_uvvm_tb.vhd
-- Description      : UVVM VVC-based Testbench Sequencer for axis_fifo.
--                    Communicates strictly using abstract VVC command interfaces,
--                    keeping the sequencer process completely free of physical port dependencies.
-- Author           : Rune Baeverrud
-- Current Revision : 1.0
-- Licensing        : Zero-Clause BSD (0BSD)
---------------------------------------------------------------------------------------------------
--
-- UVVM TOPOLOGY EXPLANATION - THE SEQUENCER (TB):
--
-- 1. PORTLESS TESTBENCH:
--    Following standard structural segregation rules, the sequencer entity has absolutely NO ports.
--    It does not read or write "aclk", "aresetn", or data buses directly in the main sequence loop.
--    This matches the abstract verification principles in modern SystemVerilog/UVM environments.
--
-- 2. INDIRECT COMMAND POOL (VVC):
--    The sequencer process runs completely in its own abstract world. Instead of wiggling pins, 
--    it dispatches non-blocking commands to autonomous verification components (VVCs) inside the 
--    harness by updating global record structures (under AXISTREAM_VVCT target variables).
--
-- 3. THE FRAMEWORK COORDINATOR:
--    The VVC command protocol relies on a central framework coordinator called "ti_uvvm_engine".
--    This background engine schedules the dispatched task records, resolves concurrent queue index
--    counters, and manages synchronous simulation timing checks.
--
---------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.util_pkg.all;

-- UVVM UTILITY PACKAGES: Provide standard logging filters, randomized loops, and summary reports
library uvvm_util;
use uvvm_util.types_pkg.all;
use uvvm_util.methods_pkg.all;
use uvvm_util.adaptations_pkg.all;
use uvvm_util.rand_pkg.all;

-- UVVM VVC FRAMEWORK SUPPORT PACKAGE: Manages queue scheduling and sync triggers
library uvvm_vvc_framework;
use uvvm_vvc_framework.ti_vvc_framework_support_pkg.all;

-- BITVIS AXI-STREAM VVC CONTEXT MAPPING: Exposes VVC config records and shared variables
library bitvis_vip_axistream;
context bitvis_vip_axistream.vvc_context;

entity axis_fifo_uvvm_tb is
end entity;

architecture sim of axis_fifo_uvvm_tb is
  -- Setup testbench constants
  constant TCLK         : time     := 10 ns;
  constant C_WIDTH      : positive := 8;
  constant C_DEPTH      : positive := 3; -- odd/non-power-of-two depth coverage
  constant C_ENABLE_NEGATIVE_TEST : boolean := false;

  -- Abstract testbench control signals driving the structural Test Harness
  signal aclk           : std_logic;
  signal aresetn        : std_logic := '1'; -- Initialised to inactive high
  signal clock_ena      : boolean   := true;
  signal fifo_count     : unsigned(log2ceil(C_DEPTH) downto 0);
  signal dbg_m_tvalid   : std_logic;
  signal dbg_m_tready   : std_logic;
  signal dbg_m_tdata    : std_logic_vector(C_WIDTH-1 downto 0);

  -------------------------------------------------------------------------------------------------
  -- setup_bfm_config:
  -- This helper sets up the underlying Bus Functional Model (BFM) properties for the VVC executors.
  -- Enabling random valid and ready back-pressure helps mimic real, erratic streaming partners.
  -------------------------------------------------------------------------------------------------
  impure function setup_bfm_config return t_axistream_bfm_config is
    variable c : t_axistream_bfm_config := C_AXISTREAM_BFM_CONFIG_DEFAULT;
  begin
    c.clock_period                     := TCLK;
    c.max_wait_cycles                  := 50;                  -- Timeout if handshake stalls for 50 cycles
    c.valid_low_at_word_num            := 0;
    c.valid_low_multiple_random_prob   := 0.3;                 -- 30% chance for TX VVC to drop valid between cycles
    c.valid_low_max_random_duration    := 3;                   -- Keep valid low for up to 3 clock cycles
    c.ready_low_at_word_num            := 0;
    c.ready_low_multiple_random_prob   := 0.3;                 -- 30% chance for RX VVC to drop ready (back-pressure)
    c.ready_low_max_random_duration    := 3;                   -- Keep ready low for up to 3 clock cycles
    c.ready_default_value              := '0';                 -- Start transaction phase with ready = 0
    c.protocol_error_severity          := NO_ALERT;            -- Disable optional unaligned bytes/packet checks
    return c;
  end function;

begin

  -------------------------------------------------------------------------------------------------
  -- Test Harness Instantiation (DUT + VVCs)
  -------------------------------------------------------------------------------------------------
th_inst : entity work.axis_fifo_uvvm_th
    generic map (
      GC_DATA_WIDTH => C_WIDTH,
      GC_FIFO_DEPTH => C_DEPTH,
      GC_CLK_PERIOD => TCLK
    )
    port map (
      aclk       => aclk,
      aresetn    => aresetn,
      clock_ena  => clock_ena,
      fifo_count => fifo_count,
      dbg_m_tvalid => dbg_m_tvalid,
      dbg_m_tready => dbg_m_tready,
      dbg_m_tdata  => dbg_m_tdata
    );

  -------------------------------------------------------------------------------------------------
  -- Central UVVM VVC Coordinator/Engine Instantiation
  -- Crucial component that acts as the coordinator and synchronization engine for all VVC channels.
  -------------------------------------------------------------------------------------------------
  i_ti_uvvm_engine : entity uvvm_vvc_framework.ti_uvvm_engine;

  -------------------------------------------------------------------------------------------------
  -- OPTIONAL FEATURE DEMO 1: UVVM Activity Watchdog
  -- Spawned as an active concurrent statement. If all VVC communications stall or freeze for 
  -- over 10 us anywhere during testbench loops, it triggers a clean simulation fail-safe.
  -- This concurrent block is fully optional: you can comment it out without affecting test logic.
  -------------------------------------------------------------------------------------------------
  -- In VHDL-2008 we can run a concurrent procedure directly:
  activity_watchdog(num_exp_vvc => 2, timeout => 10 us, alert_level => TB_ERROR, msg => "FIFO Activity Watchdog");

  -------------------------------------------------------------------------------------------------
  -- Abstract Testbench Sequencer process
  -------------------------------------------------------------------------------------------------
  process
    variable rv_seed : t_rand;
    variable rv_delay: t_rand;
    variable v_stall_data : std_logic_vector(C_WIDTH-1 downto 0);

    -- Procedural helper to insert clean timing cycles utilizing local random generators
    procedure random_delay(max_cycles : integer) is
      variable n : integer;
    begin
      n := rv_delay.rand(0, max_cycles - 1);
      for i in 1 to n loop wait until rising_edge(aclk); end loop;
    end procedure;

    procedure await_all(constant msg : in string) is
    begin
      await_completion(ALL_VVCS, 10 us, msg);
    end procedure;

    procedure set_rx_backpressure(
      constant ready_low_prob : in real;
      constant max_duration   : in natural
    ) is
    begin
      shared_axistream_vvc_config(1).bfm_config.ready_low_at_word_num          := 0;
      shared_axistream_vvc_config(1).bfm_config.ready_low_multiple_random_prob := ready_low_prob;
      shared_axistream_vvc_config(1).bfm_config.ready_low_max_random_duration  := max_duration;
    end procedure;

  begin
    -----------------------------------------------------------------------------------------------
    -- UVVM Sequencer Log Configuration:
    -- We explicitly enable specific standard message identifiers. This permits fine-grained filter
    -- controls on transcripts in simulator windows, allowing developers to mute verbose packet trace
    -- outputs without disabling sequencer milestones.
    -----------------------------------------------------------------------------------------------
    enable_log_msg(ID_SEQUENCER);       -- Logs sequencer milestones and phase switches
    enable_log_msg(ID_PACKET_INITIATE); -- Logs when a packet launch starts
    enable_log_msg(ID_PACKET_DATA);     -- Logs individual payload bytes being driven/captured
    enable_log_msg(ID_PACKET_COMPLETE); -- Logs transaction wrap and checks pass

    -- Initialize test logging with a formatted section header banner
    log(ID_LOG_HDR_LARGE, "START VVC-BASED ABSTRACT SIMULATION OF AXIS FIFO");

    -- OPTIONAL FEATURE DEMO: Adjust stop limit dynamically to prevent early termination 
    -- during expected alert (negative testing) sweeps.
    set_alert_stop_limit(ERROR, 10);

    -----------------------------------------------------------------------------------------------
    -- UVVM Configuration Registers:
    -- Shared variables allow us to configure structural components on-the-fly. We set unneeded 
    -- unwanted activity monitors to NO_ALERT during the initialization, and pass BFM configurations.
    -----------------------------------------------------------------------------------------------
    shared_axistream_vvc_config(0).unwanted_activity_severity := NO_ALERT; -- Master TX (VVC Instance 0)
    shared_axistream_vvc_config(1).unwanted_activity_severity := NO_ALERT; -- Slave RX (VVC Instance 1)
    
    shared_axistream_vvc_config(0).bfm_config := setup_bfm_config; -- Load Master TX BFM config parameters
    shared_axistream_vvc_config(1).bfm_config := setup_bfm_config; -- Load Slave RX BFM config parameters

    -----------------------------------------------------------------------------------------------
    -- Constrained-Random Iterative Seed loop
    -----------------------------------------------------------------------------------------------
    for seed_num in 1 to 5 loop
      rv_seed.set_name("seed_gen_" & integer'image(seed_num));
      rv_seed.set_rand_seeds(seed_num, seed_num * 3 + 7);
      
      rv_delay.set_name("seed_delay_" & integer'image(seed_num));
      rv_delay.set_rand_seeds(seed_num * 2, seed_num * 5 + 1);

      -- Drive active reset for 1 clock utilizing UVVM's robust non-blocking pulse builder
      gen_pulse(aresetn, '0', aclk, 1, "Asserting Reset line");
      
      -- Delay next checks to let signals settle fully
      wait until rising_edge(aclk);
      wait for 1 ns;

      log(ID_SEQUENCER, "");
      log(ID_SEQUENCER, "=== Seed " & integer'image(seed_num) & " ===");

      ---------------------------------------------------------------------------------------------
      -- Phase 1: Push C_DEPTH items (fill FIFO)
      -- Demonstrates UVVM Queued Command Processing: calling axistream_transmit() is NON-BLOCKING.
      -- The command is instantly serialized and pushed into the targeted VVC's executor queue.
      -- The sequencer immediately returns to spawn concurrent transactions.
      ---------------------------------------------------------------------------------------------
      log(ID_SEQUENCER, "Phase 1: Filling FIFO with random block-pressures...");
      for op in 1 to C_DEPTH loop
        -- Introduce sporadic generator pauses to test handshake stability
        random_delay(3);
        axistream_transmit(AXISTREAM_VVCT, 0, 
                           std_logic_vector(to_unsigned(op * 16, C_WIDTH)),
                           "Fill word " & integer'image(op));
      end loop;

      -- BLOCKING COMMAND SYNCHRONISATION:
      -- We suspend the sequencer here using await_completion() to wait until all VVC command queues 
      -- are empty before checking FIFO contents. Includes a 10 us watchdog safety net.
      await_all("Wait for VVC TX to complete the fill operations");
      log(ID_SEQUENCER, "FIFO filled completely (depth=" & integer'image(C_DEPTH) & ")");

      ---------------------------------------------------------------------------------------------
      -- Phase 1b: Explicit stall stability
      -- Hold M_AXIS ready low and verify output valid/data remain stable.
      ---------------------------------------------------------------------------------------------
      log(ID_SEQUENCER, "Phase 1b: Sustained-stall data stability check...");
      set_rx_backpressure(1.0, 8);
      wait until rising_edge(aclk);
      wait for 1 ns;
      check_value(dbg_m_tvalid, '1', ERROR, "m_tvalid must be high while FIFO is non-empty");
      check_value(to_integer(fifo_count), C_DEPTH, ERROR, "fifo_count must remain full before drain");
      v_stall_data := dbg_m_tdata;
      for stall_cycle in 1 to 4 loop
        wait until rising_edge(aclk);
        wait for 1 ns;
        check_value(dbg_m_tready, '0', ERROR, "m_tready must stay low during forced stall");
        check_value(dbg_m_tvalid, '1', ERROR, "m_tvalid dropped during forced stall");
        check_value(dbg_m_tdata, v_stall_data, ERROR, "m_tdata changed during forced stall");
        check_value(to_integer(fifo_count), C_DEPTH, ERROR, "fifo_count changed during forced stall");
      end loop;
      set_rx_backpressure(0.3, 3);

      ---------------------------------------------------------------------------------------------
      -- Phase 2: Pop C_DEPTH items and verify values and order
      -- Calls axistream_expect() to check payload data coming out of the FIFO against expected values.
      ---------------------------------------------------------------------------------------------
      log(ID_SEQUENCER, "Phase 2: Draining FIFO and verifying contents...");
      for op in 1 to C_DEPTH loop
        random_delay(3);
        axistream_expect(AXISTREAM_VVCT, 1,
                         std_logic_vector(to_unsigned(op * 16, C_WIDTH)),
                         "Expect 0x" & integer'image(op * 16));
      end loop;

      await_all("Wait for VVC RX to complete verification checks");
      log(ID_SEQUENCER, "FIFO drained and contents verified successfully!");

      ---------------------------------------------------------------------------------------------
      -- Phase 3: Push/pop known sequence (interleaved)
      -- True Pipeline handshake simulation. By queuing both TX sends and RX expectations without 
      -- waiting, VVC 0 and VVC 1 communicate on-the-wire at the exact same cycle, checking 
      -- simultaneous data read/write handshake operations.
      ---------------------------------------------------------------------------------------------
      log(ID_SEQUENCER, "Phase 3: Interleaved single-word push/pop transactions...");
      
      axistream_transmit(AXISTREAM_VVCT, 0, x"AA", "queue AA");
      axistream_expect(AXISTREAM_VVCT, 1, x"AA", "expect AA");

      axistream_transmit(AXISTREAM_VVCT, 0, x"55", "queue 55");
      axistream_expect(AXISTREAM_VVCT, 1, x"55", "expect 55");

      axistream_transmit(AXISTREAM_VVCT, 0, x"FF", "queue FF");
      axistream_expect(AXISTREAM_VVCT, 1, x"FF", "expect FF");

      axistream_transmit(AXISTREAM_VVCT, 0, x"00", "queue 00");
      axistream_expect(AXISTREAM_VVCT, 1, x"00", "expect 00");

      await_all("Wait for interleaved phases to finish");

      ---------------------------------------------------------------------------------------------
      -- Phase 4: Push sequence of 4, then drain
      -- Validates performance and boundaries under high burst rates.
      ---------------------------------------------------------------------------------------------
      log(ID_SEQUENCER, "Phase 4: Queue burst push...");
      axistream_transmit(AXISTREAM_VVCT, 0, x"10", "push 10");
      axistream_transmit(AXISTREAM_VVCT, 0, x"20", "push 20");
      axistream_transmit(AXISTREAM_VVCT, 0, x"30", "push 30");
      axistream_transmit(AXISTREAM_VVCT, 0, x"40", "push 40");

      log(ID_SEQUENCER, "Phase 4: Queue companion expect group...");
      axistream_expect(AXISTREAM_VVCT, 1, x"10", "expect 0x10");
      axistream_expect(AXISTREAM_VVCT, 1, x"20", "expect 0x20");
      axistream_expect(AXISTREAM_VVCT, 1, x"30", "expect 0x30");
      axistream_expect(AXISTREAM_VVCT, 1, x"40", "expect 0x40");

      await_all("Wait for back-to-back burst test to finish");

      ---------------------------------------------------------------------------------------------
      -- Phase 5: In-flight reset while FIFO is non-empty
      -- Force downstream stall, queue data into FIFO, assert reset, then
      -- verify clean empty restart and post-reset functionality.
      ---------------------------------------------------------------------------------------------
      log(ID_SEQUENCER, "Phase 5: In-flight reset while non-empty...");
      set_rx_backpressure(1.0, 10);

      axistream_transmit(AXISTREAM_VVCT, 0, x"9A", "queue 9A before reset");
      axistream_transmit(AXISTREAM_VVCT, 0, x"BC", "queue BC before reset");
      await_all("Queue data before reset");

      wait until rising_edge(aclk);
      wait for 1 ns;
      if to_integer(fifo_count) = 0 then
        alert(ERROR, "Expected non-empty FIFO before in-flight reset");
      end if;

      aresetn <= '0';
      wait until rising_edge(aclk);
      wait until rising_edge(aclk);
      aresetn <= '1';
      wait until rising_edge(aclk);
      wait for 1 ns;

      check_value(to_integer(fifo_count), 0, ERROR, "fifo_count should clear to 0 after in-flight reset");
      check_value(dbg_m_tvalid, '0', ERROR, "m_tvalid should be 0 after in-flight reset");

      set_rx_backpressure(0.3, 3);

      axistream_transmit(AXISTREAM_VVCT, 0, x"77", "post-reset tx 77");
      axistream_expect(AXISTREAM_VVCT, 1, x"77", "post-reset expect 77");
      await_all("Wait for post-reset functional check");

      ---------------------------------------------------------------------------------------------
      -- OPTIONAL FEATURE DEMO 2: Expected Alerts (Negative Testing)
      -- Disabled by default to keep standard regression summaries free from
      -- intentional WARNING/ERROR counts.
      ---------------------------------------------------------------------------------------------
      if C_ENABLE_NEGATIVE_TEST and seed_num = 1 then
        log(ID_SEQUENCER, "Optional Negative Testing Demo: Simulating Stall Timeout...");
        
        -- Override BFM timeout properties to raise a WARNING instead of ERROR on timeout
        shared_axistream_vvc_config(1).bfm_config.max_wait_cycles          := 1;
        shared_axistream_vvc_config(1).bfm_config.max_wait_cycles_severity := WARNING;
        
        -- Register the exact expectation of 1 warning and 1 error.
        -- When axistream_expect times out, it produces both a timeout warning and a data mismatch error.
        increment_expected_alerts(WARNING, 1, "Expect timeout warning due to un-wiggled receiver interface");
        increment_expected_alerts(ERROR, 1, "Expect data mismatch error due to missing transaction data");

        -- Queue check, but DUT has nothing to send -> this transaction will fail and time out
        axistream_expect(AXISTREAM_VVCT, 1, x"EE", "Expect data from an idle interface");
        await_completion(ALL_VVCS, 200 ns, "Wait for expected stall timeout");

        -- Restore configuration parameters to normal defaults
        shared_axistream_vvc_config(1).bfm_config.max_wait_cycles          := 50;
        shared_axistream_vvc_config(1).bfm_config.max_wait_cycles_severity := ERROR;
        log(ID_SEQUENCER, "Negative Timeout Testing verified cleanly!");
      end if;

      log(ID_SEQUENCER, "Seed " & integer'image(seed_num) & " done.");
    end loop;

    log(ID_SEQUENCER, "================================");
    log(ID_SEQUENCER, "ALL SEEDS COMPLETED (VVC MODE)");
    log(ID_SEQUENCER, "================================");

    -----------------------------------------------------------------------------------------------
    -- UVVM CONSOLIDATED GLOBAL REPORT:
    -- Aggregates checks from all VVC executors and automatically outputs a unified test report detailing
    -- successful/errant counts, failures, and mismatches.
    -----------------------------------------------------------------------------------------------
    report_alert_counters(FINAL);

    log(ID_SEQUENCER, "SIMULATION SUCCESSFUL (VVC ARCHITECTURE)");

    -- Stop the clock generator in the harness
    clock_ena <= false;

    -- Close simulation run cleanly using VHDL-2008 std.env helper to prevent idle watchdog timeout
    std.env.stop;
    wait;
  end process;

end architecture;
