-----------------------------------------------------------------------
--Filename         : axi_read_tester_tb.vhd
--Description      : Corner-case testbench for axi_read_tester.
--                   Instantiates axi_mem_model directly on the
--                   AR/R buses.  Runs 10 phases covering single-beat,
--                   max-burst, 4KB boundary, random addressing,
--                   zero/high latency, aperture gating, stat/err
--                   reset, and in-flight reset.
--Author           : Rune Bæverrud
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

  -- Clock and reset
  signal clk           : std_logic := '0';
  signal rst_n         : std_logic := '0';
  signal sim_done      : boolean   := false;
  signal global_time   : unsigned(C_TIME_WIDTH-1 downto 0) := (others => '0');

  -- Tester control
  signal enable_global : std_logic := '0';
  signal enable_local  : std_logic := '0';
  signal aperture      : std_logic := '0';
  signal stat_rst      : std_logic := '0';
  signal err_rst       : std_logic := '0';

  -- AR generation configuration
  signal arid          : std_logic_vector(C_ID_WIDTH-1 downto 0) := X"1";
  signal burst_len     : std_logic_vector(31 downto 0) := X"00000008";
  signal pace          : std_logic_vector(31 downto 0) := (others => '0');
  signal pace_init     : std_logic_vector(31 downto 0) := (others => '0');
  signal base_addr     : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := X"00001000";
  signal addr_range    : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := X"00004000";
  signal addr_mode     : std_logic := '0';

  -- Memory model configuration
  signal mem_enable    : std_logic := '1';
  signal mem_latency   : std_logic_vector(15 downto 0) := (others => '0');
  signal mem_beat_gap  : std_logic_vector(15 downto 0) := (others => '0');

  -- AXI4 AR bus (tester → memory model)
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;
  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);

  -- AXI4 R bus (memory model → tester)
  signal r_valid : std_logic;
  signal r_ready : std_logic;
  signal r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data  : std_logic_vector(8*C_DATA_BYTES-1 downto 0);
  signal r_resp  : std_logic_vector(1 downto 0);
  signal r_last  : std_logic;

  -- Monitored statistics
  signal stat_xact     : std_logic_vector(31 downto 0);
  signal stat_beats    : std_logic_vector(31 downto 0);
  signal stat_data_err : std_logic_vector(31 downto 0);
  signal stat_id_err   : std_logic_vector(31 downto 0);
  signal stat_rlast_err: std_logic_vector(31 downto 0);
  signal stat_resp_err : std_logic_vector(31 downto 0);
  signal stat_sb_uf_err: std_logic_vector(31 downto 0);
  signal stat_busy     : std_logic;

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
      wait until rising_edge(clk);
    end loop;
  end procedure;

