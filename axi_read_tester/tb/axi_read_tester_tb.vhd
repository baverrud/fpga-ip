-----------------------------------------------------------------------
--Filename         : axi_read_tester_tb.vhd
--Description      : Corner-case testbench for axi_read_tester.
--                   Instantiates axi_mem_model directly on the
--                   AR/R buses.  Runs 10 phases covering single-beat,
--                   max-burst, 4KB boundary, random addressing,
--                   zero/high latency, aperture gating, stat/err
--                   reset, and in-flight reset.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity axi_read_tester_tb is
end entity;

architecture sim of axi_read_tester_tb is

  constant C_CLK_PERIOD : time    := 10 ns;
  constant C_DRAIN      : natural := 500;   -- idle cycles after each phase
  constant C_DATA_BYTES : natural := 64;
  constant C_ADDR_WIDTH : natural := 32;
  constant C_ID_WIDTH   : natural := 4;
  constant C_TIME_WIDTH : natural := 48;
  constant C_STAT_WIDTH : natural := 48;

  -- Clock and reset
  signal aclk          : std_logic := '0';
  signal aresetn       : std_logic := '0';
  signal sim_done      : boolean   := false;
  signal global_time   : unsigned(C_TIME_WIDTH-1 downto 0) := (others => '0');

  -- Tester control
  signal enable_local  : std_logic := '0';
  signal aperture      : std_logic := '0';
  signal stat_rst      : std_logic := '0';
  signal err_rst       : std_logic := '0';

  -- AR generation configuration
  signal arid          : std_logic_vector(C_ID_WIDTH-1 downto 0) := X"1";
  signal burst_length  : std_logic_vector(31 downto 0) := X"00000008";
  signal pace          : std_logic_vector(31 downto 0) := (others => '0');
  signal pace_init     : std_logic_vector(31 downto 0) := (others => '0');
  signal base_addr     : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := X"00001000";
  signal addr_range    : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := X"00004000";
  signal addr_mode     : std_logic := '0';

  -- Memory model configuration
  signal ar_base_enable   : std_logic := '1';
  signal ar_jitter_enable : std_logic := '1';
  signal r_base_enable    : std_logic := '1';
  signal r_jitter_enable  : std_logic := '1';
  signal base_latency     : std_logic_vector(15 downto 0) := (others => '0');
  signal base_beat_gap    : std_logic_vector(15 downto 0) := (others => '0');

  -- AXI4 AR bus (tester -> memory model)
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;
  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);

  -- AXI4 R bus (memory model -> tester)
  signal r_valid : std_logic;
  signal r_ready : std_logic;
  signal r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data  : std_logic_vector(8*C_DATA_BYTES-1 downto 0);
  signal r_resp  : std_logic_vector(1 downto 0);
  signal r_last  : std_logic;

  -- Monitored statistics
  signal stat_xactions           : std_logic_vector(31 downto 0);
  signal stat_beats              : std_logic_vector(31 downto 0);
  signal stat_data_errors        : std_logic_vector(31 downto 0);
  signal stat_id_errors          : std_logic_vector(31 downto 0);
  signal stat_rlast_errors       : std_logic_vector(31 downto 0);
  signal stat_resp_errors        : std_logic_vector(31 downto 0);
  signal stat_sb_underflow_errors: std_logic_vector(31 downto 0);
  signal pipeline_busy      : std_logic;
  signal stat_latency_sum        : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_latency_min        : std_logic_vector(31 downto 0);
  signal stat_latency_max        : std_logic_vector(31 downto 0);
  signal stat_first_latency_min  : std_logic_vector(31 downto 0);
  signal stat_first_latency_max  : std_logic_vector(31 downto 0);
  signal stat_first_latency_sum  : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_interbeat_gap_sum  : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_interbeat_gap_min  : std_logic_vector(31 downto 0);
  signal stat_interbeat_gap_max  : std_logic_vector(31 downto 0);
  signal stat_ar_backpressure    : std_logic_vector(31 downto 0);
  signal stat_sb_backpressure    : std_logic_vector(31 downto 0);
  signal stat_ar_issued          : std_logic_vector(31 downto 0);
  signal stat_cfg_errors         : std_logic_vector(31 downto 0);
  signal stat_elapsed_cycles     : std_logic_vector(31 downto 0);
  signal stat_max_outstanding    : std_logic_vector(31 downto 0);

  -- Helper functions
  function u32(n : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(n, 32));
  end function;

  function u16(n : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(n, 16));
  end function;

  -- Wait for n clock cycles
  procedure wait_cycles(n : natural) is
  begin
    for i in 1 to n loop
      wait until rising_edge(aclk);
    end loop;
  end procedure;

