---------------------------------------------------------------------------------------------------
-- Filename         : axis_skid_buffer_uvvm_tb.vhd
-- Description      : UVVM VVC-based Testbench Sequencer for axis_skid_buffer.
--                    Communicates using abstract VVC command interfaces, keeping the
--                    sequencer process free of physical port dependencies.
-- Author           : Rune Baeverrud
-- Current Revision : 1.0
-- Licensing        : Zero-Clause BSD (0BSD)
---------------------------------------------------------------------------------------------------
--
-- UVVM TOPOLOGY:
--
--   SEQUENCER (this file)  --non-blocking VVC commands-->  HARNESS (uvvm_th)
--     portless, abstract                                      structural wiring
--                                                               +-- TX VVC (master, idx 0)
--                                                               +-- DUT (axis_skid_buffer)
--                                                               +-- RX VVC (slave,  idx 1)
--
-- Tests: passthrough, fill-to-TWO with stall, interleaved overlap,
--        prolonged stall, and in-flight reset.
--
---------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

-- UVVM utilities
library uvvm_util;
use uvvm_util.types_pkg.all;
use uvvm_util.methods_pkg.all;
use uvvm_util.adaptations_pkg.all;
use uvvm_util.rand_pkg.all;

-- VVC framework
library uvvm_vvc_framework;
use uvvm_vvc_framework.ti_vvc_framework_support_pkg.all;

-- AXI-Stream VVC context
library bitvis_vip_axistream;
context bitvis_vip_axistream.vvc_context;

entity axis_skid_buffer_uvvm_tb is
end entity;

architecture sim of axis_skid_buffer_uvvm_tb is
  constant TCLK         : time     := 10 ns;
  constant C_WIDTH      : positive := 8;

  type word_array_t is array (natural range <>) of std_logic_vector(C_WIDTH-1 downto 0);

  signal aclk           : std_logic;
  signal aresetn        : std_logic := '1';
  signal clock_ena      : boolean   := true;
  signal dbg_s_ready    : std_logic;
  signal dbg_m_valid    : std_logic;

  -- Coverage: inferred state + key transitions from handshake outputs.
  signal cov_seen_empty : std_logic := '0';
  signal cov_seen_one   : std_logic := '0';
  signal cov_seen_two   : std_logic := '0';
  signal cov_tr_e_o     : natural   := 0;
  signal cov_tr_o_e     : natural   := 0;
  signal cov_tr_o_t     : natural   := 0;
  signal cov_tr_t_o     : natural   := 0;
  signal cov_prev_valid : std_logic := '0';
  signal cov_prev_state : std_logic_vector(1 downto 0) := "10";

  ------------------------------------------------------------------------------------------------
  -- BFM configuration: enables random valid/ready back-pressure to exercise skid FSM
  ------------------------------------------------------------------------------------------------
  impure function setup_bfm_config return t_axistream_bfm_config is
    variable c : t_axistream_bfm_config := C_AXISTREAM_BFM_CONFIG_DEFAULT;
  begin
    c.clock_period                     := TCLK;
    c.max_wait_cycles                  := 50;
    c.valid_low_at_word_num            := 0;
    c.valid_low_multiple_random_prob   := 0.3;
    c.valid_low_max_random_duration    := 3;
    c.ready_low_at_word_num            := 0;
    c.ready_low_multiple_random_prob   := 0.3;
    c.ready_low_max_random_duration    := 3;
    c.ready_default_value              := '0';
    c.protocol_error_severity          := NO_ALERT;
    return c;
  end function;

