-----------------------------------------------------------------------
--Filename         : axis_cdc_uvvm_tb.vhd
--Description      : UVVM VVC-based testbench sequencer for axis_cdc.
--                 : Verifies ordering, repeated pointer wrap, full
--                 : backpressure, stalled-output stability, randomized
--                 : valid/ready gaps, queued-data reset flushing, and
--                 : post-reset recovery across independent clocks.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library uvvm_util;
use uvvm_util.types_pkg.all;
use uvvm_util.methods_pkg.all;
use uvvm_util.adaptations_pkg.all;

library uvvm_vvc_framework;
use uvvm_vvc_framework.ti_vvc_framework_support_pkg.all;

library bitvis_vip_axistream;
context bitvis_vip_axistream.vvc_context;

entity axis_cdc_uvvm_tb is
  generic (
    GC_TDATA_WIDTH : positive := 32;
    GC_CDC_DEPTH   : positive := 8;
    GC_SYNC_STAGES : positive := 2;
    GC_S_CLK_PERIOD : time := 10 ns;
    GC_M_CLK_PERIOD : time := 13.2 ns
  );
end entity axis_cdc_uvvm_tb;

architecture sim of axis_cdc_uvvm_tb is
  constant C_TX_VVC_IDX : natural := 0;
  constant C_RX_VVC_IDX : natural := 1;
  constant C_TIMEOUT    : time := 200 us;

  constant C_WRAP_WORDS   : positive := 4*GC_CDC_DEPTH + 17;
  constant C_RANDOM_WORDS : positive := 4*GC_CDC_DEPTH + 64;
  constant C_RESET_MARKER : natural := 255;
  constant C_POST_RESET_WORD : natural := 0;

  signal s_axis_aclk : std_logic;
  signal m_axis_aclk : std_logic;
  signal aresetn     : std_logic := '0';
  signal s_clock_ena : boolean := true;
  signal m_clock_ena : boolean := true;
  signal force_m_stall : std_logic := '0';

  signal dbg_s_axis_tdata  : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal dbg_s_axis_tvalid : std_logic;
  signal dbg_s_axis_tready : std_logic;
  signal dbg_m_axis_tdata  : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal dbg_m_axis_tvalid : std_logic;
  signal dbg_m_axis_tready : std_logic;

  signal cov_source_backpressure : std_logic := '0';
  signal cov_output_stall        : std_logic := '0';
  signal cov_source_handshakes   : natural := 0;
  signal cov_dest_handshakes     : natural := 0;

  function f_word(index : natural) return std_logic_vector is
    variable value : std_logic_vector(GC_TDATA_WIDTH-1 downto 0) := (others => '0');
  begin
    for bit_index in value'range loop
      if (((index / (2 ** (bit_index mod 8))) + (bit_index / 8)) mod 2) = 1 then
        value(bit_index) := '1';
      end if;
    end loop;
    return value;
  end function;

  impure function f_bfm_config(
    constant clock_period : time;
    constant valid_low_probability : real;
    constant ready_low_probability : real;
    constant max_random_low_cycles : natural;
    constant ready_default : std_logic
  ) return t_axistream_bfm_config is
    variable config : t_axistream_bfm_config := C_AXISTREAM_BFM_CONFIG_DEFAULT;
  begin
    config.clock_period                     := clock_period;
    config.max_wait_cycles                  := 10000;
    config.max_wait_cycles_severity         := ERROR;
    config.valid_low_at_word_num            := 0;
    config.valid_low_multiple_random_prob   := valid_low_probability;
    config.valid_low_max_random_duration    := max_random_low_cycles;
    config.ready_low_at_word_num            := 0;
    config.ready_low_multiple_random_prob   := ready_low_probability;
    config.ready_low_max_random_duration    := max_random_low_cycles;
    config.ready_default_value              := ready_default;
    config.protocol_error_severity          := ERROR;
    return config;
  end function;
