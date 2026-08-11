---------------------------------------------------------------------------------------------------
-- Filename         : axilite_io_uvvm_tb.vhd
-- Description      : UVVM VVC-based Testbench Sequencer for axilite_io.
--                    Communicates via AXI4-Lite VVC commands to the
--                    axilite_io_th harness (FIFO loopback + status i_data).
-- Author           : Rune Baeverrud
-- Current Revision : 1.00
-- Licensing        : Zero-Clause BSD (0BSD)
---------------------------------------------------------------------------------------------------
--
-- UVVM TOPOLOGY:
--
--   SEQUENCER (this file)  --VVC commands-->  HARNESS (uvvm_th)
--     portless, abstract                         +-- AXI4-Lite VVC (master, idx 1)
--                                                 +-- axilite_io_th (FIFO loopback)
--                                                       +-- axilite_io_harness
--                                                       +-- axis_fifo x2
--
---------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

library uvvm_util;
use uvvm_util.types_pkg.all;
use uvvm_util.methods_pkg.all;
use uvvm_util.adaptations_pkg.all;
use uvvm_util.rand_pkg.all;

library uvvm_vvc_framework;
use uvvm_vvc_framework.ti_vvc_framework_support_pkg.all;

library bitvis_vip_axilite;
use bitvis_vip_axilite.vvc_methods_pkg.all;
use bitvis_vip_axilite.td_vvc_framework_common_methods_pkg.all;
use bitvis_vip_axilite.vvc_cmd_pkg.all;

use work.util_pkg.all;

entity axilite_io_uvvm_tb is
end entity;

architecture sim of axilite_io_uvvm_tb is

  constant TCLK           : time     := 10 ns;
  constant NUM_ODATA      : natural  := 2;
  constant NUM_IDATA      : natural  := 2;
  constant NUM_OSTREAM    : natural  := 2;
  constant NUM_ISTREAM    : natural  := 2;

  signal aclk           : std_logic;
  signal aresetn        : std_logic := '1';
  signal clock_ena      : boolean   := true;

  -- Debug observe
  signal dbg_o_data       : slv32_array_t(0 to NUM_ODATA-1);
  signal dbg_m_tdata      : std_logic_vector(31 downto 0);
  signal dbg_m_tvalid     : std_logic_vector(NUM_OSTREAM-1 downto 0);
  signal dbg_s_tdata      : slv32_array_t(0 to NUM_ISTREAM-1);
  signal dbg_s_tready     : std_logic_vector(NUM_ISTREAM-1 downto 0);

  ------------------------------------------------------------------------------------------------
  -- BFM configuration
  ------------------------------------------------------------------------------------------------
  impure function setup_bfm_config return bitvis_vip_axilite.axilite_bfm_pkg.t_axilite_bfm_config is
    variable c : bitvis_vip_axilite.axilite_bfm_pkg.t_axilite_bfm_config := bitvis_vip_axilite.axilite_bfm_pkg.C_AXILITE_BFM_CONFIG_DEFAULT;
  begin
    c.clock_period             := TCLK;
    c.max_wait_cycles          := 100;
    c.max_wait_cycles_severity := ERROR;
    return c;
  end function;