begin

  -- Clock generator
  aclk <= not aclk after C_CLK_PERIOD / 2 when not sim_done else '0';

  -- Every issued burst must remain inside the configured address window.
  p_ar_window_check : process(aclk)
    variable burst_bytes : unsigned(C_ADDR_WIDTH downto 0);
    variable burst_end   : unsigned(C_ADDR_WIDTH downto 0);
    variable window_end  : unsigned(C_ADDR_WIDTH downto 0);
  begin
    if rising_edge(aclk) and aresetn = '1' and
       ar_valid = '1' and ar_ready = '1' then
      burst_bytes := to_unsigned(
        (to_integer(unsigned(ar_len)) + 1) * C_DATA_BYTES,
        C_ADDR_WIDTH + 1);
      burst_end   := resize(unsigned(ar_addr), C_ADDR_WIDTH + 1) + burst_bytes;
      window_end  := resize(unsigned(base_addr), C_ADDR_WIDTH + 1) +
                     resize(unsigned(addr_range), C_ADDR_WIDTH + 1);
      assert burst_end <= window_end
        report "AR burst exceeds configured address window" severity error;
    end if;
  end process;

  -- Global time counter
  p_global_time : process(aclk)
  begin
    if rising_edge(aclk) and aresetn = '1' then
      global_time <= global_time + 1;
    end if;
  end process;

  --------------------------------------------------------------------
  -- DUT: axi_read_tester (AR generator + scoreboard + R monitor)
  --------------------------------------------------------------------
  u_dut : entity work.axi_read_tester
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_TIME_WIDTH    => C_TIME_WIDTH,
      GC_STAT_WIDTH    => C_STAT_WIDTH,
      GC_SB_FIFO_DEPTH => 256,
      GC_MAX_BURST     => 256
    )
    port map (
      aclk                      => aclk,
      aresetn                   => aresetn,
      global_time               => global_time,


      enable_local              => enable_local,
      aperture                  => aperture,
      stat_rst                  => stat_rst,
      err_rst                   => err_rst,

      arid                      => arid,
      burst_length              => burst_length,
      pace                      => pace,
      pace_init                 => pace_init,
      base_addr                 => base_addr,
      addr_range                => addr_range,
      addr_mode                 => addr_mode,

      -- AR bus -> memory model
      ar_valid                  => ar_valid,
      ar_ready                  => ar_ready,
      ar_id                     => ar_id,
      ar_addr                   => ar_addr,
      ar_len                    => ar_len,

      -- R bus <- memory model
      r_valid                   => r_valid,
      r_ready                   => r_ready,
      r_id                      => r_id,
      r_data                    => r_data,
      r_resp                    => r_resp,
      r_last                    => r_last,

      -- Statistics
      stat_xactions             => stat_xactions,
      stat_beats                => stat_beats,
      stat_latency_sum          => stat_latency_sum,
      stat_latency_min          => stat_latency_min,
      stat_latency_max          => stat_latency_max,
      stat_first_latency_sum    => stat_first_latency_sum,
      stat_first_latency_min    => stat_first_latency_min,
      stat_first_latency_max    => stat_first_latency_max,
      stat_interbeat_gap_sum    => stat_interbeat_gap_sum,
      stat_interbeat_gap_min    => stat_interbeat_gap_min,
      stat_interbeat_gap_max    => stat_interbeat_gap_max,
      stat_ar_backpressure      => stat_ar_backpressure,
      stat_sb_backpressure      => stat_sb_backpressure,
      stat_ar_issued            => stat_ar_issued,
      stat_cfg_errors           => stat_cfg_errors,
      stat_elapsed_cycles       => stat_elapsed_cycles,
      pipeline_busy        => pipeline_busy,
      stat_data_errors          => stat_data_errors,
      stat_id_errors            => stat_id_errors,
      stat_rlast_errors         => stat_rlast_errors,
      stat_resp_errors          => stat_resp_errors,
      stat_sb_underflow_errors  => stat_sb_underflow_errors,
      stat_max_outstanding      => stat_max_outstanding
    );

  --------------------------------------------------------------------
  -- Memory model -- responds to AR beats with address-derived data.
  --------------------------------------------------------------------
  u_mem : entity work.axi_mem_model
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_AR_FIFO_DEPTH => 256,
      GC_TIMER_WIDTH   => 16,
      GC_R_FIFO_DEPTH  => 8
    )
    port map (
      aclk             => aclk,
      aresetn          => aresetn,
      ar_base_enable   => ar_base_enable,
      ar_jitter_enable => ar_jitter_enable,
      r_base_enable    => r_base_enable,
      r_jitter_enable  => r_jitter_enable,
      base_latency     => base_latency,
      base_beat_gap    => base_beat_gap,
      ar_valid         => ar_valid,
      ar_ready         => ar_ready,
      ar_id            => ar_id,
      ar_addr          => ar_addr,
      ar_len           => ar_len,
      r_valid          => r_valid,
      r_ready          => r_ready,
      r_id             => r_id,
      r_data           => r_data,
      r_resp           => r_resp,
      r_last           => r_last
    );

  --------------------------------------------------------------------
  -- Stimulus
  --------------------------------------------------------------------
  p_stimulus : process
    variable l         : line;
    variable all_pass  : boolean;

    -- Print stats and check for errors
    procedure check_phase(
      expected_beats_per_xaction : natural := 0;
      expect_cfg_error            : boolean := false
    ) is
      variable errs : unsigned(31 downto 0);
    begin
      all_pass := true;

      write(l, string'("  beats="));
      write(l, to_integer(unsigned(stat_beats)));
      write(l, string'(" xact="));
      write(l, to_integer(unsigned(stat_xactions)));
      write(l, string'(" data="));
      write(l, to_integer(unsigned(stat_data_errors)));
      write(l, string'(" id="));
      write(l, to_integer(unsigned(stat_id_errors)));
      write(l, string'(" rlast="));
      write(l, to_integer(unsigned(stat_rlast_errors)));
      write(l, string'(" sb_uf="));
      write(l, to_integer(unsigned(stat_sb_underflow_errors)));
      writeline(output, l);

      errs := unsigned(stat_data_errors)
            + unsigned(stat_id_errors)
            + unsigned(stat_rlast_errors)
            + unsigned(stat_resp_errors)
            + unsigned(stat_sb_underflow_errors);
      if errs > 0 then
        write(l, string'("  FAIL"));
        writeline(output, l);
        all_pass := false;
      else
        write(l, string'("  PASS"));
        writeline(output, l);
      end if;

      if expected_beats_per_xaction > 0 and
         unsigned(stat_beats) /=
         to_unsigned(to_integer(unsigned(stat_xactions)) *
                     expected_beats_per_xaction, 32) then
        write(l, string'("  FAIL: beat/xaction count mismatch"));
        writeline(output, l);
        all_pass := false;
      end if;

      if expect_cfg_error and unsigned(stat_cfg_errors) = 0 then
        write(l, string'("  FAIL: expected configuration error"));
        writeline(output, l);
        all_pass := false;
      end if;

      assert all_pass report "Test phase failed" severity error;
    end procedure;

    -- Run one test phase: configure, enable, run, drain, check, disable, reset
    procedure run_phase(
      phase_name       : string;
      phase_base_addr  : std_logic_vector(31 downto 0);
      phase_burst_len  : std_logic_vector(31 downto 0);
      phase_addr_range : std_logic_vector(31 downto 0);
      phase_addr_mode  : std_logic;
      phase_latency    : std_logic_vector(15 downto 0);
      phase_gap        : std_logic_vector(15 downto 0);
      phase_cycles     : natural;
      expected_beats_per_xaction : natural := 0;
      expect_cfg_error            : boolean := false
    ) is
    begin
      base_addr   <= phase_base_addr;
      burst_length   <= phase_burst_len;
      addr_range  <= phase_addr_range;
      addr_mode   <= phase_addr_mode;
base_latency <= phase_latency;
    base_beat_gap<= phase_gap;

      enable_local  <= '1';

      write(l, string'("=== "));
      write(l, phase_name);
      write(l, string'(" ==="));
      writeline(output, l);

      aperture <= '1';
      wait_cycles(phase_cycles);
      aperture <= '0';
      wait_cycles(C_DRAIN);

      -- Drain all in-flight AR/R activity before checking statistics.
      for i in 1 to 100000 loop
        exit when pipeline_busy = '0';
        wait_cycles(1);
      end loop;
      assert pipeline_busy = '0'
        report "Pipeline did not drain before phase check" severity error;

      check_phase(expected_beats_per_xaction, expect_cfg_error);

      enable_local  <= '0';
      aresetn         <= '0';
      wait_cycles(10);
      aresetn         <= '1';
      wait_cycles(5);
    end procedure;

  begin
    -- Power-on reset
    aresetn <= '0';
    wait_cycles(5);
    aresetn <= '1';
    wait_cycles(5);

    -- P1: Standard 16-beat bursts
    run_phase(
      phase_name       => "P1: 16-beat",
      phase_base_addr  => X"00001000",
      phase_burst_len => u32(16),
      phase_addr_range => X"00004000",
      phase_addr_mode  => '0',
      phase_latency    => u16(5),
      phase_gap        => u16(3),
      phase_cycles     => 800,
      expected_beats_per_xaction => 16
    );

    -- P2: Single-beat bursts (blen=0 -> 1 beat)
    run_phase(
      phase_name       => "P2: Single-beat",
      phase_base_addr  => X"00010000",
      phase_burst_len => u32(1),
      phase_addr_range => X"00001000",
      phase_addr_mode  => '0',
      phase_latency    => u16(5),
      phase_gap        => u16(3),
      phase_cycles     => 500,
      expected_beats_per_xaction => 1
    );

    -- P3: Maximum-length 256-beat bursts
    run_phase(
      phase_name       => "P3: Max burst 256",
      phase_base_addr  => X"00020000",
      phase_burst_len => u32(256),
      phase_addr_range => X"00100000",
      phase_addr_mode  => '0',
      phase_latency    => u16(5),
      phase_gap        => u16(3),
      phase_cycles     => 500,
      expected_beats_per_xaction => 256
    );

    -- P4: 4 KB boundary crossing (base 0xFE0 + 2 beats x 64 B = over)
    run_phase(
      phase_name       => "P4: 4KB boundary",
      phase_base_addr  => X"00000FE0",
      phase_burst_len => u32(2),
      phase_addr_range => X"00001000",
      phase_addr_mode  => '0',
      phase_latency    => u16(5),
      phase_gap        => u16(3),
      phase_cycles     => 500,
      expected_beats_per_xaction => 2
    );

    -- P5: Random addressing mode
    run_phase(
      phase_name       => "P5: Random",
      phase_base_addr  => X"00030000",
      phase_burst_len  => u32(8),
      phase_addr_range => X"00010000",
      phase_addr_mode  => '1',
      phase_latency    => u16(5),
      phase_gap        => u16(3),
      phase_cycles     => 800,
      expected_beats_per_xaction => 8
    );
    addr_mode <= '0';

    -- P6: Zero latency
    run_phase(
      phase_name       => "P6: Zero latency",
      phase_base_addr  => X"00040000",
      phase_burst_len  => u32(8),
      phase_addr_range => X"00004000",
      phase_addr_mode  => '0',
      phase_latency    => u16(0),
      phase_gap        => u16(0),
      phase_cycles     => 500,
      expected_beats_per_xaction => 8
    );

    -- P7: High latency (30 cycle base, 10 cycle gap)
    run_phase(
      phase_name       => "P7: High latency 30/10",
      phase_base_addr  => X"00050000",
      phase_burst_len  => u32(8),
      phase_addr_range => X"00004000",
      phase_addr_mode  => '0',
      phase_latency    => u16(30),
      phase_gap        => u16(10),
      phase_cycles     => 500,
      expected_beats_per_xaction => 8
    );

    -- P8: Aperture gating
    write(l, string'("=== P8: Aperture gating ==="));
    writeline(output, l);
    base_addr   <= X"00060000";
    burst_length   <= u32(4);
    addr_range  <= X"00004000";
    addr_mode   <= '0';
    base_latency <= u16(5);
    base_beat_gap<= u16(3);
    enable_local  <= '1';

    aperture <= '0';
    wait_cycles(300);
    aperture <= '1';
    wait_cycles(300);
    aperture <= '0';
    wait_cycles(C_DRAIN);

    for i in 1 to 100000 loop
      exit when pipeline_busy = '0';
      wait_cycles(1);
    end loop;
    assert pipeline_busy = '0'
      report "P8 pipeline did not drain" severity error;
    check_phase(4);

    enable_local  <= '0';
    aresetn         <= '0';
    wait_cycles(10);
    aresetn         <= '1';
    wait_cycles(5);

    -- P9: stat_rst and err_rst
    write(l, string'("=== P9: stat_rst/err_rst ==="));
    writeline(output, l);
    base_addr    <= X"00070000";
    burst_length    <= u32(8);
    addr_range   <= X"00004000";
    addr_mode    <= '0';
    base_latency  <= u16(5);
    base_beat_gap <= u16(3);
    enable_local  <= '1';

    aperture <= '1';
    wait_cycles(200);

    aperture <= '0';
    wait_cycles(C_DRAIN);
    enable_local  <= '0';

    for i in 1 to 2000 loop
      exit when pipeline_busy = '0';
      wait_cycles(1);
    end loop;

    stat_rst <= '1';
    wait_cycles(1);
    stat_rst <= '0';
    wait_cycles(1);
    if unsigned(stat_beats) /= 0 or unsigned(stat_xactions) /= 0 then
      write(l, string'("  FAIL: stat_rst did not clear beats/xact"));
      writeline(output, l);
      all_pass := false;
    else
      write(l, string'("  PASS: stat_rst cleared beats/xact"));
      writeline(output, l);
    end if;

    err_rst <= '1';
    wait_cycles(1);
    err_rst <= '0';
    wait_cycles(1);
    if unsigned(stat_data_errors) /= 0 or
      unsigned(stat_id_errors) /= 0 or
      unsigned(stat_rlast_errors) /= 0 or
      unsigned(stat_resp_errors) /= 0 or
      unsigned(stat_sb_underflow_errors) /= 0 then
      write(l, string'("  FAIL: err_rst did not clear error counters"));
      writeline(output, l);
      all_pass := false;
    else
      write(l, string'("  PASS: err_rst cleared error counters"));
      writeline(output, l);
    end if;

    check_phase;

    -- P11: burst_length=0 must clamp to a single beat.
    run_phase(
      phase_name       => "P11: Zero burst length",
      phase_base_addr  => X"00090000",
      phase_burst_len  => u32(0),
      phase_addr_range => X"00004000",
      phase_addr_mode  => '0',
      phase_latency    => u16(0),
      phase_gap        => u16(0),
      phase_cycles     => 300,
      expected_beats_per_xaction => 1
    );

    -- P12: burst_length above AXI4 maximum must clamp to 256 beats
    -- and report a configuration error.
    run_phase(
      phase_name       => "P12: Burst length clamp",
      phase_base_addr  => X"000A0000",
      phase_burst_len  => u32(257),
      phase_addr_range => X"00100000",
      phase_addr_mode  => '0',
      phase_latency    => u16(0),
      phase_gap        => u16(0),
      phase_cycles     => 5,
      expected_beats_per_xaction => 256,
      expect_cfg_error => true
    );

    aresetn         <= '0';
    wait_cycles(10);
    aresetn         <= '1';
    wait_cycles(5);

    -- P13: Reset while transactions are in-flight
    write(l, string'("=== P13: Reset in-flight ==="));
    writeline(output, l);
    base_addr   <= X"00080000";
    burst_length   <= u32(8);
    addr_range  <= X"00004000";
    addr_mode   <= '0';
    base_latency <= u16(5);
    base_beat_gap<= u16(3);
    enable_local  <= '1';

    aperture <= '1';
    wait_cycles(100);
    aresetn    <= '0';
    wait_cycles(10);
    aresetn    <= '1';
    wait_cycles(100);
    aperture <= '0';
    wait_cycles(C_DRAIN);

    for i in 1 to 100000 loop
      exit when pipeline_busy = '0';
      wait_cycles(1);
    end loop;
    assert pipeline_busy = '0'
      report "P13 pipeline did not drain" severity error;
    check_phase(8);

    -- Simulation complete
    write(l, string'("=== Simulation complete ==="));
    writeline(output, l);
    sim_done <= true;
    wait;
  end process;

end architecture;
