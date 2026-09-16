-----------------------------------------------------------------------
--Filename         : axi_read_tester_tb.vhd
--Description      : Integration testbench skeleton for axi_read_tester.
--                 : Instantiates the tester plus axi_mem_model on the
--                 : native AXI master, configures client 0 through its
--                 : AXI4-Lite register interface, and runs a measurement
--                 : window that closes, drains, and checks status counters.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_tester_tb is
  generic (
    GC_CLK_PERIOD : time := 4 ns   -- 250 MHz
  );
end entity;

architecture sim of axi_read_tester_tb is

  constant C_NUM_CLIENTS : positive := 4;
  constant C_ADDR_W      : positive := 32;
  constant C_ID_W        : positive := 4;

  -- Tester DUT I/O
  signal aclk : std_logic := '0';
  signal mem_aclk    : std_logic := '0';
  signal aresetn     : std_logic := '0';

  signal s_axi_awaddr  : slv_array_t(0 to C_NUM_CLIENTS-1)(15 downto 0) := (others => (others => '0'));
  signal s_axi_awprot  : slv_array_t(0 to C_NUM_CLIENTS-1)(2 downto 0)  := (others => (others => '0'));
  signal s_axi_awvalid : std_logic_vector(0 to C_NUM_CLIENTS-1) := (others => '0');
  signal s_axi_awready : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_wdata   : slv32_array_t(0 to C_NUM_CLIENTS-1) := (others => (others => '0'));
  signal s_axi_wstrb   : slv_array_t(0 to C_NUM_CLIENTS-1)(3 downto 0) := (others => (others => '0'));
  signal s_axi_wvalid  : std_logic_vector(0 to C_NUM_CLIENTS-1) := (others => '0');
  signal s_axi_wready  : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_bresp   : slv2_array_t(0 to C_NUM_CLIENTS-1);
  signal s_axi_bvalid  : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_bready  : std_logic_vector(0 to C_NUM_CLIENTS-1) := (others => '0');
  signal s_axi_araddr  : slv_array_t(0 to C_NUM_CLIENTS-1)(15 downto 0) := (others => (others => '0'));
  signal s_axi_arprot  : slv_array_t(0 to C_NUM_CLIENTS-1)(2 downto 0)  := (others => (others => '0'));
  signal s_axi_arvalid : std_logic_vector(0 to C_NUM_CLIENTS-1) := (others => '0');
  signal s_axi_arready : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_rdata   : slv32_array_t(0 to C_NUM_CLIENTS-1);
  signal s_axi_rresp   : slv2_array_t(0 to C_NUM_CLIENTS-1);
  signal s_axi_rvalid  : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_rready  : std_logic_vector(0 to C_NUM_CLIENTS-1) := (others => '0');

  signal pipeline_busy : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal led           : std_logic_vector(0 to C_NUM_CLIENTS-1);

  -- Global external control / shared time reference
  signal aperture   : std_logic := '0';
  signal stat_rst   : std_logic := '0';
  signal err_rst    : std_logic := '0';
  signal global_time : unsigned(47 downto 0) := (others => '0');

  -- Native AXI master (to axi_mem_model)
  signal ar_id    : std_logic_vector(C_ID_W-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_W-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;
  signal r_id     : std_logic_vector(C_ID_W-1 downto 0);
  signal r_data   : std_logic_vector(127 downto 0);
  signal r_resp   : std_logic_vector(1 downto 0);
  signal r_last   : std_logic;
  signal r_valid  : std_logic;
  signal r_ready  : std_logic;

  -- Memory model control (tie to simple constant latency)
  signal mem_base_latency : std_logic_vector(15 downto 0) := x"0008";
  signal mem_base_gap     : std_logic_vector(15 downto 0) := x"0000";

  signal sim_done : boolean := false;

begin

  -- -----------------------------------------------------------------
  -- DUT
  -- -----------------------------------------------------------------
  u_tester : entity work.axi_read_tester
    generic map (
      GC_NUM_CLIENTS       => C_NUM_CLIENTS,
      GC_ADDR_WIDTH        => C_ADDR_W,
      GC_ID_WIDTH          => C_ID_W,
      GC_CLIENT_DATA_BYTES => 64,
      GC_NATIVE_DATA_BYTES => 16,
      GC_NATIVE_ARLEN_WIDTH => 8,
      GC_MAX_BURST         => 32
    )
    port map (
      aclk => aclk,
      mem_aclk    => mem_aclk,
      aresetn     => aresetn,
      s_axi_awaddr  => s_axi_awaddr,
      s_axi_awprot  => s_axi_awprot,
      s_axi_awvalid => s_axi_awvalid,
      s_axi_awready => s_axi_awready,
      s_axi_wdata   => s_axi_wdata,
      s_axi_wstrb   => s_axi_wstrb,
      s_axi_wvalid  => s_axi_wvalid,
      s_axi_wready  => s_axi_wready,
      s_axi_bresp   => s_axi_bresp,
      s_axi_bvalid  => s_axi_bvalid,
      s_axi_bready  => s_axi_bready,
      s_axi_araddr  => s_axi_araddr,
      s_axi_arprot  => s_axi_arprot,
      s_axi_arvalid => s_axi_arvalid,
      s_axi_arready => s_axi_arready,
      s_axi_rdata   => s_axi_rdata,
      s_axi_rresp   => s_axi_rresp,
      s_axi_rvalid  => s_axi_rvalid,
      s_axi_rready  => s_axi_rready,
      pipeline_busy => pipeline_busy,
      led           => led,
      aperture     => aperture,
      stat_rst     => stat_rst,
      err_rst      => err_rst,
      global_time  => global_time,
      ar_id    => ar_id,
      ar_addr  => ar_addr,
      ar_len   => ar_len,
      ar_valid => ar_valid,
      ar_ready => ar_ready,
      r_id     => r_id,
      r_data   => r_data,
      r_resp   => r_resp,
      r_last   => r_last,
      r_valid  => r_valid,
      r_ready  => r_ready
    );

  -- Native AXI read slave (memory model)
  u_mem : entity work.axi_mem_model
    generic map (
      GC_DATA_BYTES    => 16,
      GC_ADDR_WIDTH    => C_ADDR_W,
      GC_ID_WIDTH      => C_ID_W,
      GC_TIMER_WIDTH   => 16
    )
    port map (
      aclk             => mem_aclk,
      aresetn          => aresetn,
      ar_base_enable   => '1',
      ar_jitter_enable => '0',
      r_base_enable    => '1',
      r_jitter_enable  => '0',
      base_latency     => mem_base_latency,
      base_beat_gap    => mem_base_gap,
      ar_id    => ar_id,
      ar_addr  => ar_addr,
      ar_len   => ar_len,
      ar_valid => ar_valid,
      ar_ready => ar_ready,
      r_id     => r_id,
      r_data   => r_data,
      r_resp   => r_resp,
      r_last   => r_last,
      r_valid  => r_valid,
      r_ready  => r_ready
    );

  -- -----------------------------------------------------------------
  -- Clocks (both domains, same frequency)
  -- -----------------------------------------------------------------
  p_clk_client : process
  begin
    aclk <= '0';
    wait for GC_CLK_PERIOD / 2;
    loop
      if sim_done then
        aclk <= '0';
        wait;
      end if;
      aclk <= not aclk;
      wait for GC_CLK_PERIOD / 2;
    end loop;
  end process;

  p_clk_mem : process
  begin
    mem_aclk <= '0';
    wait for GC_CLK_PERIOD / 2;
    loop
      if sim_done then
        mem_aclk <= '0';
        wait;
      end if;
      mem_aclk <= not mem_aclk;
      wait for GC_CLK_PERIOD / 2;
    end loop;
  end process;

  -- Free-running global time reference (client clock domain).
  p_gt : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        global_time <= (others => '0');
      else
        global_time <= global_time + 1;
      end if;
    end if;
  end process;

  -- -----------------------------------------------------------------
  -- Stimulus: reset, configure client 0, run a smoke window.
  -- -----------------------------------------------------------------
  p_stim : process
    variable v_wait : natural := 0;

    -- AXI4-Lite single-word write to client 0 (drives the tester's
    -- per-client register interface). Local to this process so it can drive
    -- the architecture-level signals (repo rule: procedures must live in a
    -- process to drive global signals).
    procedure p_axil_write(
      constant addr : in std_logic_vector(15 downto 0);
      constant data : in std_logic_vector(31 downto 0)) is
    begin
      s_axi_awaddr(0)  <= addr;
      s_axi_awprot(0)  <= "000";
      s_axi_wdata(0)   <= data;
      s_axi_wstrb(0)   <= "1111";
      s_axi_awvalid(0) <= '1';
      s_axi_wvalid(0)  <= '1';
      wait until rising_edge(aclk);
      loop
        exit when (s_axi_awready(0) = '1') and (s_axi_wready(0) = '1');
        wait until rising_edge(aclk);
      end loop;
      s_axi_awvalid(0) <= '0';
      s_axi_wvalid(0)  <= '0';
      loop
        exit when s_axi_bvalid(0) = '1';
        wait until rising_edge(aclk);
      end loop;
      s_axi_bready(0) <= '1';
      wait until rising_edge(aclk);
      s_axi_bready(0) <= '0';
    end procedure;

    procedure p_axil_read(
      constant addr : in std_logic_vector(15 downto 0);
      variable data : out std_logic_vector(31 downto 0)) is
    begin
      s_axi_araddr(0)  <= addr;
      s_axi_arprot(0)  <= "000";
      s_axi_arvalid(0) <= '1';
      wait until rising_edge(aclk);
      loop
        exit when s_axi_arready(0) = '1';
        wait until rising_edge(aclk);
      end loop;
      s_axi_arvalid(0) <= '0';
      s_axi_rready(0)  <= '1';
      loop
        exit when s_axi_rvalid(0) = '1';
        wait until rising_edge(aclk);
      end loop;
      data := s_axi_rdata(0);
      wait until rising_edge(aclk);
      s_axi_rready(0) <= '0';
    end procedure;

    variable v_stat : std_logic_vector(31 downto 0);

  begin
    aresetn <= '0';
    for i in 1 to 8 loop
      wait until rising_edge(aclk);
    end loop;
    aresetn <= '1';
    wait until rising_edge(aclk);

    -- Configure client 0: enable generation + monitor enable, data checking,
    -- 32-beat requests, line-rate pace, base address 0x0, and 64 KiB range.
    p_axil_write(x"0000", x"00000001");  -- o_data[0]: enable
    p_axil_write(x"0004", x"00000001");  -- o_data[1]: mon_enable
    p_axil_write(x"0008", x"00000001");  -- o_data[2]: data_check_enable
    p_axil_write(x"0014", x"0000001F");  -- o_data[5]: cfg_req_len = 32 beats
    p_axil_write(x"001C", x"00000000");  -- o_data[7]: cfg_pace = 0
    p_axil_write(x"0020", x"00000000");  -- o_data[8]: cfg_pace_init = 0
    p_axil_write(x"0024", x"00000000");  -- o_data[9]: cfg_base_addr
    p_axil_write(x"0028", x"00010000");  -- o_data[10]: cfg_addr_range = 64 KiB

    stat_rst <= '1';
    wait until rising_edge(aclk);
    stat_rst <= '0';
    aperture <= '1';

    -- Check 1: a request must reach the native AR channel.
    v_wait := 0;
    while ar_valid = '0' or ar_ready = '0' loop
      assert v_wait < 2000
        report "FAIL: no AR transaction issued"
        severity failure;
      wait until rising_edge(mem_aclk);
      v_wait := v_wait + 1;
    end loop;
    report "SMOKE: native AR issued (id=" & integer'image(to_integer(unsigned(ar_id))) &
           ", len=" & integer'image(to_integer(unsigned(ar_len))) & ")";

    -- Check 2: the memory model must return a response beat.
    v_wait := 0;
    while r_valid = '0' or r_ready = '0' loop
      assert v_wait < 2000
        report "FAIL: no R response returned"
        severity failure;
      wait until rising_edge(mem_aclk);
      v_wait := v_wait + 1;
    end loop;
    report "SMOKE: R response returned";

    -- Let several bursts complete, then close the aperture and drain them.
    for i in 1 to 200 loop
      wait until rising_edge(aclk);
    end loop;
    aperture <= '0';
    v_wait := 0;
    while pipeline_busy(0) = '1' loop
      assert v_wait < 2000
        report "FAIL: pipeline did not drain after aperture close"
        severity failure;
      wait until rising_edge(aclk);
      v_wait := v_wait + 1;
    end loop;

    p_axil_write(x"0000", x"00000000");  -- stop the generator
    p_axil_write(x"0004", x"00000000");  -- stop the monitor

    -- Status indexes: xactions=6, beats=7, latency_min=10,
    -- elapsed=24, data_errors=27, rlast_errors=28, response_errors=29,
    -- scoreboard_underflows=30.
    p_axil_read(x"8018", v_stat);
    assert unsigned(v_stat) > 0
      report "FAIL: no completed transactions counted"
      severity failure;
    p_axil_read(x"801C", v_stat);
    assert unsigned(v_stat) >= 1
      report "FAIL: no response beats counted"
      severity failure;
    p_axil_read(x"8028", v_stat);
    assert v_stat /= x"FFFFFFFF"
      report "FAIL: latency minimum was not sampled"
      severity failure;
    p_axil_read(x"8060", v_stat);
    assert unsigned(v_stat) > 0
      report "FAIL: aperture elapsed time was not captured"
      severity failure;
    p_axil_read(x"806C", v_stat);
    assert v_stat = x"00000000"
      report "FAIL: unexpected data errors"
      severity failure;
    p_axil_read(x"8070", v_stat);
    assert v_stat = x"00000000"
      report "FAIL: unexpected RLAST errors"
      severity failure;
    p_axil_read(x"8074", v_stat);
    assert v_stat = x"00000000"
      report "FAIL: unexpected response errors"
      severity failure;
    p_axil_read(x"8078", v_stat);
    assert v_stat = x"00000000"
      report "FAIL: unexpected scoreboard underflows"
      severity failure;

    report "AXI READ TESTER STATISTICS PASSED";
    sim_done <= true;
    wait;
  end process;

  -- Watchdog
  p_watchdog : process
  begin
    wait for 100 us;
    if not sim_done then
      report "FAIL: watchdog timeout (axi_read_tester_tb)" severity failure;
    end if;
    wait;
  end process;

end architecture;