begin
  test_harness : entity work.axis_cdc_uvvm_th
    generic map (
      GC_TDATA_WIDTH => GC_TDATA_WIDTH,
      GC_CDC_DEPTH   => GC_CDC_DEPTH,
      GC_SYNC_STAGES => GC_SYNC_STAGES,
      GC_S_CLK_PERIOD => GC_S_CLK_PERIOD,
      GC_M_CLK_PERIOD => GC_M_CLK_PERIOD
    )
    port map (
      s_axis_aclk => s_axis_aclk,
      m_axis_aclk => m_axis_aclk,
      aresetn     => aresetn,
      s_clock_ena => s_clock_ena,
      m_clock_ena => m_clock_ena,
      force_m_stall => force_m_stall,
      dbg_s_axis_tdata  => dbg_s_axis_tdata,
      dbg_s_axis_tvalid => dbg_s_axis_tvalid,
      dbg_s_axis_tready => dbg_s_axis_tready,
      dbg_m_axis_tdata  => dbg_m_axis_tdata,
      dbg_m_axis_tvalid => dbg_m_axis_tvalid,
      dbg_m_axis_tready => dbg_m_axis_tready
    );

  uvvm_engine : entity uvvm_vvc_framework.ti_uvvm_engine;

  activity_watchdog(
    num_exp_vvc => 2,
    timeout     => C_TIMEOUT,
    alert_level => TB_ERROR,
    msg         => "axis_cdc UVVM activity watchdog"
  );

  p_source_coverage : process(s_axis_aclk)
  begin
    if rising_edge(s_axis_aclk) and aresetn = '1' then
      if dbg_s_axis_tvalid = '1' and dbg_s_axis_tready = '1' then
        cov_source_handshakes <= cov_source_handshakes + 1;
      elsif dbg_s_axis_tvalid = '1' and dbg_s_axis_tready = '0' then
        cov_source_backpressure <= '1';
      end if;
    end if;
  end process;

  p_destination_monitor : process(m_axis_aclk)
    variable was_stalled : boolean := false;
    variable stalled_data : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  begin
    if rising_edge(m_axis_aclk) then
      if aresetn = '0' then
        was_stalled := false;
      else
        if was_stalled then
          check_value(dbg_m_axis_tvalid, '1', ERROR,
                      "m_axis_tvalid must remain asserted while stalled");
          check_value(dbg_m_axis_tdata, stalled_data, ERROR,
                      "m_axis_tdata must remain stable while stalled");
        end if;

        was_stalled := dbg_m_axis_tvalid = '1' and dbg_m_axis_tready = '0';
        if was_stalled then
          stalled_data := dbg_m_axis_tdata;
          cov_output_stall <= '1';
        end if;

        if dbg_m_axis_tvalid = '1' and dbg_m_axis_tready = '1' then
          cov_dest_handshakes <= cov_dest_handshakes + 1;
        end if;
      end if;
    end if;
  end process;

  p_sequencer : process
    procedure configure_vvcs(
      constant valid_low_probability : in real;
      constant ready_low_probability : in real;
      constant max_random_low_cycles : in natural;
      constant ready_default : in std_logic
    ) is
    begin
      shared_axistream_vvc_config(C_TX_VVC_IDX).unwanted_activity_severity := NO_ALERT;
      shared_axistream_vvc_config(C_RX_VVC_IDX).unwanted_activity_severity := NO_ALERT;
      shared_axistream_vvc_config(C_TX_VVC_IDX).bfm_config := f_bfm_config(
        GC_S_CLK_PERIOD, valid_low_probability, 0.0, max_random_low_cycles, '0');
      shared_axistream_vvc_config(C_RX_VVC_IDX).bfm_config := f_bfm_config(
        GC_M_CLK_PERIOD, 0.0, ready_low_probability, max_random_low_cycles, ready_default);
    end procedure;

    procedure queue_word(
      constant word_index : in natural;
      constant message_id : in string
    ) is
    begin
      axistream_transmit(
        AXISTREAM_VVCT, C_TX_VVC_IDX, f_word(word_index),
        "TX " & message_id & " word " & integer'image(word_index));
      axistream_expect(
        AXISTREAM_VVCT, C_RX_VVC_IDX, f_word(word_index),
        "RX " & message_id & " word " & integer'image(word_index));
    end procedure;

    procedure await_all(constant message_id : in string) is
    begin
      await_completion(ALL_VVCS, C_TIMEOUT, message_id);
    end procedure;

    procedure wait_source_ready_low(constant message_id : in string) is
      variable ready_went_low : boolean := false;
    begin
      for cycle_index in 1 to 10000 loop
        wait until rising_edge(s_axis_aclk);
        if dbg_s_axis_tready = '0' then
          ready_went_low := true;
          exit;
        end if;
      end loop;
      check_value(ready_went_low, true, ERROR, message_id);
    end procedure;

    procedure wait_destination_valid(constant message_id : in string) is
      variable valid_went_high : boolean := false;
    begin
      for cycle_index in 1 to 10000 loop
        wait until rising_edge(m_axis_aclk);
        if dbg_m_axis_tvalid = '1' then
          valid_went_high := true;
          exit;
        end if;
      end loop;
      check_value(valid_went_high, true, ERROR, message_id);
    end procedure;

    procedure apply_reset(constant message_id : in string) is
    begin
      log(ID_SEQUENCER, message_id);
      aresetn <= '0';
      wait for 100 ps;
      check_value(dbg_s_axis_tready, '0', ERROR,
                  "s_axis_tready must clear asynchronously during reset");
      check_value(dbg_m_axis_tvalid, '0', ERROR,
                  "m_axis_tvalid must clear asynchronously during reset");
      wait until rising_edge(s_axis_aclk);
      wait until rising_edge(s_axis_aclk);
      wait until rising_edge(m_axis_aclk);
      wait until rising_edge(m_axis_aclk);
      aresetn <= '1';
      wait until rising_edge(s_axis_aclk);
      wait until rising_edge(s_axis_aclk);
      wait until rising_edge(s_axis_aclk);
      wait until rising_edge(m_axis_aclk);
      wait until rising_edge(m_axis_aclk);
      wait until rising_edge(m_axis_aclk);
    end procedure;

    variable stalled_word : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
    variable source_count_before_reset : natural;
    variable dest_count_before_reset   : natural;
  begin
    enable_log_msg(ID_SEQUENCER);
    set_alert_stop_limit(ERROR, 1);
    set_alert_stop_limit(TB_ERROR, 1);

    log(ID_LOG_HDR_LARGE, "START UVVM VVC TEST OF AXIS_CDC");
    configure_vvcs(0.0, 0.0, 0, '1');
    apply_reset("Initial reset");

    -- Phase 1: queue enough concurrent TX/RX commands to wrap both pointers
    -- several times while checking every payload bit and transfer order.
    log(ID_SEQUENCER, "Phase 1: ordered multi-wrap transfer");
    for word_index in 0 to C_WRAP_WORDS-1 loop
      queue_word(word_index, "wrap");
    end loop;
    await_all("Wait for ordered multi-wrap transfer");

    -- Phase 2: with no RX commands and ready defaulting low, queue one more
    -- word than the FIFO can hold. The pending TX command must backpressure.
    log(ID_SEQUENCER, "Phase 2: full backpressure and stalled-output stability");
    configure_vvcs(0.0, 0.0, 0, '1');
    force_m_stall <= '1';
    for word_index in 0 to GC_CDC_DEPTH loop
      axistream_transmit(
        AXISTREAM_VVCT, C_TX_VVC_IDX, f_word(1000 + word_index),
        "TX full-boundary word " & integer'image(word_index));
    end loop;

    wait_source_ready_low("s_axis_tready must deassert when the FIFO fills");
    wait_destination_valid("m_axis_tvalid must assert while output is stalled");
    stalled_word := dbg_m_axis_tdata;
    for stall_cycle in 1 to 8 loop
      wait until rising_edge(m_axis_aclk);
      check_value(dbg_m_axis_tready, '0', ERROR,
                  "m_axis_tready must remain low during forced stall");
      check_value(dbg_m_axis_tvalid, '1', ERROR,
                  "m_axis_tvalid must remain high during forced stall");
      check_value(dbg_m_axis_tdata, stalled_word, ERROR,
                  "m_axis_tdata must remain stable during forced stall");
    end loop;

    force_m_stall <= '0';
    for word_index in 0 to GC_CDC_DEPTH loop
      axistream_expect(
        AXISTREAM_VVCT, C_RX_VVC_IDX, f_word(1000 + word_index),
        "RX full-boundary word " & integer'image(word_index));
    end loop;
    await_all("Drain full-boundary sequence");

    -- Phase 3: use the AXI-Stream VVC's randomized valid and ready gaps.
    -- The fixed transaction data remains deterministic for reproducibility.
    log(ID_SEQUENCER, "Phase 3: randomized valid and ready gaps");
    configure_vvcs(0.35, 0.40, 5, '1');
    for word_index in 0 to C_RANDOM_WORDS-1 loop
      queue_word(2000 + word_index, "random-gap");
    end loop;
    await_all("Wait for randomized-gap transfer");

    -- Phase 4: fill the FIFO while the receiver is stalled, then reset with
    -- valid data visible. No pre-reset expectation is queued, so old data
    -- leaking after reset fails the distinct post-reset expectation.
    log(ID_SEQUENCER, "Phase 4: queued-data reset flush and recovery");
    configure_vvcs(0.0, 0.0, 0, '1');
    force_m_stall <= '1';
    for word_index in 0 to GC_CDC_DEPTH-1 loop
      axistream_transmit(
        AXISTREAM_VVCT, C_TX_VVC_IDX, f_word(C_RESET_MARKER),
        "TX pre-reset marker " & integer'image(word_index));
    end loop;
    await_completion(
      AXISTREAM_VVCT, C_TX_VVC_IDX, C_TIMEOUT,
      "Wait for pre-reset words to enter the FIFO");
    wait_destination_valid("pre-reset data must reach the stalled output");
    check_value(dbg_m_axis_tready, '0', ERROR,
                "receiver must remain stalled before reset");

    source_count_before_reset := cov_source_handshakes;
    dest_count_before_reset   := cov_dest_handshakes;
    aresetn <= '0';
    wait for 100 ps;
    check_value(dbg_s_axis_tready, '0', ERROR,
                "s_axis_tready must clear immediately on queued-data reset");
    check_value(dbg_m_axis_tvalid, '0', ERROR,
                "m_axis_tvalid must clear immediately on queued-data reset");
    wait until rising_edge(s_axis_aclk);
    wait until rising_edge(s_axis_aclk);
    wait until rising_edge(m_axis_aclk);
    wait until rising_edge(m_axis_aclk);
    aresetn <= '1';
    wait until rising_edge(s_axis_aclk);
    wait until rising_edge(s_axis_aclk);
    wait until rising_edge(s_axis_aclk);
    wait until rising_edge(m_axis_aclk);
    wait until rising_edge(m_axis_aclk);
    wait until rising_edge(m_axis_aclk);

    check_value(cov_source_handshakes >= source_count_before_reset, true, ERROR,
                "source handshake counter must not move backwards across reset");
    check_value(cov_dest_handshakes = dest_count_before_reset, true, ERROR,
                "queued pre-reset data must not transfer during reset");

    force_m_stall <= '0';
    axistream_transmit(
      AXISTREAM_VVCT, C_TX_VVC_IDX, f_word(C_POST_RESET_WORD),
      "TX post-reset marker");
    axistream_expect(
      AXISTREAM_VVCT, C_RX_VVC_IDX, f_word(C_POST_RESET_WORD),
      "RX post-reset marker");
    await_all("Verify post-reset restart and flushed pre-reset data");

    check_value(cov_source_backpressure, '1', ERROR,
                "coverage: source backpressure must be observed");
    check_value(cov_output_stall, '1', ERROR,
                "coverage: stalled valid output must be observed");
    check_value(cov_source_handshakes > 0, true, ERROR,
                "coverage: source handshakes must occur");
    check_value(cov_dest_handshakes > 0, true, ERROR,
                "coverage: destination handshakes must occur");

    report_alert_counters(FINAL);
    log(ID_LOG_HDR_LARGE, "AXIS_CDC UVVM VVC TEST PASSED");

    s_clock_ena <= false;
    m_clock_ena <= false;
    std.env.stop;
    wait;
  end process;
end architecture sim;
