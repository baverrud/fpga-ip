-----------------------------------------------------------------------
--Filename         : axi_monitor_simple_tb.vhd
--Description      : Simple, hand-editable testbench for axi_monitor.
--                   A hand-driven req/rsp sequencer exercises the
--                   monitor without the bridge.  The sequencer issues
--                   one request and returns its beats, then checks the
--                   core stats.  Edit the sequencer to add scenarios.
--
--                   Architecture:
--                     sequencer -- drives req / consumes rsp
--                     axi_monitor  -- taps req/rsp between them
--
--                   The monitor is fully passive; the TB acts as the
--                   rsp-channel consumer (rsp_ready tied high).
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_monitor_simple_tb is
end entity;

architecture sim of axi_monitor_simple_tb is
  constant C_CLK_PERIOD : time := 10 ns;
  constant C_DATA_BYTES : positive := 64;
  constant C_ADDR_WIDTH : positive := 32;
  constant C_TIME_WIDTH : positive := 48;
  constant C_STAT_WIDTH : positive := 48;

  signal aclk     : std_logic := '0';
  signal aresetn  : std_logic := '0';
  signal sim_done : boolean  := false;

  signal global_time   : unsigned(C_TIME_WIDTH-1 downto 0) := (others => '0');
  signal mon_enable    : std_logic := '1';
  signal data_check_en : std_logic := '1';
  signal pipeline_busy : std_logic;

  -- req / rsp channels (sequencer drives req and consumes rsp).
  -- req_ready is an input to the monitor (it taps the bus ready); the
  -- hand-driven slave here always accepts.
  signal req_valid : std_logic := '0';
  signal req_ready : std_logic := '1';
  signal req_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal req_len   : std_logic_vector(7 downto 0) := (others => '0');
  signal rsp_valid : std_logic := '0';
  signal rsp_ready : std_logic := '1';
  signal rsp_data  : std_logic_vector(8*C_DATA_BYTES-1 downto 0) := (others => '0');
  signal rsp_resp  : std_logic_vector(1 downto 0) := (others => '0');
  signal rsp_last  : std_logic := '0';

  -- Monitor statistics
  signal stat_xactions     : std_logic_vector(31 downto 0);
  signal stat_beats        : std_logic_vector(31 downto 0);
  signal stat_burst_len_min : std_logic_vector(31 downto 0);
  signal stat_burst_len_max : std_logic_vector(31 downto 0);
  signal stat_data_errors  : std_logic_vector(31 downto 0);
  signal stat_rlast_errors : std_logic_vector(31 downto 0);
  signal stat_resp_errors  : std_logic_vector(31 downto 0);
  signal stat_sb_uf_errors : std_logic_vector(31 downto 0);
