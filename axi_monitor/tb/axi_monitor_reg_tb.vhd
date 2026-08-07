-----------------------------------------------------------------------
--Filename         : axi_monitor_reg_tb.vhd
--Description      : VHDL-2008 testbench for axi_monitor_reg (AXI4-Lite
--                   register wrapper around axi_monitor + axi_ar_gen).
--                   Drives the flat AXI4-Lite port with axilite_bfm_pkg,
--                   connects axi_mem_model to the generator's AR channel
--                   and the R channel, configures the generator and
--                   monitor via the register bank, then runs a traffic
--                   window and verifies the observed statistics.
--
--                   Register access helpers (simplified wrappers around
--                   axilite_write / axilite_read):
--                     write_reg(index, value)  -- o_data[index]
--                     read_reg(index, value)   -- i_data[index]
--
--                   Checks:
--                     T1  - traffic:  ar_seen == ar_issued,
--                           xactions == ar_seen, beats == xactions*16,
--                           no protocol/data errors, pipeline drains.
--                     T2  - stat_rst clears the counters.
--                     T3  - led reflects the o_data[2] register bit.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;
use work.axilite_bfm_pkg.all;

entity axi_monitor_reg_tb is
end entity;

architecture sim of axi_monitor_reg_tb is

  constant C_CLK_PERIOD   : time    := 10 ns;
  constant C_DATA_BYTES   : natural := 16;
  constant C_ADDR_WIDTH   : natural := 49;
  constant C_ID_WIDTH     : natural := 6;
  constant C_TIME_WIDTH   : natural := 48;
  constant C_RUN_CYCLES   : natural := 2000;
  -- Safety bound for the pipeline-drain poll; the loop exits as soon as
  -- pipeline_busy clears, so this is only a timeout, not a fixed wait.
  constant C_DRAIN_CYCLES : natural := 100000;

  signal clk      : std_logic := '0';
  signal rst_n    : std_logic := '0';
  signal sim_done : boolean  := false;

  signal global_time   : unsigned(C_TIME_WIDTH-1 downto 0) := (others => '0');
  signal aperture      : std_logic := '0';
  signal stat_rst      : std_logic := '0';
  signal err_rst       : std_logic := '0';
  signal led           : std_logic;
  signal pipeline_busy : std_logic;

  -- Flat AXI4-Lite slave interface.
  signal axilite_awaddr  : std_logic_vector(39 downto 0) := (others => '0');
  signal axilite_awprot  : std_logic_vector(2 downto 0) := (others => '0');
  signal axilite_awvalid : std_logic := '0';
  signal axilite_awready : std_logic;
  signal axilite_wdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal axilite_wstrb   : std_logic_vector(3 downto 0) := (others => '0');
  signal axilite_wvalid  : std_logic := '0';
  signal axilite_wready  : std_logic;
  signal axilite_bresp   : std_logic_vector(1 downto 0);
  signal axilite_bvalid  : std_logic;
  signal axilite_bready  : std_logic := '0';
  signal axilite_araddr  : std_logic_vector(39 downto 0) := (others => '0');
  signal axilite_arprot  : std_logic_vector(2 downto 0) := (others => '0');
  signal axilite_arvalid : std_logic := '0';
  signal axilite_arready : std_logic;
  signal axilite_rdata   : std_logic_vector(31 downto 0);
  signal axilite_rresp   : std_logic_vector(1 downto 0);
  signal axilite_rvalid  : std_logic;
  signal axilite_rready  : std_logic := '0';

  -- AXI4 read-address channel (driven by axi_ar_gen, consumed by mem).
  signal ar_id     : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr   : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len    : std_logic_vector(7 downto 0);
  signal ar_size   : std_logic_vector(2 downto 0);
  signal ar_burst  : std_logic_vector(1 downto 0);
  signal ar_valid  : std_logic;
  signal ar_ready  : std_logic;

  -- AXI4 read-data channel (driven by mem, tapped by monitor).
  signal r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data  : std_logic_vector(8*C_DATA_BYTES-1 downto 0);
  signal r_resp  : std_logic_vector(1 downto 0);
  signal r_last  : std_logic;
  signal r_valid : std_logic;
  signal r_ready : std_logic;

  function u32(value : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(value, 32));
  end function;

  -- o_data registers at 0x0000 (4 bytes each); i_data at 0x8000.
  function o_data_addr(index : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(index * 4, 16));
  end function;

  function i_data_addr(index : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(16#8000# + index * 4, 16));
  end function;

begin

  clk <= not clk after C_CLK_PERIOD / 2 when not sim_done else '0';

  -- The monitor is passive and never drives r_ready; the TB acts as the
  -- R-channel consumer so the mem_model's beats are always accepted.
  r_ready <= '1';

  p_global_time : process(clk)
  begin
    if rising_edge(clk) and rst_n = '1' then
      global_time <= global_time + 1;
    end if;
  end process;

  u_dut : entity work.axi_monitor_reg
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_TIME_WIDTH    => C_TIME_WIDTH,
      GC_STAT_WIDTH    => 48,
      GC_SB_FIFO_DEPTH => 4096,
      GC_MAX_BURST     => 256
    )
    port map (
      aclk           => clk,
      aresetn        => rst_n,
      global_time    => global_time,
      aperture       => aperture,
      stat_rst       => stat_rst,
      err_rst        => err_rst,
      led            => led,
      pipeline_busy  => pipeline_busy,
      axilite_awaddr  => axilite_awaddr,
      axilite_awprot  => axilite_awprot,
      axilite_awvalid => axilite_awvalid,
      axilite_awready => axilite_awready,
      axilite_wdata   => axilite_wdata,
      axilite_wstrb   => axilite_wstrb,
      axilite_wvalid  => axilite_wvalid,
      axilite_wready  => axilite_wready,
      axilite_bresp   => axilite_bresp,
      axilite_bvalid  => axilite_bvalid,
      axilite_bready  => axilite_bready,
      axilite_araddr  => axilite_araddr,
      axilite_arprot  => axilite_arprot,
      axilite_arvalid => axilite_arvalid,
      axilite_arready => axilite_arready,
      axilite_rdata   => axilite_rdata,
      axilite_rresp   => axilite_rresp,
      axilite_rvalid  => axilite_rvalid,
      axilite_rready  => axilite_rready,
      ar_valid        => ar_valid,
      ar_ready        => ar_ready,
      ar_id           => ar_id,
      ar_addr         => ar_addr,
      ar_len          => ar_len,
      ar_size         => ar_size,
      ar_burst        => ar_burst,
      r_valid         => r_valid,
      r_ready         => r_ready,
      r_id            => r_id,
      r_data          => r_data,
      r_resp          => r_resp,
      r_last          => r_last
    );

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
      aclk             => clk,
      aresetn          => rst_n,
      ar_base_enable   => '1',
      ar_jitter_enable => '1',
      r_base_enable    => '1',
      r_jitter_enable  => '1',
      base_latency     => std_logic_vector(to_unsigned(5, 16)),
      base_beat_gap    => std_logic_vector(to_unsigned(3, 16)),
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

  p_stimulus : process
    variable data     : std_logic_vector(31 downto 0);
    variable ar_seen  : natural;
    variable ar_stall : natural;
    variable xactions : natural;
    variable beats    : natural;
    variable errors   : natural;

    -- Simplified AXI4-Lite register access (o_data write / i_data read).
    procedure write_reg(
      constant index : in natural;
      constant value : in std_logic_vector(31 downto 0);
      constant strb  : in std_logic_vector(3 downto 0) := x"F"
    ) is
    begin
      axilite_write(
        clk, axilite_awaddr, axilite_awprot, axilite_awvalid, axilite_awready,
        axilite_wdata, axilite_wstrb, axilite_wvalid, axilite_wready,
        axilite_bready, axilite_bvalid, o_data_addr(index), value, strb
      );
    end procedure;

    procedure read_reg(
      constant index : in natural;
      variable value : out std_logic_vector(31 downto 0)
    ) is
    begin
      axilite_read(
        clk, axilite_araddr, axilite_arprot, axilite_arvalid, axilite_arready,
        axilite_rready, axilite_rvalid, axilite_rdata, i_data_addr(index), value
      );
    end procedure;

  begin
    report "=== axi_monitor_reg: flat-port traffic + register check ==="
      severity note;

    -- Reset
    rst_n <= '0';
    wait_cycles(clk, 10);
    rst_n <= '1';
    wait_cycles(clk, 5);

    -- Pulse stat/err reset to start from a clean state
    stat_rst <= '1';
    err_rst  <= '1';
    wait_cycles(clk, 2);
    stat_rst <= '0';
    err_rst  <= '0';
    wait_cycles(clk, 2);

    ------------------------------------------------------------------
    -- T1: configure and run traffic
    ------------------------------------------------------------------
    report "=== T1: configure generator/monitor, run traffic ==="
      severity note;

    -- Monitor control (o_data): enable=1, data_check_en=1
    write_reg(0, u32(1));
    write_reg(1, u32(1));

    -- Generator config (o_data): enable=1, 16-beat bursts over 64 KiB.
    write_reg(3, u32(1));               -- gen enable
    write_reg(4, u32(0));               -- cfg_id
    write_reg(5, u32(15));              -- cfg_arlen = 15 -> 16 beats
    write_reg(6, u32(0));               -- cfg_pace = 0 (every cycle)
    write_reg(7, u32(0));               -- cfg_pace_init
    write_reg(8, x"00001000");          -- cfg_base_addr[31:0]
    write_reg(9, u32(0));               -- cfg_base_addr[48:32]
    write_reg(10, x"00010000");         -- cfg_addr_range[31:0]
    write_reg(11, u32(0));              -- cfg_addr_range[48:32]
    write_reg(12, u32(0));              -- cfg_addr_mode = linear

    aperture <= '1';
    wait_cycles(clk, C_RUN_CYCLES);

    -- Stop generation; keep the monitor window open to drain.
    write_reg(3, u32(0));               -- gen enable = 0

    -- Drain until the scoreboard empties (pipeline_busy deasserts).
    -- Polling is robust: the generator floods the mem_model FIFO, so
    -- draining hundreds of in-flight bursts takes many thousands of
    -- cycles; a short fixed window would falsely fail this check.
    for i in 1 to C_DRAIN_CYCLES loop
      exit when pipeline_busy = '0';
      wait_cycles(clk, 1);
    end loop;
    aperture <= '0';

    assert pipeline_busy = '0'
      report "T1: pipeline_busy did not clear within the drain timeout"
      severity error;

    read_reg(0, data);
    ar_seen := to_integer(unsigned(data));
    assert ar_seen > 0
      report "T1: no AR transactions were observed"
      severity error;

    read_reg(30, data);                 -- gen_stat_ar_issued
    assert ar_seen = to_integer(unsigned(data))
      report "T1: monitor ar_seen != generator ar_issued"
      severity error;

    read_reg(3, data);
    xactions := to_integer(unsigned(data));
    assert xactions = ar_seen
      report "T1: xactions != ar_seen (incomplete bursts?)"
      severity error;

    read_reg(4, data);
    beats := to_integer(unsigned(data));
    assert beats = xactions * 16
      report "T1: beats != xactions*16"
      severity error;

    errors := 0;
    for index in 24 to 28 loop           -- data/id/rlast/resp/sb_uf errors
      read_reg(index, data);
      errors := errors + to_integer(unsigned(data));
    end loop;
    read_reg(31, data);                  -- gen_stat_cfg_errors
    errors := errors + to_integer(unsigned(data));
    assert errors = 0
      report "T1: unexpected protocol/data/config errors detected"
      severity error;

    -- Wide-stat readback:  burst_len min/max, latency, elapsed,
    -- max_outstanding, and the generator's ar_stall counter.
    read_reg(19, data);                  -- stat_burst_len_min
    assert to_integer(unsigned(data)) = 16
      report "T1: burst_len_min != 16 via register"
      severity error;
    read_reg(20, data);                  -- stat_burst_len_max
    assert to_integer(unsigned(data)) = 16
      report "T1: burst_len_max != 16 via register"
      severity error;
    read_reg(17, data);                  -- stat_burst_len_sum low word
    assert to_integer(unsigned(data)) = beats
      report "T1: burst_len_sum low word != beats"
      severity error;
    read_reg(18, data);                  -- stat_burst_len_sum high word
    assert to_integer(unsigned(data)) = 0
      report "T1: burst_len_sum high word != 0"
      severity error;
    read_reg(7, data);                   -- stat_latency_min
    assert to_integer(unsigned(data)) > 0
      report "T1: latency_min == 0 via register"
      severity error;
    read_reg(23, data);                  -- stat_max_outstanding
    assert to_integer(unsigned(data)) > 0
      report "T1: max_outstanding == 0 via register"
      severity error;
    read_reg(21, data);                  -- stat_elapsed_cycles
    assert to_integer(unsigned(data)) > 0
      report "T1: elapsed_cycles == 0 via register"
      severity error;
    -- Generator ar_stall must match the monitor's ar_stall:  the AR FIFO
    -- in the mem_model is only depth 8, so at pace=0 the generator stalls
    -- against mem backpressure exactly as often as the monitor observes.
    read_reg(29, data);                  -- gen_stat_ar_stall
    ar_stall := to_integer(unsigned(data));
    assert ar_stall > 0
      report "T1: generator never stalled against mem AR backpressure"
      severity error;
    read_reg(1, data);                   -- monitor stat_ar_stall
    assert ar_stall = to_integer(unsigned(data))
      report "T1: generator/monitor ar_stall mismatch"
      severity error;

    report "T1 PASS: ar_seen=" & integer'image(ar_seen) &
           " xactions=" & integer'image(xactions) &
           " beats=" & integer'image(beats)
      severity note;

    ------------------------------------------------------------------
    -- T2: stat_rst clears the counters
    ------------------------------------------------------------------
    report "=== T2: stat_rst clears counters ===" severity note;
    stat_rst <= '1';
    wait_cycles(clk, 2);
    stat_rst <= '0';
    wait_cycles(clk, 2);

    read_reg(3, data);                   -- stat_xactions
    assert to_integer(unsigned(data)) = 0
      report "T2: stat_rst did not clear xactions"
      severity error;
    read_reg(0, data);                   -- stat_ar_seen
    assert to_integer(unsigned(data)) = 0
      report "T2: stat_rst did not clear ar_seen"
      severity error;
    read_reg(30, data);                  -- gen_stat_ar_issued
    assert to_integer(unsigned(data)) = 0
      report "T2: stat_rst did not clear generator ar_issued"
      severity error;

    report "T2 PASS: counters cleared" severity note;

    ------------------------------------------------------------------
    -- T3: led reflects o_data[2]
    ------------------------------------------------------------------
    report "=== T3: led register bit ===" severity note;
    write_reg(2, u32(0));
    wait_cycles(clk, 2);
    assert led = '0'
      report "T3: led not low after o_data[2]=0"
      severity error;
    write_reg(2, u32(1));
    wait_cycles(clk, 2);
    assert led = '1'
      report "T3: led not high after o_data[2]=1"
      severity error;
    report "T3 PASS: led follows o_data[2]" severity note;

    ------------------------------------------------------------------
    -- T4: monitor enable off (via register) while generator runs
    ------------------------------------------------------------------
    report "=== T4: monitor disable via register ===" severity note;
    stat_rst <= '1';
    wait_cycles(clk, 2);
    stat_rst <= '0';
    wait_cycles(clk, 2);

    -- Turn the monitor off (o_data[0]=0); keep the generator running.
    write_reg(0, u32(0));               -- mon enable = 0
    write_reg(3, u32(1));               -- gen enable = 1
    aperture <= '1';
    wait_cycles(clk, C_RUN_CYCLES);
    write_reg(3, u32(0));               -- gen enable = 0

    -- Monitor is inert:  no transactions/beats/errors observed, and the
    -- scoreboard stays empty so the pipeline is not busy.
    read_reg(0, data);                   -- stat_ar_seen
    assert to_integer(unsigned(data)) = 0
      report "T4: monitor counted ARs while disabled"
      severity error;
    read_reg(3, data);                   -- stat_xactions
    assert to_integer(unsigned(data)) = 0
      report "T4: monitor counted xactions while disabled"
      severity error;
    read_reg(4, data);                   -- stat_beats
    assert to_integer(unsigned(data)) = 0
      report "T4: monitor counted beats while disabled"
      severity error;
    errors := 0;
    for index in 24 to 28 loop
      read_reg(index, data);
      errors := errors + to_integer(unsigned(data));
    end loop;
    assert errors = 0
      report "T4: errors counted while monitor disabled"
      severity error;
    wait_cycles(clk, 2);
    assert pipeline_busy = '0'
      report "T4: pipeline busy while monitor disabled"
      severity error;

    -- Re-enable the monitor for subsequent tests.
    write_reg(0, u32(1));
    report "T4 PASS: monitor inert while disabled" severity note;

    ------------------------------------------------------------------
    -- T5: partial-write (wstrb) to a generator config register
    ------------------------------------------------------------------
    report "=== T5: partial write to cfg_arlen (wstrb) ===" severity note;

    -- T4 left in-flight R responses draining out of the mem_model.  Pulse a
    -- full reset so the mem_model FIFOs and the monitor/generator state are
    -- flushed before this test; the registers are re-programmed below.
    rst_n <= '0';
    wait_cycles(clk, 5);
    rst_n <= '1';
    wait_cycles(clk, 5);
    stat_rst <= '1';
    wait_cycles(clk, 2);
    stat_rst <= '0';
    wait_cycles(clk, 2);

    -- Monitor enabled again for this test.
    write_reg(0, u32(1));               -- mon enable
    write_reg(1, u32(1));               -- data_check_en

    -- Verify the write strobe masks register writes.  Start from
    -- cfg_arlen = 0 (1 beat), then write 15 to byte 0 only using a
    -- single-lane strobe.  A masked write must update only byte 0, so
    -- cfg_arlen becomes 15 -> 16-beat bursts.
    write_reg(5, u32(0));               -- cfg_arlen = 0 (1 beat)
    write_reg(5, x"0000000F", x"1");    -- byte 0 only -> cfg_arlen 15
    write_reg(3, u32(1));               -- gen enable
    aperture <= '1';
    wait_cycles(clk, C_RUN_CYCLES);
    write_reg(3, u32(0));               -- gen enable = 0
    for i in 1 to C_DRAIN_CYCLES loop
      exit when pipeline_busy = '0';
      wait_cycles(clk, 1);
    end loop;
    aperture <= '0';

    read_reg(4, data);                   -- stat_beats
    beats := to_integer(unsigned(data));
    read_reg(3, data);                   -- stat_xactions
    xactions := to_integer(unsigned(data));
    assert xactions > 0
      report "T5: no transactions after partial write"
      severity error;
    assert beats = xactions * 16
      report "T5: partial byte write did not set cfg_arlen to 15"
      severity error;
    read_reg(20, data);                  -- stat_burst_len_max
    assert to_integer(unsigned(data)) = 16
      report "T5: burst_len_max != 16 after partial write"
      severity error;
    report "T5 PASS: wstrb applied to config register" severity note;

    report "=== Simulation complete ===" severity note;
    sim_done <= true;
    wait;
  end process;

end architecture;