begin

  -- Clock generator
  clk <= not clk after C_CLK_PERIOD / 2 when not sim_done else '0';

  -- Global time counter
  p_global_time : process(clk)
  begin
    if rising_edge(clk) and rst_n = '1' then
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
      GC_STAT_WIDTH    => C_TIME_WIDTH,
      GC_SB_FIFO_DEPTH => 256,
      GC_MAX_BURST     => 256
    )
    port map (
      aclk                      => clk,
      aresetn                   => rst_n,
      global_time               => std_logic_vector(global_time),

      enable_global             => enable_global,
      enable_local              => enable_local,
      aperture                  => aperture,
      stat_rst                  => stat_rst,
      err_rst                   => err_rst,

      arid                      => arid,
      burst_length              => burst_len,
      pace                      => pace,
      pace_init                 => pace_init,
      base_addr                 => base_addr,
      addr_range                => addr_range,
      addr_mode                 => addr_mode,

      -- AR bus → memory model
      ar_valid                  => ar_valid,
      ar_ready                  => ar_ready,
      ar_id                     => ar_id,
      ar_addr                   => ar_addr,
      ar_len                    => ar_len,

      -- R bus ← memory model
      r_valid                   => r_valid,
      r_ready                   => r_ready,
      r_id                      => r_id,
      r_data                    => r_data,
      r_resp                    => r_resp,
      r_last                    => r_last,

      -- Statistics
      stat_xactions             => stat_xact,
      stat_beats                => stat_beats,
      stat_latency_sum          => open,
      stat_latency_min          => open,
      stat_latency_max          => open,
      stat_first_latency_sum    => open,
      stat_first_latency_min    => open,
      stat_first_latency_max    => open,
      stat_interbeat_gap_sum    => open,
      stat_ar_backpressure      => open,
      stat_sb_backpressure      => open,
      stat_ar_issued            => open,
      stat_cfg_errors           => open,
      stat_elapsed_cycles       => open,
      stat_max_outstanding      => open,
      stat_pipeline_busy        => stat_busy,
      stat_data_errors          => stat_data_err,
      stat_id_errors            => stat_id_err,
      stat_rlast_errors         => stat_rlast_err,
      stat_resp_errors          => stat_resp_err,
      stat_sb_underflow_errors  => stat_sb_uf_err
    );

  --------------------------------------------------------------------
  -- Memory model — responds to AR beats with address-derived data.
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
      aclk            => clk,
      aresetn         => rst_n,
      enable          => mem_enable,
      base_latency    => mem_latency,
      base_beat_gap   => mem_beat_gap,
      ar_valid        => ar_valid,
      ar_ready        => ar_ready,
      ar_id           => ar_id,
      ar_addr         => ar_addr,
      ar_len          => ar_len,
      r_valid         => r_valid,
      r_ready         => r_ready,
      r_id            => r_id,
      r_data          => r_data,
      r_resp          => r_resp,
      r_last          => r_last
    );

  --------------------------------------------------------------------
  -- Stimulus
  --------------------------------------------------------------------
  p_stimulus : process
    variable l         : line;
    variable all_pass  : boolean;

    -- Print stats and check for errors
    procedure check_phase is
      variable errs : unsigned(31 downto 0);
    begin
      all_pass := true;

      write(l, string'("  beats="));
      write(l, to_integer(unsigned(stat_beats)));
      write(l, string'(" xact="));
      write(l, to_integer(unsigned(stat_xact)));
      write(l, string'(" data="));
      write(l, to_integer(unsigned(stat_data_err)));
      write(l, string'(" id="));
      write(l, to_integer(unsigned(stat_id_err)));
      write(l, string'(" rlast="));
      write(l, to_integer(unsigned(stat_rlast_err)));
      write(l, string'(" sb_uf="));
      write(l, to_integer(unsigned(stat_sb_uf_err)));
      writeline(output, l);

      errs := unsigned(stat_data_err)
            + unsigned(stat_id_err)
            + unsigned(stat_rlast_err)
            + unsigned(stat_resp_err)
            + unsigned(stat_sb_uf_err);
      if errs > 0 then
        write(l, string'("  FAIL"));
        writeline(output, l);
        all_pass := false;
      else
        write(l, string'("  PASS"));
        writeline(output, l);
      end if;
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
      phase_cycles     : natural
    ) is
    begin
      base_addr   <= phase_base_addr;
      burst_len   <= phase_burst_len;
      addr_range  <= phase_addr_range;
      addr_mode   <= phase_addr_mode;
      mem_latency <= phase_latency;
      mem_beat_gap<= phase_gap;

      enable_global <= '1';
      enable_local  <= '1';

      write(l, string'("=== "));
      write(l, phase_name);
      write(l, string'(" ==="));
      writeline(output, l);

      aperture <= '1';
      wait_cycles(phase_cycles);
      aperture <= '0';
      wait_cycles(C_DRAIN);

      check_phase;

      enable_global <= '0';
      enable_local  <= '0';
      rst_n         <= '0';
      wait_cycles(10);
      rst_n         <= '1';
      wait_cycles(5);
    end procedure;

  begin
    -- Power-on reset
    rst_n <= '0';
    wait_cycles(10);
    rst_n <= '1';
    wait_cycles(5);

    -- P1: Standard 16-beat bursts
    run_phase(
      phase_name       => "P1: 16-beat",
      phase_base_addr  => X"00001000",
      phase_burst_len  => u32(16),
      phase_addr_range => X"00004000",
      phase_addr_mode  => '0',
      phase_latency    => u16(5),
      phase_gap        => u16(3),
      phase_cycles     => 800
    );

    -- P2: Single-beat bursts (blen=0 → 1 beat)
    run_phase(
      phase_name       => "P2: Single-beat",
      phase_base_addr  => X"00010000",
      phase_burst_len  => u32(1),
      phase_addr_range => X"00001000",
      phase_addr_mode  => '0',
      phase_latency    => u16(5),
      phase_gap        => u16(3),
      phase_cycles     => 500
    );

    -- P3: Maximum-length 256-beat bursts
    run_phase(
      phase_name       => "P3: Max burst 256",
      phase_base_addr  => X"00020000",
      phase_burst_len  => u32(256),
      phase_addr_range => X"00100000",
      phase_addr_mode  => '0',
      phase_latency    => u16(5),
      phase_gap        => u16(3),
      phase_cycles     => 2000
    );

    -- P4: 4 KB boundary crossing (base 0xFE0 + 2 beats × 64 B = over)
    run_phase(
      phase_name       => "P4: 4KB boundary",
      phase_base_addr  => X"00000FE0",
      phase_burst_len  => u32(2),
      phase_addr_range => X"00001000",
      phase_addr_mode  => '0',
      phase_latency    => u16(5),
      phase_gap        => u16(3),
      phase_cycles     => 500
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
      phase_cycles     => 800
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
      phase_cycles     => 500
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
      phase_cycles     => 3000
    );

    -- P8: Aperture gating
    write(l, string'("=== P8: Aperture gating ==="));
    writeline(output, l);
    base_addr   <= X"00060000";
    burst_len   <= u32(4);
    addr_range  <= X"00004000";
    addr_mode   <= '0';
    mem_latency <= u16(5);
    mem_beat_gap<= u16(3);
    enable_global <= '1';
    enable_local  <= '1';

    aperture <= '0';
    wait_cycles(300);
    aperture <= '1';
    wait_cycles(300);
    aperture <= '0';
    wait_cycles(C_DRAIN);

    check_phase;

    enable_global <= '0';
    enable_local  <= '0';
    rst_n         <= '0';
    wait_cycles(10);
    rst_n         <= '1';
    wait_cycles(5);

    -- P9: stat_rst and err_rst
    write(l, string'("=== P9: stat_rst/err_rst ==="));
    writeline(output, l);
    base_addr    <= X"00070000";
    burst_len    <= u32(8);
    addr_range   <= X"00004000";
    addr_mode    <= '0';
    mem_latency  <= u16(5);
    mem_beat_gap <= u16(3);
    enable_global <= '1';
    enable_local  <= '1';

    aperture <= '1';
    wait_cycles(200);

    aperture <= '0';
    wait_cycles(C_DRAIN);
    enable_global <= '0';
    enable_local  <= '0';

    for i in 1 to 2000 loop
      exit when stat_busy = '0';
      wait_cycles(1);
    end loop;

    stat_rst <= '1';
    wait_cycles(1);
    stat_rst <= '0';
    wait_cycles(1);
    if unsigned(stat_beats) /= 0 or unsigned(stat_xact) /= 0 then
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
    if unsigned(stat_data_err) /= 0 or
       unsigned(stat_id_err) /= 0 or
       unsigned(stat_rlast_err) /= 0 or
       unsigned(stat_resp_err) /= 0 or
       unsigned(stat_sb_uf_err) /= 0 then
      write(l, string'("  FAIL: err_rst did not clear error counters"));
      writeline(output, l);
      all_pass := false;
    else
      write(l, string'("  PASS: err_rst cleared error counters"));
      writeline(output, l);
    end if;

    check_phase;

    rst_n         <= '0';
    wait_cycles(10);
    rst_n         <= '1';
    wait_cycles(5);

    -- P10: Reset while transactions are in-flight
    write(l, string'("=== P10: Reset in-flight ==="));
    writeline(output, l);
    base_addr   <= X"00080000";
    burst_len   <= u32(8);
    addr_range  <= X"00004000";
    addr_mode   <= '0';
    mem_latency <= u16(5);
    mem_beat_gap<= u16(3);
    enable_global <= '1';
    enable_local  <= '1';

    aperture <= '1';
    wait_cycles(100);
    rst_n    <= '0';
    wait_cycles(10);
    rst_n    <= '1';
    wait_cycles(100);
    aperture <= '0';
    wait_cycles(C_DRAIN);

    check_phase;

    -- Simulation complete
    write(l, string'("=== Simulation complete ==="));
    writeline(output, l);
    sim_done <= true;
    wait;
  end process;

end architecture;