begin

  p_clk : process
  begin
    aclk <= '0';
    while not sim_done loop
      wait for C_CLK_PERIOD / 2;
      aclk <= not aclk;
    end loop;
    aclk <= '0';
    wait;
  end process;

  p_time : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        global_time <= (others => '0');
      else
        global_time <= global_time + 1;
      end if;
    end if;
  end process;

  u_monitor : entity work.axi_monitor
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_TIME_WIDTH    => C_TIME_WIDTH,
      GC_STAT_WIDTH    => C_STAT_WIDTH,
      GC_SB_FIFO_DEPTH => 16
    )
    port map (
      aclk                    => aclk,
      aresetn                 => aresetn,
      global_time             => global_time,
      enable                  => mon_enable,
      stat_rst                => '0',
      err_rst                 => '0',
      data_check_en           => data_check_en,
      pipeline_busy           => pipeline_busy,
      req_valid               => req_valid,
      req_ready               => req_ready,
      req_addr                => req_addr,
      req_len                 => req_len,
      rsp_valid               => rsp_valid,
      rsp_ready               => rsp_ready,
      rsp_data                => rsp_data,
      rsp_resp                => rsp_resp,
      rsp_last                => rsp_last,
      stat_req_seen           => open,
      stat_req_stall          => open,
      stat_sb_backpressure    => open,
      stat_xactions           => stat_xactions,
      stat_beats              => stat_beats,
      stat_latency_sum        => open,
      stat_latency_min        => open,
      stat_latency_max        => open,
      stat_first_latency_sum  => open,
      stat_first_latency_min  => open,
      stat_first_latency_max  => open,
      stat_interbeat_gap_sum  => open,
      stat_interbeat_gap_min  => open,
      stat_interbeat_gap_max  => open,
      stat_burst_len_sum      => open,
      stat_burst_len_min      => stat_burst_len_min,
      stat_burst_len_max      => stat_burst_len_max,
      stat_elapsed_cycles     => open,
      stat_rsp_stall          => open,
      stat_max_outstanding    => open,
      stat_data_errors        => stat_data_errors,
      stat_rlast_errors       => stat_rlast_errors,
      stat_resp_errors        => stat_resp_errors,
      stat_sb_underflow_errors => stat_sb_uf_errors
    );

  p_seq : process
    variable wait_count : natural;
    variable v_data     : std_logic_vector(8*C_DATA_BYTES-1 downto 0);
    variable v_word     : natural;

    -- Issue one client read request (req channel): drive addr/len/valid and
    -- hold until a rising-edge ready handshake.
    procedure req_w(
      signal   clk      : in  std_logic;
      signal   addr     : out std_logic_vector;
      signal   len      : out std_logic_vector;
      signal   valid    : out std_logic;
      signal   ready    : in  std_logic;
      constant req_addr : in  std_logic_vector;
      constant req_len  : in  std_logic_vector
    ) is
    begin
      addr  <= req_addr;
      len   <= req_len;
      valid <= '1';
      loop
        wait until rising_edge(clk);
        exit when ready = '1';
      end loop;
      valid <= '0';
    end procedure;

    -- Drive one client response beat (rsp channel, responder role): hold
    -- valid and the payload until a rising-edge ready handshake.
    procedure rsp_w(
      signal   clk      : in  std_logic;
      signal   valid    : out std_logic;
      signal   ready    : in  std_logic;
      signal   data     : out std_logic_vector;
      signal   resp     : out std_logic_vector;
      signal   last     : out std_logic;
      constant rsp_data : in  std_logic_vector;
      constant rsp_resp : in  std_logic_vector;
      constant rsp_last : in  std_logic
    ) is
    begin
      valid <= '1';
      data  <= rsp_data;
      resp  <= rsp_resp;
      last  <= rsp_last;
      loop
        wait until rising_edge(clk);
        exit when ready = '1';
      end loop;
      valid <= '0';
    end procedure;
  begin
    wait for 100 ns;
    aresetn <= '1';
    wait until rising_edge(aclk);

    -- Request: 2 beats (len=1) at 0x1000.
    req_w(aclk, req_addr, req_len, req_valid, req_ready,
          x"00001000", x"01");

    -- Return beat 0 (0x1000-based data, OKAY, not last).
    v_data := (others => '0');
    for v_word in 0 to C_DATA_BYTES/4-1 loop
      v_data(32*v_word+31 downto 32*v_word) :=
        std_logic_vector(to_unsigned(16#1000# + v_word*4, 32));
    end loop;
    rsp_w(aclk, rsp_valid, rsp_ready, rsp_data, rsp_resp, rsp_last,
          v_data, "00", '0');

    -- Return beat 1 (0x1040-based data, OKAY, last).
    v_data := (others => '0');
    for v_word in 0 to C_DATA_BYTES/4-1 loop
      v_data(32*v_word+31 downto 32*v_word) :=
        std_logic_vector(to_unsigned(16#1040# + v_word*4, 32));
    end loop;
    rsp_w(aclk, rsp_valid, rsp_ready, rsp_data, rsp_resp, rsp_last,
          v_data, "00", '1');

    -- Drain and check.
    wait_count := 0;
    loop
      wait until rising_edge(aclk);
      exit when pipeline_busy = '0';
      wait_count := wait_count + 1;
      assert wait_count < 100 report "drain timeout" severity failure;
    end loop;

    assert stat_xactions = x"00000001"
      report "xactions /= 1" severity failure;
    assert stat_beats = x"00000002"
      report "beats /= 2" severity failure;
    assert stat_burst_len_min = x"00000002" and stat_burst_len_max = x"00000002"
      report "burst length stats wrong" severity failure;
    assert stat_data_errors = x"00000000" and stat_rlast_errors = x"00000000"
       and stat_resp_errors = x"00000000" and stat_sb_uf_errors = x"00000000"
      report "errors on clean traffic" severity failure;

    report "ALL SIMPLE MONITOR CHECKS PASSED" severity note;
    sim_done <= true;
    wait;
  end process;
end architecture sim;
