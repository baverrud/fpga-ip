-----------------------------------------------------------------------
--Filename         : axi_monitor_simple_tb.vhd
--Description      : Simple, hand-editable testbench for axi_monitor.
--                   Uses plain signal initialization (defaults in the
--                   declarations) so tests can be added by editing the
--                   sequencer process.  The sequencer sets initial
--                   values, then drives a small traffic window.
--
--                   Architecture:
--                     axi_ar_gen    -- generates AR traffic
--                     axi_mem_model -- responds with R beats
--                     axi_monitor   -- taps AR + R between them
--
--                   The monitor is fully passive; the TB acts as the
--                   R-channel consumer (r_ready tied high).
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity axi_monitor_simple_tb is
end entity;

architecture sim of axi_monitor_simple_tb is

  constant C_CLK_PERIOD : time    := 10 ns;
  constant C_DATA_BYTES : natural := 16;
  constant C_ADDR_WIDTH : natural := 32;
  constant C_ID_WIDTH   : natural := 6;
  constant C_TIME_WIDTH : natural := 48;
  constant C_STAT_WIDTH : natural := 48;

  signal aclk     : std_logic := '0';
  signal aresetn  : std_logic := '0';
  signal sim_done : boolean  := false;

  signal global_time   : unsigned(C_TIME_WIDTH-1 downto 0) := (others => '0');
  signal mon_enable    : std_logic := '1';  -- monitor per-instance enable
  signal aperture      : std_logic := '0';
  signal stat_rst      : std_logic := '0';
  signal err_rst       : std_logic := '0';
  signal data_check_en : std_logic := '1';

  -- Traffic source (ar_gen) config -- initial values
  signal ar_enable      : std_logic := '0';
  signal cfg_id         : std_logic_vector(C_ID_WIDTH-1 downto 0) := (others => '0');
  signal cfg_arlen      : std_logic_vector(log2ceil(256)-1 downto 0) := x"0F";  -- 16 beats
  signal cfg_pace       : std_logic_vector(31 downto 0) := x"00000000";
  signal cfg_pace_init  : std_logic_vector(31 downto 0) := x"00000000";
  signal cfg_base_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0) :=
                            std_logic_vector(to_unsigned(16#1000#, C_ADDR_WIDTH));
  signal cfg_addr_range : std_logic_vector(C_ADDR_WIDTH-1 downto 0) :=
                            std_logic_vector(to_unsigned(16#10000#, C_ADDR_WIDTH));
  signal cfg_addr_mode  : std_logic := '0';

  -- AR channel (gen drives, mem accepts, monitor taps)
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;
  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);
  signal ar_size  : std_logic_vector(2 downto 0);
  signal ar_burst : std_logic_vector(1 downto 0);

  -- R channel (mem drives, TB consumes, monitor taps)
  signal r_valid : std_logic;
  signal r_ready : std_logic := '1';  -- TB acts as R consumer
  signal r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data  : std_logic_vector(8*C_DATA_BYTES-1 downto 0);
  signal r_resp  : std_logic_vector(1 downto 0);
  signal r_last  : std_logic;

  -- Waveform view: four 32-bit words, word 0 is r_data(31 downto 0).
  type t_r_data_words is array (0 to 3) of std_logic_vector(31 downto 0);
  signal r_data_words : t_r_data_words;
  signal r_data_word0_prev : unsigned(31 downto 0) := (others => '0');
  signal r_data_word0_diff : signed(32 downto 0)  := (others => '0');
  signal r_data_word_count : unsigned(15 downto 0)  := (others => '0');

  -- Memory model control
  signal ar_base_enable   : std_logic := '0';
  signal ar_jitter_enable : std_logic := '0';
  signal r_base_enable    : std_logic := '0';
  signal r_jitter_enable  : std_logic := '0';
  signal base_latency     : std_logic_vector(15 downto 0) := x"0000";
  signal base_beat_gap    : std_logic_vector(15 downto 0) := x"0000";
  -- Monitor statistics
  signal stat_ar_seen             : std_logic_vector(31 downto 0);
  signal stat_ar_stall            : std_logic_vector(31 downto 0);
  signal stat_sb_backpressure     : std_logic_vector(31 downto 0);

  signal stat_xactions            : std_logic_vector(31 downto 0);
  signal stat_beats               : std_logic_vector(31 downto 0);
  signal stat_latency_sum         : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_latency_min         : std_logic_vector(31 downto 0);
  signal stat_latency_max         : std_logic_vector(31 downto 0);
  signal stat_first_latency_sum   : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_first_latency_min   : std_logic_vector(31 downto 0);
  signal stat_first_latency_max   : std_logic_vector(31 downto 0);
  signal stat_interbeat_gap_sum   : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_interbeat_gap_min   : std_logic_vector(31 downto 0);
  signal stat_interbeat_gap_max   : std_logic_vector(31 downto 0);
  signal stat_burst_len_sum       : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_burst_len_min       : std_logic_vector(31 downto 0);
  signal stat_burst_len_max       : std_logic_vector(31 downto 0);
  signal stat_elapsed_cycles      : std_logic_vector(31 downto 0);
  signal stat_r_stall             : std_logic_vector(31 downto 0);
  signal pipeline_busy            : std_logic;
  signal stat_max_outstanding     : std_logic_vector(31 downto 0);
  signal stat_data_errors         : std_logic_vector(31 downto 0);
  signal stat_id_errors           : std_logic_vector(31 downto 0);
  signal stat_rlast_errors        : std_logic_vector(31 downto 0);
  signal stat_resp_errors         : std_logic_vector(31 downto 0);
  signal stat_sb_underflow_errors : std_logic_vector(31 downto 0);

  -- Generator stats (cross-check ar_seen vs ar_issued)
  signal gen_stat_ar_stall    : std_logic_vector(31 downto 0);
  signal gen_stat_ar_issued   : std_logic_vector(31 downto 0);
  signal gen_stat_cfg_errors  : std_logic_vector(31 downto 0);

  -- Global time counter
  signal global_time_cnt : unsigned(C_TIME_WIDTH-1 downto 0) := (others => '0');

  procedure wait_cycles(n : natural) is
  begin
    for i in 1 to n loop
      wait until rising_edge(aclk);
    end loop;
  end procedure;

  -- Wait until all ARs accepted by the monitor have completed (xactions
  -- catches up to ar_seen), or max_cycles elapse.
  procedure wait_drained(max_cycles : natural) is
    variable n : natural := 0;
  begin
    while unsigned(stat_xactions) < unsigned(stat_ar_seen) and n < max_cycles loop
      wait until rising_edge(aclk);
      n := n + 1;
    end loop;
  end procedure;

begin

  aclk <= not aclk after C_CLK_PERIOD/2 when not sim_done else '0';

  r_data_words(0) <= r_data(31 downto 0);
  r_data_words(1) <= r_data(63 downto 32);
  r_data_words(2) <= r_data(95 downto 64);
  r_data_words(3) <= r_data(127 downto 96);

  -- Sample the previous word-0 value only on accepted R-channel beats.
  p_r_data_word0_prev : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        r_data_word0_prev <= (others => '0');
        r_data_word_count <= (others => '0');
      elsif r_valid = '1' and r_ready = '1' then
        r_data_word0_prev <= unsigned(r_data_words(0));
        if r_last = '1' then
          r_data_word_count <= (others => '0');
        else
          r_data_word_count <= r_data_word_count + 1;
        end if;
      end if;
    end if;
  end process;

  -- Combinatorial difference between the live word and the last sampled word.
  r_data_word0_diff <= signed(resize(unsigned(r_data_words(0)), 33)) -
                       signed(resize(r_data_word0_prev, 33));

  -- Global time counter (free-running)
  p_gt : process
  begin
    wait until rising_edge(aclk);
    if aresetn = '0' then
      global_time_cnt <= (others => '0');
    else
      global_time_cnt <= global_time_cnt + 1;
    end if;
  end process;
  global_time <= global_time_cnt;

  ---------------------------------------------------------------------
  -- Traffic source:  axi_ar_gen
  ---------------------------------------------------------------------
  u_gen : entity work.axi_ar_gen
    generic map (
      GC_DATA_BYTES => C_DATA_BYTES,
      GC_ADDR_WIDTH => C_ADDR_WIDTH,
      GC_ID_WIDTH   => C_ID_WIDTH,
      GC_MAX_BURST  => 256
    )
    port map (
      aclk            => aclk,
      aresetn         => aresetn,
      enable          => ar_enable,
      aperture        => aperture,
      stat_rst        => stat_rst,
      cfg_id          => cfg_id,
      cfg_arlen       => cfg_arlen,
      cfg_pace        => cfg_pace,
      cfg_pace_init   => cfg_pace_init,
      cfg_base_addr   => cfg_base_addr,
      cfg_addr_range  => cfg_addr_range,
      cfg_addr_mode   => cfg_addr_mode,
      ar_valid        => ar_valid,
      ar_ready        => ar_ready,
      ar_id           => ar_id,
      ar_addr         => ar_addr,
      ar_len          => ar_len,
      ar_size         => ar_size,
      ar_burst        => ar_burst,
      stat_ar_stall   => gen_stat_ar_stall,
      stat_ar_issued  => gen_stat_ar_issued,
      stat_cfg_errors => gen_stat_cfg_errors
    );

  ---------------------------------------------------------------------
  -- Responding slave:  axi_mem_model
  ---------------------------------------------------------------------
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
      ar_id            => ar_id,
      ar_addr          => ar_addr,
      ar_len           => ar_len,
      ar_valid         => ar_valid,
      ar_ready         => ar_ready,
      r_id             => r_id,
      r_data           => r_data,
      r_resp           => r_resp,
      r_last           => r_last,
      r_valid          => r_valid,
      r_ready          => r_ready
    );

  ---------------------------------------------------------------------
  -- DUT:  axi_monitor -- passive tap between generator and memory model
  ---------------------------------------------------------------------
  u_monitor : entity work.axi_monitor
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_TIME_WIDTH    => C_TIME_WIDTH,
      GC_STAT_WIDTH    => C_STAT_WIDTH,
      GC_SB_FIFO_DEPTH => 4096
    )
    port map (
      aclk                    => aclk,
      aresetn                 => aresetn,
      global_time             => global_time,
      enable                  => mon_enable,
      stat_rst                => stat_rst,
      err_rst                 => err_rst,
      data_check_en           => data_check_en,
      ar_valid                => ar_valid,
      ar_ready                => ar_ready,
      ar_id                   => ar_id,
      ar_addr                 => ar_addr,
      ar_len                  => ar_len,
      r_valid                 => r_valid,
      r_ready                 => r_ready,
      r_id                    => r_id,
      r_data                  => r_data,
      r_resp                  => r_resp,
      r_last                  => r_last,
      stat_ar_seen            => stat_ar_seen,
      stat_ar_stall           => stat_ar_stall,
      stat_sb_backpressure    => stat_sb_backpressure,
      stat_xactions           => stat_xactions,
      stat_beats              => stat_beats,
      stat_latency_sum        => stat_latency_sum,
      stat_latency_min        => stat_latency_min,
      stat_latency_max        => stat_latency_max,
      stat_first_latency_sum  => stat_first_latency_sum,
      stat_first_latency_min  => stat_first_latency_min,
      stat_first_latency_max  => stat_first_latency_max,
      stat_interbeat_gap_sum  => stat_interbeat_gap_sum,
      stat_interbeat_gap_min  => stat_interbeat_gap_min,
      stat_interbeat_gap_max  => stat_interbeat_gap_max,
      stat_burst_len_sum      => stat_burst_len_sum,
      stat_burst_len_min      => stat_burst_len_min,
      stat_burst_len_max      => stat_burst_len_max,
      stat_elapsed_cycles     => stat_elapsed_cycles,
      stat_r_stall            => stat_r_stall,
      pipeline_busy           => pipeline_busy,
      stat_max_outstanding    => stat_max_outstanding,
      stat_data_errors        => stat_data_errors,
      stat_id_errors          => stat_id_errors,
      stat_rlast_errors       => stat_rlast_errors,
      stat_resp_errors        => stat_resp_errors,
      stat_sb_underflow_errors => stat_sb_underflow_errors
    );

  ---------------------------------------------------------------------
  -- Sequencer -- edit here to add tests.  Initial values are set first,
  -- then a reset and a simple traffic window with a minimal check.
  ---------------------------------------------------------------------
  p_seq : process
    variable l : line;
  begin
    -- Initial values in the sequencer
    aresetn          <= '0';
    cfg_id           <= "001010";
    cfg_arlen        <= x"01";   
    cfg_pace         <= x"00000000"; 
    cfg_pace_init    <= x"00000000";
    cfg_base_addr    <= x"00040000";
    cfg_addr_range   <= x"00040000";
    cfg_addr_mode    <= '0';
    data_check_en    <= '1';
    stat_rst         <= '0';
    err_rst          <= '0';
    mon_enable       <= '1';
    ar_enable        <= '1';
    aperture         <= '0';

    -- Reset
    wait_cycles(1);
    aresetn <= '1';
    wait_cycles(1);

    aperture <= '1';
    wait_cycles(3);
    aperture <= '0';

    wait_cycles(8);
    stat_rst <= '1';
    wait_cycles(1);
    stat_rst <= '0';
    wait_cycles(2);
    sim_done <= true;
    std.env.stop;
    wait;
  end process p_seq;

  -- Watchdog
  p_watchdog : process
  begin
    wait for 20 ms;
    assert sim_done report "Watchdog timeout" severity failure;
    wait;
  end process;

end architecture;