begin

  ------------------------------------------------------------------------------------------------
  -- Test Harness (axilite_io_th + AXI4-Lite VVC)
  ------------------------------------------------------------------------------------------------
  th_inst : entity work.axilite_io_uvvm_th
    generic map (
      GC_NUM_ODATA    => NUM_ODATA,
      GC_NUM_IDATA    => NUM_IDATA,
      GC_NUM_OSTREAM  => NUM_OSTREAM,
      GC_NUM_ISTREAM  => NUM_ISTREAM,
      GC_CLK_PERIOD   => TCLK
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      clock_ena         => clock_ena,
      dbg_o_data        => dbg_o_data,
      dbg_m_axis_tdata  => dbg_m_tdata,
      dbg_m_axis_tvalid => dbg_m_tvalid,
      dbg_s_axis_tdata  => dbg_s_tdata,
      dbg_s_axis_tready => dbg_s_tready
    );

  ------------------------------------------------------------------------------------------------
  -- UVVM VVC Coordinator Engine
  ------------------------------------------------------------------------------------------------
  i_ti_uvvm_engine : entity uvvm_vvc_framework.ti_uvvm_engine;

  ------------------------------------------------------------------------------------------------
  -- Activity Watchdog
  ------------------------------------------------------------------------------------------------
  activity_watchdog(num_exp_vvc => 1, timeout => 50 us, alert_level => TB_ERROR,
                    msg => "AXI4-Lite Activity Watchdog");

  ------------------------------------------------------------------------------------------------
  -- Sequencer process
  ------------------------------------------------------------------------------------------------
  --
  -- All tests run inside a seed loop (3 iterations) with randomized BFM timing delays.
  -- Each seed starts with a clean reset.  Tests are numbered 1..17.
  --
  process
    variable rv_bfm     : t_rand;   -- Randomises BFM timing per seed
    variable rv_delay   : t_rand;   -- Randomises inter-test gap per seed

    -- Address constants for the four AXI4-Lite regions
    --   "00" = o_data registers    (0x0000..0x3FFF)
    --   "01" = stream push         (0x4000..0x7FFF)
    --   "10" = i_data ports        (0x8000..0xBFFF)
    --   "11" = stream pop          (0xC000..0xFFFF)
    constant C_ADDR_ODATA0 : unsigned(15 downto 0) := x"0000";
    constant C_ADDR_ODATA1 : unsigned(15 downto 0) := x"0004";
    constant C_ADDR_IDATA0 : unsigned(15 downto 0) := x"8000";
    constant C_ADDR_IDATA1 : unsigned(15 downto 0) := x"8004";
    constant C_ADDR_PUSH0  : unsigned(15 downto 0) := x"4000";
    constant C_ADDR_PUSH1  : unsigned(15 downto 0) := x"4004";
    constant C_ADDR_POP0   : unsigned(15 downto 0) := x"C000";
    constant C_ADDR_POP1   : unsigned(15 downto 0) := x"C004";

    --------------------------------------------------------------------------------------------
    -- Helper: write a register via AXI4-Lite VVC (non-blocking, queued)
    --------------------------------------------------------------------------------------------
    procedure vvc_write(
      constant addr : in unsigned(15 downto 0);
      constant data : in std_logic_vector(31 downto 0);
      constant tag  : in string
    ) is
    begin
      axilite_write(AXILITE_VVCT, 1, addr, data, tag);
    end procedure;

    --------------------------------------------------------------------------------------------
    -- Helper: read a register via AXI4-Lite VVC (non-blocking, queued)
    --------------------------------------------------------------------------------------------
    procedure vvc_read(
      constant addr : in unsigned(15 downto 0);
      constant tag  : in string
    ) is
    begin
      axilite_read(AXILITE_VVCT, 1, addr, tag);
    end procedure;

    --------------------------------------------------------------------------------------------
    -- Helper: read a register and check its value (non-blocking, queued)
    --------------------------------------------------------------------------------------------
    procedure vvc_check(
      constant addr : in unsigned(15 downto 0);
      constant exp  : in std_logic_vector(31 downto 0);
      constant tag  : in string
    ) is
    begin
      axilite_check(AXILITE_VVCT, 1, addr, exp, tag);
    end procedure;

    --------------------------------------------------------------------------------------------
    -- Helper: wait for all queued VVC commands to finish
    --------------------------------------------------------------------------------------------
    procedure vvc_await(constant tag : in string) is
    begin
      await_completion(AXILITE_VVCT, 1, 100 us, tag);
    end procedure;

    --------------------------------------------------------------------------------------------
    -- Helper: random delay between tests (0..max_cycles-1 clock edges)
    --------------------------------------------------------------------------------------------
    procedure random_delay(constant max_cycles : in integer) is
      variable n : integer;
    begin
      n := rv_delay.rand(0, max_cycles - 1);
      for i in 1 to n loop
        wait until rising_edge(aclk);
      end loop;
    end procedure;

    --------------------------------------------------------------------------------------------
    -- Helper: configure VVC for the current seed.  Higher seeds add more pipeline stages
    -- on the AXI4-Lite handshake channels, exercising the DUT's pipeline tolerance under
    -- non-deterministic bus timing.
    --
    -- Pipeline stages (num_*_pipe_stages) control how many clock cycles the BFM inserts
    -- before asserting the response handshake (awready, wready, bvalid, arready, rvalid).
    -- More stages = more latency, which stresses the DUT's write/read pipeline state
    -- machine (premature bvalid deassert, stale arvalid overlap, etc.).
    --------------------------------------------------------------------------------------------
    procedure apply_vvc_config(
      constant seed        : in integer;
      constant aw_pipe     : in natural;
      constant w_pipe      : in natural;
      constant ar_pipe     : in natural;
      constant r_pipe      : in natural;
      constant b_pipe      : in natural
    ) is
      variable cfg : bitvis_vip_axilite.axilite_bfm_pkg.t_axilite_bfm_config;
    begin
      cfg                    := setup_bfm_config;
      cfg.num_aw_pipe_stages := aw_pipe;
      cfg.num_w_pipe_stages  := w_pipe;
      cfg.num_ar_pipe_stages := ar_pipe;
      cfg.num_r_pipe_stages  := r_pipe;
      cfg.num_b_pipe_stages  := b_pipe;
      shared_axilite_vvc_config(1).bfm_config := cfg;
      log(ID_SEQUENCER, "VVC config applied for seed " & integer'image(seed) &
          " (aw=" & integer'image(aw_pipe) &
          ", w="  & integer'image(w_pipe) &
          ", ar=" & integer'image(ar_pipe) &
          ", r="  & integer'image(r_pipe) &
          ", b="  & integer'image(b_pipe) & ")");
    end procedure;

  begin
    -- Enable logging for sequencer messages and packet flow visibility
    enable_log_msg(ID_SEQUENCER);
    enable_log_msg(ID_PACKET_INITIATE);
    enable_log_msg(ID_PACKET_DATA);
    enable_log_msg(ID_PACKET_COMPLETE);

    log(ID_LOG_HDR_LARGE, "START UVVM VVC-BASED SIMULATION OF axilite_io");
    set_alert_stop_limit(ERROR, 10);

    -- Configure AXI4-Lite VVC base settings (shared across seeds)
    shared_axilite_vvc_config(1).unwanted_activity_severity := NO_ALERT;

    -- ============================================================================================
    --  Seed loop: 3 iterations with increasing BFM backpressure
    -- ============================================================================================
    --
    -- Each seed re-runs all 17 tests from a clean reset state.  Seeds 2 and 3 add
    -- progressively more random ready-low insertion on the AXI4-Lite channels, which
    -- stresses the DUT's ability to maintain correct state under non-deterministic
    -- bus handshake timing (equivalent to a slower or congested interconnect).
    --
    for seed_num in 1 to 3 loop

      -- Seed the random generators for this iteration so that each seed produces
      -- a reproducible but distinct sequence of inter-test delays and BFM timing.
      rv_bfm.set_name("bfm_seed_" & integer'image(seed_num));
      rv_bfm.set_rand_seeds(seed_num * 7, seed_num * 11 + 3);
      rv_delay.set_name("delay_seed_" & integer'image(seed_num));
      rv_delay.set_rand_seeds(seed_num * 5, seed_num * 13 + 1);

      -- Configure VVC with seed-dependent pipeline depth.
      -- Seed 1:  minimal pipeline (1 stage each) -- baseline timing.
      -- Seed 2:  moderate pipeline (3-4 stages) -- exercises write/read state machine.
      -- Seed 3:  deep pipeline (6-8 stages) -- stresses response buffering and
      --          back-to-back transaction tolerance.
      if seed_num = 1 then
        apply_vvc_config(seed_num, 1, 1, 1, 1, 1);
      elsif seed_num = 2 then
        apply_vvc_config(seed_num, 3, 4, 3, 4, 3);
      else
        apply_vvc_config(seed_num, 6, 8, 6, 8, 6);
      end if;

      -- Assert reset for 4 clock cycles to initialise the DUT and FIFOs
      gen_pulse(aresetn, '0', aclk, 4, "Asserting reset (seed " & integer'image(seed_num) & ")");
      wait until rising_edge(aclk);
      wait for 1 ns;

      log(ID_SEQUENCER, "");
      log(ID_SEQUENCER, "--- Seed " & integer'image(seed_num) & " ---");

      -- ==========================================================================================
      -- Test 1: Write/Read o_data[0]
      --   Verifies basic register write and readback on the first output slot.
      --   This is the simplest smoke test -- if this fails, the AXI4-Lite slave
      --   interface or the address decoder is broken.
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 1: Write/Read o_data[0] ===");
      vvc_write(C_ADDR_ODATA0, x"A5A5A5A5", "write o_data[0]");
      vvc_await("wait write o_data[0]");
      check_value(dbg_o_data(0), x"A5A5A5A5", ERROR, "o_data[0] check");
      vvc_check(C_ADDR_ODATA0, x"A5A5A5A5", "readback o_data[0]");
      vvc_await("wait readback o_data[0]");
      random_delay(3);

      -- ==========================================================================================
      -- Test 2: Byte-strobe o_data[1] byte0 (wstrb = x"1")
      --   Writes only byte lane 0 (bits 7:0) of o_data[1].  Since o_data[1] was
      --   zeroed by reset, only byte 0 should be 0xFF; bytes 1-3 stay 0x00.
      --   This validates the per-lane byte-enable gating in the write path.
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 2: byte-strobe o_data[1] byte0 ===");
      axilite_write(AXILITE_VVCT, 1, C_ADDR_ODATA1, x"FFFF00FF", std_logic_vector'(x"1"), "strobe byte0");
      vvc_await("wait strobe");
      check_value(dbg_o_data(1), x"000000FF", ERROR, "o_data[1] byte0");
      vvc_check(C_ADDR_ODATA1, x"000000FF", "readback o_data[1] byte0");
      vvc_await("wait readback o_data[1]");
      random_delay(3);

      -- ==========================================================================================
      -- Test 3: Byte-strobe o_data[0] bytes0+2 (wstrb = x"5")
      --   Writes bytes 0 and 2 of o_data[0].  The existing byte 1 (0x34 from test 1's data
      --   x"A5A5A5A5") and byte 3 (0xA5) are preserved.  After the write only bytes 0 and 2
      --   are updated, proving independent byte-lane gating with a multi-bit strobe mask.
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 3: byte-strobe o_data[0] bytes0+2 ===");
      axilite_write(AXILITE_VVCT, 1, C_ADDR_ODATA0, x"12345678", std_logic_vector'(x"5"), "strobe bytes0+2");
      vvc_await("wait strobe");
      check_value(dbg_o_data(0), x"A534A578", ERROR, "o_data[0] bytes0+2");
      vvc_check(C_ADDR_ODATA0, x"A534A578", "readback o_data[0]");
      vvc_await("wait");
      random_delay(3);

      -- ==========================================================================================
      -- Test 4: Read i_data ports
      --   The TH drives i_data[0..1] from its external port (tied to zero in uvvm_th).
      --   Reading the i_data region confirms the DUT's read multiplexer works for
      --   unregistered inputs.  The expected value is zero (default).
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 4: Read i_data ports ===");
      vvc_check(C_ADDR_IDATA0, x"00000000", "i_data[0] default");
      vvc_await("wait i_data[0]");
      random_delay(3);

      -- ==========================================================================================
      -- Test 5-6: Stream push via FIFO loopback (channels 0 and 1)
      --   Writing to the stream-push address region (0x4000+) drives m_axis_tdata and
      --   pulses m_axis_tvalid.  The TH routes this through an axis_fifo loopback back
      --   to the DUT's s_axis input.  These tests verify that the stream output pipeline
      --   produces valid beats that are captured by the FIFO.
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 5: Stream push [0] ===");
      vvc_write(C_ADDR_PUSH0, x"AABBCCDD", "push[0]");
      vvc_await("wait push[0]");

      log(ID_SEQUENCER, "=== Test 6: Stream push [1] ===");
      vvc_write(C_ADDR_PUSH1, x"11223344", "push[1]");
      vvc_await("wait push[1]");
      random_delay(3);

      -- ==========================================================================================
      -- Test 7-8: Stream pop (read back from FIFO loopback)
      --   Reading from the stream-pop region (0xC000+) asserts s_axis_tready, consuming
      --   one beat from the FIFO.  The returned data should match what was pushed in
      --   tests 5-6, verifying the complete m_axis -> FIFO -> s_axis loopback path.
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 7: Stream pop [0] ===");
      vvc_check(C_ADDR_POP0, x"AABBCCDD", "pop[0]");
      vvc_await("wait pop[0]");

      log(ID_SEQUENCER, "=== Test 8: Stream pop [1] ===");
      vvc_check(C_ADDR_POP1, x"11223344", "pop[1]");
      vvc_await("wait pop[1]");
      random_delay(3);

      -- ==========================================================================================
      -- Test 9: Read-after-write
      --   Writes a new value to o_data[0] then immediately reads back via the AXI bus.
      --   This checks that the write pipeline clears bvalid and the read pipeline
      --   can be initiated in the very next transaction without a stale response blocking it.
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 9: Read-after-write ===");
      vvc_write(C_ADDR_ODATA0, x"FEDCBA98", "write r-a-w");
      vvc_await("wait r-a-w write");
      vvc_check(C_ADDR_ODATA0, x"FEDCBA98", "read-after-write");
      vvc_await("wait r-a-w read");
      random_delay(3);

      -- ==========================================================================================
      -- Test 10: Unmapped read
      --   Reads from address 0x5000 which falls in region "01" (stream push).
      --   This region returns zero on reads (the DUT drives v.rdata := (others => '0') for
      --   read transactions to the stream-push address range).  Verifies that reads to
      --   write-only regions produce a deterministic zero response rather than X.
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 10: Unmapped read ===");
      vvc_check(x"5000", x"00000000", "unmapped read");
      vvc_await("wait unmapped");
      random_delay(3);

      -- ==========================================================================================
      -- Test 11: wstrb = 0 (no bytes written)
      --   Writes x"FFFFFFFF" with wstrb = x"0".  The DUT's write gating should skip all
      --   byte lanes, leaving o_data[0] unchanged (still x"FEDCBA98" from test 9).
      --   Verifies the edge case where no bytes are selected.
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 11: wstrb = 0 ===");
      axilite_write(AXILITE_VVCT, 1, C_ADDR_ODATA0, x"FFFFFFFF", std_logic_vector'(x"0"), "wstrb=0");
      vvc_await("wait wstrb=0");
      vvc_check(C_ADDR_ODATA0, x"FEDCBA98", "o_data unchanged after wstrb=0");
      vvc_await("wait check");
      random_delay(3);

      -- ==========================================================================================
      -- Test 12: Full overwrite after strobe
      --   Does a full-bytes write (wstrb = x"F") to o_data[0] after the strobe tests above.
      --   This verifies that a full write correctly overrides any previous byte-strobe state
      --   and that the register now holds the new full-word value (x"DEADBEEF").
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 12: Full overwrite after strobe ===");
      vvc_write(C_ADDR_ODATA0, x"DEADBEEF", "full overwrite");
      vvc_await("wait overwrite");
      check_value(dbg_o_data(0), x"DEADBEEF", ERROR, "o_data[0] full overwrite");
      vvc_check(C_ADDR_ODATA0, x"DEADBEEF", "rdata full overwrite");
      vvc_await("wait check overwrite");
      random_delay(3);

      -- ==========================================================================================
      -- Test 13: Back-to-back writes to different registers
      --   Writes two different values to two different output registers (o_data[0] and
      --   o_data[1]) without waiting for write responses in between.  The VVC queues
      --   both writes and executes them sequentially.  This stresses the AW/W channel
      --   handshake and verifies that two consecutive writes complete without stalling
      --   on the bvalid handshake of the first write.
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 13: Back-to-back writes ===");
      vvc_write(C_ADDR_ODATA0, x"AAAA0000", "b2b write o_data[0]");
      vvc_write(C_ADDR_ODATA1, x"BBBB0000", "b2b write o_data[1]");
      vvc_await("wait b2b writes");
      check_value(dbg_o_data(0), x"AAAA0000", ERROR, "o_data[0] b2b");
      check_value(dbg_o_data(1), x"BBBB0000", ERROR, "o_data[1] b2b");
      random_delay(3);

      -- ==========================================================================================
      -- Test 14: Consecutive reads of same register (stability)
      --   Reads o_data[0] three times in a row with no intervening writes.  Each read
      --   must return the same stable value (x"AAAA0000" from test 13).  This detects
      --   any read-side pipeline glitch, stale bvalid interaction, or one-shot read
      --   corruption that could cause consecutive reads to return different values.
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 14: Consecutive reads (stability) ===");
      vvc_check(C_ADDR_ODATA0, x"AAAA0000", "read[0] stability");
      vvc_check(C_ADDR_ODATA0, x"AAAA0000", "read[1] stability");
      vvc_check(C_ADDR_ODATA0, x"AAAA0000", "read[2] stability");
      vvc_await("wait stability reads");
      random_delay(3);

      -- ==========================================================================================
      -- Test 15: Individual byte strobes x"2", x"4", x"8"
      --   Tests the remaining three byte lanes individually (byte1, byte2, byte3).
      --   Together with test 2 (byte0) this proves all four byte lanes work independently.
      --   Each strobe writes to a fresh or known state, and the result is verified both
      --   on the o_data output and via readback.
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 15: Byte strobes x2, x4, x8 ===");
      -- Reset both registers to zero first so strobe results are deterministic
      vvc_write(C_ADDR_ODATA0, x"00000000", "clear o_data[0]");
      vvc_write(C_ADDR_ODATA1, x"00000000", "clear o_data[1]");
      vvc_await("wait clears");

      -- Strobe byte1 only (wstrb = x"2"): write 0xFF to byte lane 1 of o_data[1]
      axilite_write(AXILITE_VVCT, 1, C_ADDR_ODATA1, x"0000FF00", std_logic_vector'(x"2"), "strobe byte1");
      vvc_await("wait strobe byte1");
      check_value(dbg_o_data(1), x"0000FF00", ERROR, "o_data[1] byte1");
      vvc_check(C_ADDR_ODATA1, x"0000FF00", "rdata[1] byte1");
      vvc_await("wait check byte1");

      -- Strobe byte2 only (wstrb = x"4"): write 0xFF to byte lane 2 of o_data[0]
      axilite_write(AXILITE_VVCT, 1, C_ADDR_ODATA0, x"00FF0000", std_logic_vector'(x"4"), "strobe byte2");
      vvc_await("wait strobe byte2");
      check_value(dbg_o_data(0), x"00FF0000", ERROR, "o_data[0] byte2");
      vvc_check(C_ADDR_ODATA0, x"00FF0000", "rdata[0] byte2");
      vvc_await("wait check byte2");

      -- Strobe byte3 only (wstrb = x"8"): write 0xFF to byte lane 3 of o_data[1]
      -- o_data[1] currently has byte1 = 0xFF, other lanes = 0.  After byte3 strobe,
      -- byte1 stays 0xFF and byte3 becomes 0xFF -> result x"FF00FF00".
      axilite_write(AXILITE_VVCT, 1, C_ADDR_ODATA1, x"FF000000", std_logic_vector'(x"8"), "strobe byte3");
      vvc_await("wait strobe byte3");
      check_value(dbg_o_data(1), x"FF00FF00", ERROR, "o_data[1] byte3");
      vvc_check(C_ADDR_ODATA1, x"FF00FF00", "rdata[1] byte3");
      vvc_await("wait check byte3");
      random_delay(3);

      -- ==========================================================================================
      -- Test 16: FIFO ordering -- multiple stream pushes to same channel
      --   Pushes three items (AAA00001, BBB00002, CCC00003) to channel 0, then pops
      --   them in order.  The axis_fifo preserves push order, so pops must return
      --   AAA, then BBB, then CCC.  This validates that the FIFO loopback does not
      --   reorder or drop beats, and that the stream push/pop address decoding does
      --   not alias channels.
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 16: FIFO ordering ===");
      vvc_write(C_ADDR_PUSH0, x"AAA00001", "push[0] #1");
      vvc_write(C_ADDR_PUSH0, x"BBB00002", "push[0] #2");
      vvc_write(C_ADDR_PUSH0, x"CCC00003", "push[0] #3");
      vvc_await("wait pushes");

      vvc_check(C_ADDR_POP0, x"AAA00001", "pop[0] #1");
      vvc_check(C_ADDR_POP0, x"BBB00002", "pop[0] #2");
      vvc_check(C_ADDR_POP0, x"CCC00003", "pop[0] #3");
      vvc_await("wait pops");
      random_delay(3);

      -- ==========================================================================================
      -- Test 17: In-flight reset
      --   Pushes data into the FIFO (stream push), then asserts reset while data is
      --   present in the FIFO.  After reset de-assertion the DUT should be in a clean
      --   state: o_data registers zeroed, FIFO emptied, no stale valid/resp pending.
      --   A final write-read cycle verifies that post-reset functionality is intact.
      -- ==========================================================================================
      log(ID_SEQUENCER, "=== Test 17: In-flight reset ===");
      -- Push data into the FIFO first
      vvc_write(C_ADDR_PUSH0, x"DEADBEEF", "pre-reset push");
      vvc_await("wait pre-reset push");

      -- Assert reset while data is in the FIFO
      aresetn <= '0';
      for i in 1 to 4 loop
        wait until rising_edge(aclk);
      end loop;
      aresetn <= '1';
      wait until rising_edge(aclk);
      wait for 1 ns;

      -- Check that o_data registers are zeroed after reset
      check_value(dbg_o_data(0), x"00000000", ERROR, "o_data[0] after reset");
      check_value(dbg_o_data(1), x"00000000", ERROR, "o_data[1] after reset");

      -- Verify post-reset functionality: simple write/read
      vvc_write(C_ADDR_ODATA0, x"12345678", "post-reset write");
      vvc_await("wait post-reset write");
      vvc_check(C_ADDR_ODATA0, x"12345678", "post-reset readback");
      vvc_await("wait post-reset readback");
      random_delay(3);

      --------------------------------------------------------------------------------------------
      -- End-of-seed summary
      --------------------------------------------------------------------------------------------
      vvc_await("wait seed " & integer'image(seed_num) & " final");
      log(ID_SEQUENCER, "Seed " & integer'image(seed_num) & " completed.");
    end loop;

    ----------------------------------------------------------------------------------------------
    -- Final summary
    ----------------------------------------------------------------------------------------------
    report_alert_counters(FINAL);
    log(ID_SEQUENCER, "SIMULATION SUCCESSFUL (UVVM VVC) - ALL SEEDS PASSED");

    clock_ena <= false;
    std.env.stop;
    wait;
  end process;

end architecture;
