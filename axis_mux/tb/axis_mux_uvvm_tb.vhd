-----------------------------------------------------------------------
--Filename         : axis_mux_uvvm_tb.vhd
--Description      : UVVM VVC sequencer for axis_mux.
--                 : Covers deterministic round-robin ordering, repeated
--                 : fairness, output stalls, input backpressure, reset
--                 : flushing, post-reset recovery, and randomized gaps.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.util_pkg.all;

library uvvm_util;
use uvvm_util.types_pkg.all;
use uvvm_util.methods_pkg.all;
use uvvm_util.adaptations_pkg.all;

library uvvm_vvc_framework;
use uvvm_vvc_framework.ti_vvc_framework_support_pkg.all;

library bitvis_vip_axistream;
context bitvis_vip_axistream.vvc_context;

entity axis_mux_uvvm_tb is
  generic (
    GC_TDATA_WIDTH : positive := 32;
    GC_FIFO_DEPTH  : positive range 2 to positive'high := 4;
    GC_CLK_PERIOD  : time := 10 ns
  );
end entity axis_mux_uvvm_tb;

architecture sim of axis_mux_uvvm_tb is
  constant C_TX0_VVC_IDX : natural := 0;
  constant C_TX1_VVC_IDX : natural := 1;
  constant C_TX2_VVC_IDX : natural := 2;
  constant C_RX_VVC_IDX  : natural := 3;
  constant C_TIMEOUT     : time := 200 us;
  constant C_WAIT_CYCLES : positive := 10000;

  signal aclk              : std_logic;
  signal aresetn           : std_logic := '0';
  signal clock_ena         : boolean := true;
  signal force_m_stall     : std_logic := '0';
  signal dbg_s_axis_tready : std_logic_vector(0 to 2);
  signal dbg_m_axis_tdata  : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal dbg_m_axis_tvalid : std_logic;
  signal dbg_m_axis_tready : std_logic;
  signal fifo_count        : unsigned(log2ceil(GC_FIFO_DEPTH) downto 0);

  function f_word(value : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(value, GC_TDATA_WIDTH));
  end function;

  impure function f_bfm_config(
    constant clock_period          : time;
    constant valid_low_probability : real;
    constant ready_low_probability : real;
    constant max_low_cycles        : natural;
    constant ready_default         : std_logic
  ) return t_axistream_bfm_config is
    variable config : t_axistream_bfm_config := C_AXISTREAM_BFM_CONFIG_DEFAULT;
  begin
    config.clock_period                     := clock_period;
    config.max_wait_cycles                  := 10000;
    config.max_wait_cycles_severity         := ERROR;
    config.valid_low_at_word_num            := 0;
    config.valid_low_multiple_random_prob   := valid_low_probability;
    config.valid_low_max_random_duration    := max_low_cycles;
    config.ready_low_at_word_num            := 0;
    config.ready_low_multiple_random_prob   := ready_low_probability;
    config.ready_low_max_random_duration    := max_low_cycles;
    config.ready_default_value              := ready_default;
    config.protocol_error_severity          := ERROR;
    return config;
  end function;
