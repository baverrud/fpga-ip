-----------------------------------------------------------------------
--Filename         : axi_read_tester_simple_tb.vhd
--Description      : Simple, hand-editable testbench for axi_read_tester.
--                   A skeleton: the sequencer resets the DUT, initializes
--                   every input signal, then hands over to a (mostly
--                   empty) user smoke-test area.  Simplified AXI4-Lite
--                   write/read helper procedures are provided so the user
--                   can configure a client and drive the tester without
--                   writing handshake code.  Edit the "USER SMOKE-TEST
--                   AREA" below to add your own stimulus/checks.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_read_tester_simple_tb is
end entity;

architecture sim of axi_read_tester_simple_tb is
  constant C_NUM_CLIENTS   : positive := 1;    -- only client 0 driven here
  constant C_ADDR_WIDTH    : positive := 32;
  constant C_ID_WIDTH      : positive := 4;
  constant C_CLIENT_PERIOD : time := 10 ns;    -- 100 MHz client clock
  constant C_MEM_PERIOD    : time := 4 ns;     -- 250 MHz native clock
  constant C_TIMEOUT       : time := 2 ms;

  -- Clocks / test control (initialized here; all stimulus below is
  -- initialized in the sequencer).
  signal aclk     : std_logic := '0';
  signal mem_aclk : std_logic := '0';
  signal aresetn  : std_logic;
  signal sim_done : boolean  := false;

  signal global_time : unsigned(47 downto 0) := (others => '0');

  -- Per-client AXI4-Lite slave (config/status), only client 0 is driven.
  -- No initializers: the sequencer sets every one of these at the start.
  signal s_axi_awaddr  : slv_array_t(0 to C_NUM_CLIENTS-1)(15 downto 0);
  signal s_axi_awprot  : slv_array_t(0 to C_NUM_CLIENTS-1)(2 downto 0);
  signal s_axi_awvalid : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_awready : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_wdata   : slv32_array_t(0 to C_NUM_CLIENTS-1);
  signal s_axi_wstrb   : slv_array_t(0 to C_NUM_CLIENTS-1)(3 downto 0);
  signal s_axi_wvalid  : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_wready  : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_bresp   : slv2_array_t(0 to C_NUM_CLIENTS-1);
  signal s_axi_bvalid  : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_bready  : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_araddr  : slv_array_t(0 to C_NUM_CLIENTS-1)(15 downto 0);
  signal s_axi_arprot  : slv_array_t(0 to C_NUM_CLIENTS-1)(2 downto 0);
  signal s_axi_arvalid : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_arready : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_rdata   : slv32_array_t(0 to C_NUM_CLIENTS-1);
  signal s_axi_rresp   : slv2_array_t(0 to C_NUM_CLIENTS-1);
  signal s_axi_rvalid  : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal s_axi_rready  : std_logic_vector(0 to C_NUM_CLIENTS-1);

  -- Per-client status / external control
  signal pipeline_busy : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal led           : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal aperture      : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal stat_rst      : std_logic_vector(0 to C_NUM_CLIENTS-1);
  signal err_rst       : std_logic_vector(0 to C_NUM_CLIENTS-1);

  -- Native AXI read master (tester -> memory model); the tester drives
  -- these, so the TB only observes them.
  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);
  signal ar_size  : std_logic_vector(2 downto 0);
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;
  signal r_id     : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data   : std_logic_vector(127 downto 0);  -- 8*16 bytes
  signal r_resp   : std_logic_vector(1 downto 0);
  signal r_last   : std_logic;
  signal r_valid  : std_logic;
  signal r_ready  : std_logic;

