-----------------------------------------------------------------------
--Filename         : axi_read_tester_simple_tb.vhd
--Description      : Minimal smoke-test bench for axi_read_tester.
--                   Connects tester to axi_mem_model.  Stimulus process
--                   is a skeleton — populate your own test sequence.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity axi_read_tester_simple_tb is
end entity;

architecture sim of axi_read_tester_simple_tb is

  -- =================================================================
  -- Constants
  -- =================================================================
  constant C_CLK_PERIOD : time    := 10 ns;
  constant C_DATA_BYTES : natural := 64;
  constant C_ADDR_WIDTH : natural := 32;
  constant C_ID_WIDTH   : natural := 4;
  constant C_TIME_WIDTH : natural := 48;
  constant C_STAT_WIDTH : natural := 48;

  -- =================================================================
  -- Clock & control
  -- =================================================================
  signal aclk        : std_logic := '1';
  signal aresetn     : std_logic := '0';
  signal sim_done    : boolean   := false;
  signal global_time : std_logic_vector(C_TIME_WIDTH-1 downto 0) := (others => '0');

  -- =================================================================
  -- Tester control
  -- =================================================================
  signal enable_local : std_logic := '0';
  signal aperture     : std_logic := '0';
  signal stat_rst     : std_logic := '0';
  signal err_rst      : std_logic := '0';

  -- =================================================================
  -- AR generation configuration
  -- =================================================================
  signal arid         : std_logic_vector(C_ID_WIDTH-1 downto 0)     := X"1";
  signal burst_length : std_logic_vector(31 downto 0)               := X"00000008";
  signal pace         : std_logic_vector(31 downto 0)               := (others => '0');
  signal pace_init    : std_logic_vector(31 downto 0)               := (others => '0');
  signal base_addr    : std_logic_vector(C_ADDR_WIDTH-1 downto 0)   := X"00001000";
  signal addr_range   : std_logic_vector(C_ADDR_WIDTH-1 downto 0)   := X"00004000";
  signal addr_mode    : std_logic                                   := '0';

  -- =================================================================
  -- Memory model configuration
  -- =================================================================
  signal ar_base_enable   : std_logic := '1';
  signal ar_jitter_enable : std_logic := '1';
  signal r_base_enable    : std_logic := '1';
  signal r_jitter_enable  : std_logic := '1';
  signal base_latency     : std_logic_vector(15 downto 0) := (others => '0');
  signal base_beat_gap    : std_logic_vector(15 downto 0) := (others => '0');

  -- =================================================================
  -- AXI4 AR bus (tester → memory model)
  -- =================================================================
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;
  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);

  -- =================================================================
  -- AXI4 R bus (memory model → tester)
  -- =================================================================
  signal r_valid : std_logic;
  signal r_ready : std_logic;
  signal r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data  : std_logic_vector(8*C_DATA_BYTES-1 downto 0);
  signal r_resp  : std_logic_vector(1 downto 0);
  signal r_last  : std_logic;

  -- =================================================================
  -- Statistics
  -- =================================================================
  signal stat_xactions           : std_logic_vector(31 downto 0);
  signal stat_beats              : std_logic_vector(31 downto 0);
  signal stat_data_errors        : std_logic_vector(31 downto 0);
  signal stat_id_errors          : std_logic_vector(31 downto 0);
  signal stat_rlast_errors       : std_logic_vector(31 downto 0);
  signal stat_resp_errors        : std_logic_vector(31 downto 0);
  signal stat_sb_underflow_errors: std_logic_vector(31 downto 0);
  signal pipeline_busy           : std_logic;
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

  -- =================================================================
  -- R-data word slices — convenience for waveform viewing
  -- =================================================================
  type t_slv32_arr is array (0 to 15) of std_logic_vector(31 downto 0);
  signal r_words : t_slv32_arr;

  -- =================================================================
  -- Helper procedures
  -- =================================================================
  procedure wait_cycles(signal clk : in std_logic; n : in integer) is
  begin
    for i in 1 to n loop
      wait until rising_edge(clk);
    end loop;
  end procedure;

  procedure pulse(
    signal clk : in  std_logic;
    signal sig : out std_logic;
    n          : in  integer
  ) is
  begin
    sig <= '1';
    wait until rising_edge(clk);
    sig <= '0';
    for i in 1 to n loop
      wait until rising_edge(clk);
    end loop;
  end procedure;

begin

  -- =================================================================
  -- Clock generator
  -- =================================================================
  aclk <= not aclk after C_CLK_PERIOD / 2 when not sim_done else '0';

  -- =================================================================
  -- Global time counter (free-running, enabled after reset)
  -- =================================================================
  p_global_time : process(aclk)
  begin
    if rising_edge(aclk) and aresetn = '1' then
      global_time <= std_logic_vector(unsigned(global_time) + 1);
    end if;
  end process;

  -- =================================================================
  -- Slice r_data into 16 x 32-bit words (for 64-byte data bus)
  -- =================================================================
  gen_r_words : for i in 0 to 15 generate
    r_words(i) <= r_data(32*i+31 downto 32*i);
  end generate;

  -- =================================================================
  -- DUT: axi_read_tester (AR generator + scoreboard FIFO + R monitor)
  -- =================================================================
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
      pipeline_busy             => pipeline_busy,
      stat_data_errors          => stat_data_errors,
      stat_id_errors            => stat_id_errors,
      stat_rlast_errors         => stat_rlast_errors,
      stat_resp_errors          => stat_resp_errors,
      stat_sb_underflow_errors  => stat_sb_underflow_errors,
      stat_max_outstanding      => stat_max_outstanding
    );

  -- =================================================================
  -- Memory model — responds to AR beats with address-derived data.
  -- =================================================================
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

  -- =================================================================
  -- Stimulus process — skeleton, populate your own test sequence.
  -- =================================================================
  process
  begin
    -- Drive all control signals to safe defaults
    aresetn          <= '0';
    enable_local     <= '0';
    aperture         <= '0';
    stat_rst         <= '0';
    err_rst          <= '0';
    arid             <= X"1";
    burst_length     <= X"00000008";
    pace             <= (others => '0');
    pace_init        <= (others => '0');
    base_addr        <= X"00001000";
    addr_range       <= X"00004000";
    addr_mode        <= '0';
    ar_base_enable   <= '1';
    ar_jitter_enable <= '1';
    r_base_enable    <= '1';
    r_jitter_enable  <= '1';
    base_latency     <= (others => '0');
    base_beat_gap    <= (others => '0');

    -- Release reset
    wait until rising_edge(aclk);
    aresetn          <= '1';
    wait_cycles(aclk, 5);

    -- ===============================================================
    --  Place your test sequence here.
    -- ===============================================================

    -- Example: enable and let it run for 200 cycles
    -- enable_local <= '1';
    -- aperture     <= '1';
    -- wait_cycles(aclk, 200);
    -- aperture     <= '0';

    wait_cycles(aclk, 100);

    sim_done <= true;
    wait;
  end process;

end architecture;