begin

  test_harness : entity work.axis_mux_uvvm_th
    generic map (
      GC_TDATA_WIDTH => GC_TDATA_WIDTH,
      GC_FIFO_DEPTH  => GC_FIFO_DEPTH,
      GC_CLK_PERIOD  => GC_CLK_PERIOD
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      clock_ena         => clock_ena,
      force_m_stall     => force_m_stall,
      dbg_s_axis_tready => dbg_s_axis_tready,
      dbg_m_axis_tdata  => dbg_m_axis_tdata,
      dbg_m_axis_tvalid => dbg_m_axis_tvalid,
      dbg_m_axis_tready => dbg_m_axis_tready,
      fifo_count        => fifo_count
    );

  i_ti_uvvm_engine : entity uvvm_vvc_framework.ti_uvvm_engine;

  activity_watchdog(
    num_exp_vvc => 4,
    timeout     => C_TIMEOUT,
    alert_level => TB_ERROR,
    msg         => "axis_mux UVVM activity watchdog"
  );

  p_sequencer : process
    procedure configure_vvcs(
      constant valid_probability : in real;
      constant ready_probability : in real;
      constant max_low_cycles    : in natural;
      constant ready_default     : in std_logic
    ) is
    begin
      shared_axistream_vvc_config(C_TX0_VVC_IDX).unwanted_activity_severity := NO_ALERT;
      shared_axistream_vvc_config(C_TX1_VVC_IDX).unwanted_activity_severity := NO_ALERT;
      shared_axistream_vvc_config(C_TX2_VVC_IDX).unwanted_activity_severity := NO_ALERT;
      shared_axistream_vvc_config(C_RX_VVC_IDX).unwanted_activity_severity  := NO_ALERT;
      shared_axistream_vvc_config(C_TX0_VVC_IDX).bfm_config := f_bfm_config(
        GC_CLK_PERIOD, valid_probability, 0.0, max_low_cycles, '0');
      shared_axistream_vvc_config(C_TX1_VVC_IDX).bfm_config := f_bfm_config(
        GC_CLK_PERIOD, valid_probability, 0.0, max_low_cycles, '0');
      shared_axistream_vvc_config(C_TX2_VVC_IDX).bfm_config := f_bfm_config(
        GC_CLK_PERIOD, valid_probability, 0.0, max_low_cycles, '0');
      shared_axistream_vvc_config(C_RX_VVC_IDX).bfm_config := f_bfm_config(
        GC_CLK_PERIOD, 0.0, ready_probability, max_low_cycles, ready_default);
    end procedure;

    procedure queue_one_round(
      signal   output_stall : out std_logic;
      constant base_value   : in natural
    ) is
    begin
      -- Hold the sink while all three source handshakes complete. This makes
      -- the fairness check independent of VVC scheduling between sources.
      output_stall <= '1';
      axistream_transmit(AXISTREAM_VVCT, C_TX0_VVC_IDX,
                         f_word(base_value), "TX source 0");
      axistream_transmit(AXISTREAM_VVCT, C_TX1_VVC_IDX,
                         f_word(base_value + 1), "TX source 1");
      axistream_transmit(AXISTREAM_VVCT, C_TX2_VVC_IDX,
                         f_word(base_value + 2), "TX source 2");
      await_completion(AXISTREAM_VVCT, C_TX0_VVC_IDX, C_TIMEOUT,
               "Wait for source 0 handshake");
      await_completion(AXISTREAM_VVCT, C_TX1_VVC_IDX, C_TIMEOUT,
               "Wait for source 1 handshake");
      await_completion(AXISTREAM_VVCT, C_TX2_VVC_IDX, C_TIMEOUT,
               "Wait for source 2 handshake");
      axistream_expect(AXISTREAM_VVCT, C_RX_VVC_IDX,
                       f_word(base_value), "RX round-robin source 0");
      axistream_expect(AXISTREAM_VVCT, C_RX_VVC_IDX,
                       f_word(base_value + 1), "RX round-robin source 1");
      axistream_expect(AXISTREAM_VVCT, C_RX_VVC_IDX,
                       f_word(base_value + 2), "RX round-robin source 2");
      output_stall <= '0';
    end procedure;

    procedure await_all(constant message : in string) is
    begin
      await_completion(ALL_VVCS, C_TIMEOUT, message);
    end procedure;

    procedure apply_reset(constant message : in string) is
    begin
      log(ID_SEQUENCER, message);
      aresetn <= '0';
      for cycle in 1 to 3 loop
        wait until rising_edge(aclk);
      end loop;
      check_value(fifo_count, to_unsigned(0, fifo_count'length), ERROR,
          "FIFO count must be zero in reset");
      check_value(dbg_m_axis_tvalid, '0', ERROR,
                  "output valid must be low in reset");
      aresetn <= '1';
      for cycle in 1 to 3 loop
        wait until rising_edge(aclk);
      end loop;
    end procedure;

    procedure wait_for_valid(constant message : in string) is
      variable found : boolean := false;
    begin
      for cycle in 1 to C_WAIT_CYCLES loop
        wait until rising_edge(aclk);
        if dbg_m_axis_tvalid = '1' then
          found := true;
          exit;
        end if;
      end loop;
      check_value(found, true, ERROR, message);
    end procedure;

    variable stalled_data : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  begin
    set_alert_stop_limit(ERROR, 1);
    set_alert_stop_limit(TB_ERROR, 1);
    configure_vvcs(0.0, 0.0, 0, '1');

    apply_reset("Initial axis_mux reset");

    -- Deterministic simultaneous arbitration: source zero wins after reset.
    log(ID_SEQUENCER, "Round-robin order check");
    queue_one_round(force_m_stall, 16#100#);
    await_all("Wait for first round-robin sequence");

    -- Repeat the same simultaneous request shape. Each round starts with the
    -- previously selected source, so this verifies wrap-around fairness.
    for round_index in 0 to 5 loop
      queue_one_round(force_m_stall, 16#200# + round_index * 16);
      await_all("Wait for repeated fair round");
    end loop;

    -- A forced sink stall must not alter the visible FIFO word. The three
    -- source masters can still fill the mux slots and output FIFO safely.
    log(ID_SEQUENCER, "Output stall and input backpressure check");
    force_m_stall <= '1';
    axistream_transmit(AXISTREAM_VVCT, C_TX0_VVC_IDX,
                       f_word(16#400#), "TX stalled source 0");
    axistream_transmit(AXISTREAM_VVCT, C_TX1_VVC_IDX,
                       f_word(16#401#), "TX stalled source 1");
    axistream_transmit(AXISTREAM_VVCT, C_TX2_VVC_IDX,
                       f_word(16#402#), "TX stalled source 2");
    await_completion(AXISTREAM_VVCT, C_TX0_VVC_IDX, C_TIMEOUT,
                     "Wait for source 0 stalled transfer");
    await_completion(AXISTREAM_VVCT, C_TX1_VVC_IDX, C_TIMEOUT,
                     "Wait for source 1 stalled transfer");
    await_completion(AXISTREAM_VVCT, C_TX2_VVC_IDX, C_TIMEOUT,
                     "Wait for source 2 stalled transfer");
    wait_for_valid("Stalled output must become valid");
    stalled_data := dbg_m_axis_tdata;
    for cycle in 1 to 8 loop
      wait until rising_edge(aclk);
      check_value(dbg_m_axis_tready, '0', ERROR,
                  "forced stall must hold output ready low");
      check_value(dbg_m_axis_tvalid, '1', ERROR,
                  "valid must remain high during output stall");
      check_value(dbg_m_axis_tdata, stalled_data, ERROR,
                  "data must remain stable during output stall");
    end loop;
    force_m_stall <= '0';
    axistream_expect(AXISTREAM_VVCT, C_RX_VVC_IDX,
                     f_word(16#400#), "RX stalled source 0");
    axistream_expect(AXISTREAM_VVCT, C_RX_VVC_IDX,
                     f_word(16#401#), "RX stalled source 1");
    axistream_expect(AXISTREAM_VVCT, C_RX_VVC_IDX,
                     f_word(16#402#), "RX stalled source 2");
    await_all("Drain stalled sequence");

    -- Reset must flush both mux slots and the output FIFO. A new marker after
    -- reset proves that no pre-reset value escaped.
    log(ID_SEQUENCER, "Queued-data reset flush");
    force_m_stall <= '1';
    axistream_transmit(AXISTREAM_VVCT, C_TX0_VVC_IDX,
               f_word(16#500#), "TX reset-flush source 0");
    axistream_transmit(AXISTREAM_VVCT, C_TX1_VVC_IDX,
               f_word(16#501#), "TX reset-flush source 1");
    axistream_transmit(AXISTREAM_VVCT, C_TX2_VVC_IDX,
               f_word(16#502#), "TX reset-flush source 2");
    await_completion(AXISTREAM_VVCT, C_TX0_VVC_IDX, C_TIMEOUT,
             "Wait for reset-flush source 0");
    await_completion(AXISTREAM_VVCT, C_TX1_VVC_IDX, C_TIMEOUT,
             "Wait for reset-flush source 1");
    await_completion(AXISTREAM_VVCT, C_TX2_VVC_IDX, C_TIMEOUT,
             "Wait for reset-flush source 2");
    wait_for_valid("Reset-flush data must reach the stalled output");
    apply_reset("Reset while output data is queued");
    check_value(fifo_count, to_unsigned(0, fifo_count'length), ERROR,
          "FIFO must be empty after reset flush");
    check_value(dbg_m_axis_tvalid, '0', ERROR,
                "stale data must not remain valid after reset");
    force_m_stall <= '0';
    axistream_transmit(AXISTREAM_VVCT, C_TX0_VVC_IDX,
                       f_word(16#5A5#), "TX post-reset marker");
    axistream_expect(AXISTREAM_VVCT, C_RX_VVC_IDX,
                     f_word(16#5A5#), "RX post-reset marker");
    await_all("Verify post-reset recovery");

    -- Randomized valid/ready gaps exercise the handshake contract without
    -- relying on any fixed cycle alignment between the sources and sink.
    log(ID_SEQUENCER, "Randomized valid and ready gap check");
    configure_vvcs(0.30, 0.30, 4, '1');
    for round_index in 0 to 7 loop
      axistream_transmit(
        AXISTREAM_VVCT, round_index mod 3,
        f_word(16#600# + round_index),
        "TX randomized source " & integer'image(round_index mod 3));
      axistream_expect(
        AXISTREAM_VVCT, C_RX_VVC_IDX,
        f_word(16#600# + round_index),
        "RX randomized source " & integer'image(round_index mod 3));
      await_all("Wait for randomized fair round");
    end loop;

    report_alert_counters(FINAL);
    log(ID_LOG_HDR_LARGE, "AXIS_MUX UVVM VVC TEST PASSED");
    clock_ena <= false;
    std.env.stop;
    wait;
  end process;

end architecture sim;