begin

  p_client_clk : process
  begin
    aclk <= '0';
    while not sim_done loop
      wait for C_CLIENT_PERIOD / 2;
      aclk <= not aclk;
    end loop;
    aclk <= '0';
    wait;
  end process;

  p_mem_clk : process
  begin
    mem_aclk <= '0';
    while not sim_done loop
      wait for C_MEM_PERIOD / 2;
      mem_aclk <= not mem_aclk;
    end loop;
    mem_aclk <= '0';
    wait;
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

  p_watchdog : process
  begin
    wait for C_TIMEOUT;
    if not sim_done then
      report "axi_read_tester_simple_tb watchdog timeout" severity failure;
    end if;
    wait;
  end process;

  -- -----------------------------------------------------------------
  -- DUT: tester core (one client driven) + memory model as read slave.
  -- -----------------------------------------------------------------
  u_tester : entity work.axi_read_tester
    generic map (
      GC_NUM_CLIENTS        => C_NUM_CLIENTS,
      GC_ADDR_WIDTH         => C_ADDR_WIDTH,
      GC_ID_WIDTH           => C_ID_WIDTH,
      GC_CLIENT_DATA_BYTES  => 64,
      GC_NATIVE_DATA_BYTES  => 16,
      GC_NATIVE_ARLEN_WIDTH => 8,
      GC_MAX_BURST          => 32
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
      aperture      => aperture,
      stat_rst      => stat_rst,
      err_rst       => err_rst,
      global_time   => global_time,
      ar_id    => ar_id,
      ar_addr  => ar_addr,
      ar_len   => ar_len,
      ar_size  => ar_size,
      ar_valid => ar_valid,
      ar_ready => ar_ready,
      r_id     => r_id,
      r_data   => r_data,
      r_resp   => r_resp,
      r_last   => r_last,
      r_valid  => r_valid,
      r_ready  => r_ready
    );

  u_mem : entity work.axi_mem_model
    generic map (
      GC_DATA_BYTES    => 16,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_TIMER_WIDTH   => 16
    )
    port map (
      aclk             => mem_aclk,
      aresetn          => aresetn,
      ar_base_enable   => '1',
      ar_jitter_enable => '0',
      r_base_enable    => '1',
      r_jitter_enable  => '0',
      base_latency     => x"0008",
      base_beat_gap    => x"0000",
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
  -- Sequencer: reset, initialize all inputs, then hand over to the
  -- (mostly empty) user smoke-test area.  The helper procedures are
  -- declared here so they can drive the architecture-level signals
  -- (repo rule: procedures must live in a process to drive globals).
  -- -----------------------------------------------------------------
  p_stim : process

    procedure wait_cycles(n : natural) is
    begin
      for i in 1 to n loop
        wait until rising_edge(aclk);
      end loop;
    end procedure;

    -- Simplified AXI4-Lite single-word write to client 0.
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
      loop
        wait until rising_edge(aclk);
        exit when (s_axi_awready(0) = '1') and (s_axi_wready(0) = '1');
      end loop;
      s_axi_awvalid(0) <= '0';
      s_axi_wvalid(0)  <= '0';
      loop
        wait until rising_edge(aclk);
        exit when s_axi_bvalid(0) = '1';
      end loop;
      s_axi_bready(0) <= '1';
      wait until rising_edge(aclk);
      s_axi_bready(0) <= '0';
    end procedure;

    -- Simplified AXI4-Lite single-word read from client 0.
    procedure p_axil_read(
      constant addr  : in  std_logic_vector(15 downto 0);
      variable data  : out std_logic_vector(31 downto 0)) is
    begin
      s_axi_araddr(0)  <= addr;
      s_axi_arprot(0)  <= "000";
      s_axi_arvalid(0) <= '1';
      loop
        wait until rising_edge(aclk);
        exit when s_axi_arready(0) = '1';
      end loop;
      s_axi_arvalid(0) <= '0';
      loop
        wait until rising_edge(aclk);
        exit when s_axi_rvalid(0) = '1';
      end loop;
      data := s_axi_rdata(0);
      s_axi_rready(0) <= '1';
      wait until rising_edge(aclk);
      s_axi_rready(0) <= '0';
    end procedure;

  begin
    -- 1) Reset.
    aresetn <= '0';
    wait_cycles(8);
    aresetn <= '1';
    wait until rising_edge(aclk);

    -- 2) Initialize every DUT input signal to a safe default.
    s_axi_awaddr(0)  <= (others => '0');
    s_axi_awprot(0)  <= (others => '0');
    s_axi_wdata(0)   <= (others => '0');
    s_axi_wstrb(0)   <= (others => '0');
    s_axi_awvalid(0) <= '0';
    s_axi_wvalid(0)  <= '0';
    s_axi_bready(0)  <= '0';
    s_axi_araddr(0)  <= (others => '0');
    s_axi_arprot(0)  <= (others => '0');
    s_axi_arvalid(0) <= '0';
    s_axi_rready(0)  <= '0';
    aperture(0)      <= '0';
    stat_rst(0)      <= '0';
    err_rst(0)       <= '0';
    wait until rising_edge(aclk);

    -- 3) USER SMOKE-TEST AREA (write your own stimulus/checks here).
    -- ==================================================================
    --  Example: configure client 0 and open the aperture.
    --    aperture(0) <= '1';
    --    p_axil_write(x"0000", x"00000009");  -- o_data[0]: enable, mon_enable
    --    p_axil_write(x"0004", x"00000000");  -- o_data[1]: cfg_pace = 0
    --    p_axil_write(x"0008", x"00000000");  -- o_data[2]: cfg_pace_init = 0
    --    p_axil_write(x"000C", x"00000000");  -- o_data[3]: cfg_base_addr
    --    p_axil_write(x"0010", x"00010000");  -- o_data[4]: cfg_addr_range
    --    wait_cycles(200);
    --    assert ar_valid = '1'
    --      report "no AR issued" severity failure;
    --    p_axil_read(x"8003", v_stat);       -- read a monitor stat word
    -- ==================================================================

    report "axi_read_tester_simple_tb done (no user smoke-test stimulus)";
    sim_done <= true;
    wait;
  end process;

end architecture;