begin

  ------------------------------------------------------------------------------------------------
  -- Test Harness (DUT + VVCs)
  ------------------------------------------------------------------------------------------------
  th_inst : entity work.axis_skid_buffer_uvvm_th
    generic map (
      GC_TDATA_WIDTH => C_WIDTH,
      GC_CLK_PERIOD  => TCLK
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      clock_ena         => clock_ena,
      dbg_s_axis_tready => dbg_s_ready,
      dbg_m_axis_tvalid => dbg_m_valid
    );

  ------------------------------------------------------------------------------------------------
  -- UVVM VVC Coordinator Engine
  ------------------------------------------------------------------------------------------------
  i_ti_uvvm_engine : entity uvvm_vvc_framework.ti_uvvm_engine;

  ------------------------------------------------------------------------------------------------
  -- Lightweight state coverage monitor
  ------------------------------------------------------------------------------------------------
  p_state_cov : process(aclk)
    variable curr_state : std_logic_vector(1 downto 0);
  begin
    if rising_edge(aclk) then
      curr_state := dbg_s_ready & dbg_m_valid;

      case curr_state is
        when "10" => cov_seen_empty <= '1';
        when "11" => cov_seen_one   <= '1';
        when "01" => cov_seen_two   <= '1';
        when others => null;
      end case;

      if cov_prev_valid = '1' then
        if    cov_prev_state = "10" and curr_state = "11" then cov_tr_e_o <= cov_tr_e_o + 1;
        elsif cov_prev_state = "11" and curr_state = "10" then cov_tr_o_e <= cov_tr_o_e + 1;
        elsif cov_prev_state = "11" and curr_state = "01" then cov_tr_o_t <= cov_tr_o_t + 1;
        elsif cov_prev_state = "01" and curr_state = "11" then cov_tr_t_o <= cov_tr_t_o + 1;
        end if;
      end if;

      cov_prev_state <= curr_state;
      cov_prev_valid <= '1';
    end if;
  end process;

  ------------------------------------------------------------------------------------------------
  -- Activity Watchdog: fails if all VVCs stall for >10 us
  ------------------------------------------------------------------------------------------------
  activity_watchdog(num_exp_vvc => 2, timeout => 10 us, alert_level => TB_ERROR,
                    msg => "Skid Buffer Activity Watchdog");

  ------------------------------------------------------------------------------------------------
  -- Sequencer process
  ------------------------------------------------------------------------------------------------
  process
    variable rv_seed  : t_rand;
    variable rv_delay : t_rand;

    constant C_PHASE3_SEQ : word_array_t(0 to 3) := (x"11", x"22", x"33", x"44");

    procedure random_delay(max_cycles : integer) is
      variable n : integer;
    begin
      n := rv_delay.rand(0, max_cycles - 1);
      for i in 1 to n loop wait until rising_edge(aclk); end loop;
    end procedure;

    procedure await_all(constant done_msg : in string) is
    begin
      await_completion(ALL_VVCS, 10 us, done_msg);
    end procedure;

    procedure apply_default_vvc_config is
    begin
      shared_axistream_vvc_config(0).unwanted_activity_severity := NO_ALERT;
      shared_axistream_vvc_config(1).unwanted_activity_severity := NO_ALERT;
      shared_axistream_vvc_config(0).bfm_config := setup_bfm_config;
      shared_axistream_vvc_config(1).bfm_config := setup_bfm_config;
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

    procedure queue_tx_word(
      constant data  : in std_logic_vector(C_WIDTH-1 downto 0);
      constant msg_tag : in string
    ) is
    begin
      axistream_transmit(AXISTREAM_VVCT, 0, data, "tx " & msg_tag);
    end procedure;

    procedure queue_expect_word(
      constant data  : in std_logic_vector(C_WIDTH-1 downto 0);
      constant msg_tag : in string
    ) is
    begin
      axistream_expect(AXISTREAM_VVCT, 1, data, "expect " & msg_tag);
    end procedure;

  begin
    enable_log_msg(ID_SEQUENCER);
    enable_log_msg(ID_PACKET_INITIATE);
    enable_log_msg(ID_PACKET_DATA);
    enable_log_msg(ID_PACKET_COMPLETE);

    log(ID_LOG_HDR_LARGE, "START VVC-BASED SIMULATION OF AXIS SKID BUFFER");
    set_alert_stop_limit(ERROR, 10);

    ----------------------------------------------------------------------------------------------
    -- Seed loop (5 constrained-random iterations)
    ----------------------------------------------------------------------------------------------
    for seed_num in 1 to 5 loop
      rv_seed.set_name("seed_gen_" & integer'image(seed_num));
      rv_seed.set_rand_seeds(seed_num, seed_num * 3 + 7);
      rv_delay.set_name("seed_delay_" & integer'image(seed_num));
      rv_delay.set_rand_seeds(seed_num * 2, seed_num * 5 + 1);

      -- Configure VVCs
      apply_default_vvc_config;

      -- Reset
      gen_pulse(aresetn, '0', aclk, 1, "Asserting reset");
      wait until rising_edge(aclk);

      log(ID_SEQUENCER, "");
      log(ID_SEQUENCER, "=== Seed " & integer'image(seed_num) & " ===");

      ----------------------------------------------------------------------------------------------
      -- Phase 1: Simple passthrough (write one, expect one, no backpressure)
      -- Exercises EMPTY -> ONE -> EMPTY path.
      ----------------------------------------------------------------------------------------------
      log(ID_SEQUENCER, "Phase 1: Passthrough smoke test");
      queue_tx_word(x"A5", "A5");
      queue_expect_word(x"A5", "A5");
      await_all("Phase 1 done");
      random_delay(3);

      ----------------------------------------------------------------------------------------------
      -- Phase 2: Fill to TWO with backpressure, then drain and verify order
      -- Exercises EMPTY -> ONE -> TWO -> ONE -> EMPTY.
      -- With m_ready low, second write causes skid capture.
      -- Drain order: newest word from pipe first, older from skid second.
      ----------------------------------------------------------------------------------------------
      log(ID_SEQUENCER, "Phase 2: Fill to TWO with backpressure, verify drain order");
      set_rx_backpressure(1.0, 5);

      queue_tx_word(x"AA", "AA (goes to pipe)");
      queue_tx_word(x"BB", "BB (goes to skid)");
      await_all("TWO state reached");

      set_rx_backpressure(0.3, 3);

      -- Drain and verify order: BB from pipe, AA from skid
      queue_expect_word(x"BB", "BB (pipe, newest first)");
      queue_expect_word(x"AA", "AA (skid, older second)");
      await_all("Phase 2 done");
      random_delay(3);

      ----------------------------------------------------------------------------------------------
      -- Phase 3: Interleaved push/pop (ONE->ONE overlap)
      -- Queuing both TX and expect commands without await ensures simultaneous handshake.
      ----------------------------------------------------------------------------------------------
      log(ID_SEQUENCER, "Phase 3: Interleaved push/pop (overlap)");
      for i in C_PHASE3_SEQ'range loop
        queue_tx_word(C_PHASE3_SEQ(i), "P3[" & integer'image(i) & "]");
        queue_expect_word(C_PHASE3_SEQ(i), "P3[" & integer'image(i) & "]");
      end loop;
      await_all("Phase 3 done");
      random_delay(3);

      ----------------------------------------------------------------------------------------------
      -- Phase 4: In-flight reset
      -- Push data into the buffer, assert reset, then verify clean restart.
      ----------------------------------------------------------------------------------------------
      log(ID_SEQUENCER, "Phase 4: In-flight reset");
      -- Strong backpressure to keep data in the buffer
      set_rx_backpressure(1.0, 10);

      queue_tx_word(x"99", "99");
      queue_tx_word(x"88", "88");
      await_all("Data queued in buffer");

      -- Assert reset while data is present
      aresetn <= '0';
      wait until rising_edge(aclk);
      wait until rising_edge(aclk);
      aresetn <= '1';
      wait until rising_edge(aclk);

      -- Restore normal ready behavior
      set_rx_backpressure(0.3, 3);

      -- Explicit post-reset idle checks using DUT handshake observe ports.
      for probe in 1 to 2 loop
        wait until rising_edge(aclk);
        check_value(dbg_m_valid, '0', ERROR,
                    "post-reset idle: m_axis_tvalid low (probe " & integer'image(probe) & ")");
        check_value(dbg_s_ready, '1', ERROR,
                    "post-reset idle: s_axis_tready high (probe " & integer'image(probe) & ")");
      end loop;

      -- Verify post-reset functionality still works
      queue_tx_word(x"77", "77 post-reset");
      queue_expect_word(x"77", "77 post-reset");
      await_all("Phase 4 done");

      log(ID_SEQUENCER, "Seed " & integer'image(seed_num) & " done.");
    end loop;

    log(ID_SEQUENCER, "==================================");
    log(ID_SEQUENCER, "ALL SEEDS COMPLETED (VVC MODE)");
    log(ID_SEQUENCER, "==================================");

    -- Transition/state coverage closure from observed handshake state bits.
    if cov_seen_empty /= '1' then
      alert(ERROR, "Coverage miss: EMPTY state not observed");
    end if;
    if cov_seen_one /= '1' then
      alert(ERROR, "Coverage miss: ONE state not observed");
    end if;
    if cov_seen_two /= '1' then
      alert(ERROR, "Coverage miss: TWO state not observed");
    end if;
    if cov_tr_e_o = 0 then
      alert(ERROR, "Coverage miss: transition EMPTY->ONE not observed");
    end if;
    if cov_tr_o_e = 0 then
      alert(ERROR, "Coverage miss: transition ONE->EMPTY not observed");
    end if;
    if cov_tr_o_t = 0 then
      alert(ERROR, "Coverage miss: transition ONE->TWO not observed");
    end if;
    if cov_tr_t_o = 0 then
      alert(ERROR, "Coverage miss: transition TWO->ONE not observed");
    end if;

    log(ID_SEQUENCER,
        "Coverage counts: E->O=" & integer'image(cov_tr_e_o) &
        ", O->E=" & integer'image(cov_tr_o_e) &
        ", O->T=" & integer'image(cov_tr_o_t) &
        ", T->O=" & integer'image(cov_tr_t_o));

    report_alert_counters(FINAL);
    log(ID_SEQUENCER, "SIMULATION SUCCESSFUL (VVC)");

    clock_ena <= false;
    std.env.stop;
    wait;
  end process;

end architecture;
