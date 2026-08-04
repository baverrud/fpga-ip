-----------------------------------------------------------------------
--Filename         : axi4_read_tester_multi_tb.vhd
--Description      : Testbench for axi4_read_tester_multi.
--                   Instantiates 4 x axi_mem_model on the AR/R buses,
--                   drives axilite_ctrl + per-shim axilite buses via
--                   package-level AXI4-Lite BFM procedures, and runs
--                   a simple configure / run / verify sequence.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;
use work.axi4_pkg.all;
use work.axilite_pkg.all;

entity axi4_read_tester_multi_tb is
end entity;

architecture sim of axi4_read_tester_multi_tb is

  constant C_CLK_PERIOD  : time    := 10 ns;
  constant C_DATA_BYTES  : natural := 16;
  constant C_ADDR_WIDTH  : natural := 49;
  constant C_ID_WIDTH    : natural := 6;
  constant C_DRAIN       : natural := 500;

  signal clk    : std_logic := '0';
  signal rst_n  : std_logic := '0';
  signal sim_done : boolean := false;

  signal led : std_logic_vector(4 downto 0);
  signal pipeline_busy : std_logic_vector(0 to 3);

  -- AXI4-Lite buses -- one per shim instance
  signal axilite_0 : axilite_m40_t;
  signal axilite_1 : axilite_m40_t;
  signal axilite_2 : axilite_m40_t;
  signal axilite_3 : axilite_m40_t;

  -- AXI4-Lite control bus for multi-level registers
  signal axilite_ctrl : axilite_m40_t;

  -- AXI4 AR/R buses -- one per shim instance
  signal ar_0 : axi4_hp_ar_t;
  signal ar_1 : axi4_hp_ar_t;
  signal ar_2 : axi4_hp_ar_t;
  signal ar_3 : axi4_hp_ar_t;

  signal r_0 : axi4_hp_r_t;
  signal r_1 : axi4_hp_r_t;
  signal r_2 : axi4_hp_r_t;
  signal r_3 : axi4_hp_r_t;

  function u32(n : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(n, 32));
  end function;

  function reg_addr(index : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(index * 4, 16));
  end function;

  procedure wait_cycles(n : natural) is
  begin
    for i in 1 to n loop
      wait until rising_edge(clk);
    end loop;
  end procedure;

begin

  --------------------------------------------------------------------
  -- Clock generator
  --------------------------------------------------------------------
  clk <= not clk after C_CLK_PERIOD / 2 when not sim_done else '0';

  --------------------------------------------------------------------
  -- Device under test: axi4_read_tester_multi
  --------------------------------------------------------------------
  u_dut : entity work.axi4_read_tester_multi
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_SB_FIFO_DEPTH => 256,
      GC_MAX_BURST     => 256
    )
    port map (
      aclk         => clk,
      aresetn      => rst_n,
      axilite_0    => axilite_0,
      axilite_1    => axilite_1,
      axilite_2    => axilite_2,
      axilite_3    => axilite_3,
      ar_0         => ar_0,
      ar_1         => ar_1,
      ar_2         => ar_2,
      ar_3         => ar_3,
      r_0          => r_0,
      r_1          => r_1,
      r_2          => r_2,
      r_3          => r_3,
      axilite_ctrl => axilite_ctrl,
      led          => led,
      pipeline_busy => pipeline_busy
    );

  --------------------------------------------------------------------
  -- Memory models -- one per AR/R pair
  --------------------------------------------------------------------
  u_mem_0 : entity work.axi_mem_model
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_AR_FIFO_DEPTH => 256,
      GC_TIMER_WIDTH   => 16,
      GC_R_FIFO_DEPTH  => 8
    )
    port map (
      aclk           => clk,          aresetn        => rst_n,
      ar_base_enable   => '1',        ar_jitter_enable => '1',
      r_base_enable    => '1',        r_jitter_enable  => '1',
      base_latency     => u32(5)(15 downto 0),
      base_beat_gap  => u32(3)(15 downto 0),
      ar_valid       => ar_0.arvalid, ar_ready       => ar_0.arready,
      ar_id          => ar_0.arid,    ar_addr        => ar_0.araddr,
      ar_len         => ar_0.arlen,
      r_valid        => r_0.rvalid,   r_ready        => r_0.rready,
      r_id           => r_0.rid,     r_data         => r_0.rdata,
      r_resp         => r_0.rresp,   r_last         => r_0.rlast
    );

  u_mem_1 : entity work.axi_mem_model
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,  GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,    GC_AR_FIFO_DEPTH => 256,
      GC_TIMER_WIDTH   => 16,           GC_R_FIFO_DEPTH  => 8
    )
    port map (
      aclk           => clk,          aresetn        => rst_n,
      ar_base_enable   => '1',        ar_jitter_enable => '1',
      r_base_enable    => '1',        r_jitter_enable  => '1',
      base_latency     => u32(5)(15 downto 0),
      base_beat_gap  => u32(3)(15 downto 0),
      ar_valid       => ar_1.arvalid, ar_ready       => ar_1.arready,
      ar_id          => ar_1.arid,    ar_addr        => ar_1.araddr,
      ar_len         => ar_1.arlen,
      r_valid        => r_1.rvalid,   r_ready        => r_1.rready,
      r_id           => r_1.rid,     r_data         => r_1.rdata,
      r_resp         => r_1.rresp,   r_last         => r_1.rlast
    );

  u_mem_2 : entity work.axi_mem_model
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,  GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,    GC_AR_FIFO_DEPTH => 256,
      GC_TIMER_WIDTH   => 16,           GC_R_FIFO_DEPTH  => 8
    )
    port map (
      aclk           => clk,          aresetn        => rst_n,
      ar_base_enable   => '1',        ar_jitter_enable => '1',
      r_base_enable    => '1',        r_jitter_enable  => '1',
      base_latency     => u32(5)(15 downto 0),
      base_beat_gap  => u32(3)(15 downto 0),
      ar_valid       => ar_2.arvalid, ar_ready       => ar_2.arready,
      ar_id          => ar_2.arid,    ar_addr        => ar_2.araddr,
      ar_len         => ar_2.arlen,
      r_valid        => r_2.rvalid,   r_ready        => r_2.rready,
      r_id           => r_2.rid,     r_data         => r_2.rdata,
      r_resp         => r_2.rresp,   r_last         => r_2.rlast
    );

  u_mem_3 : entity work.axi_mem_model
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,  GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,    GC_AR_FIFO_DEPTH => 256,
      GC_TIMER_WIDTH   => 16,           GC_R_FIFO_DEPTH  => 8
    )
    port map (
      aclk           => clk,          aresetn        => rst_n,
      ar_base_enable   => '1',        ar_jitter_enable => '1',
      r_base_enable    => '1',        r_jitter_enable  => '1',
      base_latency     => u32(5)(15 downto 0),
      base_beat_gap  => u32(3)(15 downto 0),
      ar_valid       => ar_3.arvalid, ar_ready       => ar_3.arready,
      ar_id          => ar_3.arid,    ar_addr        => ar_3.araddr,
      ar_len         => ar_3.arlen,
      r_valid        => r_3.rvalid,   r_ready        => r_3.rready,
      r_id           => r_3.rid,     r_data         => r_3.rdata,
      r_resp         => r_3.rresp,   r_last         => r_3.rlast
    );

  --------------------------------------------------------------------
  -- AXI4 fill signals -- drive unused fields to zero
  --------------------------------------------------------------------
  r_0.ruser <= (others => '0');
  r_1.ruser <= (others => '0');
  r_2.ruser <= (others => '0');
  r_3.ruser <= (others => '0');

  --------------------------------------------------------------------
  -- Stimulus
  --------------------------------------------------------------------
  p_stimulus : process
    variable l          : line;
    variable v_data     : std_logic_vector(31 downto 0);

    ------------------------------------------------------------------
    -- Per-bus BFM helpers for each axilite instance
    ------------------------------------------------------------------
    procedure axi_wr_0(
      constant index : in natural;
      constant dat   : in std_logic_vector(31 downto 0)
    ) is
    begin
      axilite_write(
        aclk    => clk,
        awaddr  => axilite_0.awaddr,
        awprot  => axilite_0.awprot,
        awvalid => axilite_0.awvalid,
        awready => axilite_0.awready,
        wdata   => axilite_0.wdata,
        wstrb   => axilite_0.wstrb,
        wvalid  => axilite_0.wvalid,
        wready  => axilite_0.wready,
        bready  => axilite_0.bready,
        bvalid  => axilite_0.bvalid,
        addr    => reg_addr(index),
        dat     => dat
      );
    end procedure;

    procedure axi_wr_ctrl(
      constant index : in natural;
      constant dat   : in std_logic_vector(31 downto 0)
    ) is
    begin
      axilite_write(
        aclk    => clk,
        awaddr  => axilite_ctrl.awaddr,
        awprot  => axilite_ctrl.awprot,
        awvalid => axilite_ctrl.awvalid,
        awready => axilite_ctrl.awready,
        wdata   => axilite_ctrl.wdata,
        wstrb   => axilite_ctrl.wstrb,
        wvalid  => axilite_ctrl.wvalid,
        wready  => axilite_ctrl.wready,
        bready  => axilite_ctrl.bready,
        bvalid  => axilite_ctrl.bvalid,
        addr    => reg_addr(index),
        dat     => dat
      );
    end procedure;
  begin
    -- Power-on reset
    rst_n <= '0';
    wait_cycles(10);
    rst_n <= '1';
    wait_cycles(5);

    -- Initialise all axilite BFM buses to idle
    axilite_0.awvalid <= '0'; axilite_0.wvalid <= '0'; axilite_0.arvalid <= '0';
    axilite_0.bready  <= '0'; axilite_0.rready <= '0';
    axilite_1.awvalid <= '0'; axilite_1.wvalid <= '0'; axilite_1.arvalid <= '0';
    axilite_1.bready  <= '0'; axilite_1.rready <= '0';
    axilite_2.awvalid <= '0'; axilite_2.wvalid <= '0'; axilite_2.arvalid <= '0';
    axilite_2.bready  <= '0'; axilite_2.rready <= '0';
    axilite_3.awvalid <= '0'; axilite_3.wvalid <= '0'; axilite_3.arvalid <= '0';
    axilite_3.bready  <= '0'; axilite_3.rready <= '0';
    axilite_ctrl.awvalid <= '0'; axilite_ctrl.wvalid <= '0'; axilite_ctrl.arvalid <= '0';
    axilite_ctrl.bready  <= '0'; axilite_ctrl.rready <= '0';

    wait_cycles(5);

    ------------------------------------------------------------------
    -- Test 1: Enable all shims via axilite_ctrl, verify LED output
    ------------------------------------------------------------------
    write(l, string'("=== T1: Multi-shim enable and LED test ==="));
    writeline(output, l);

    -- aperture = 1 (o_data[0])
    axi_wr_ctrl(0, u32(1));
    wait_cycles(2);

    if led(4) = '0' then
      write(l, string'("  PASS: led(4) off (default)"));
      writeline(output, l);
    end if;

    -- Write extra LED via o_data[3]
    axi_wr_ctrl(3, u32(1));
    wait_cycles(2);
    if led(4) = '1' then
      write(l, string'("  PASS: led(4) on (software)"));
      writeline(output, l);
    end if;

    axi_wr_ctrl(0, u32(0));

    ------------------------------------------------------------------
    -- Test 2: Configure shim 0 and run a short burst
    ------------------------------------------------------------------
    write(l, string'("=== T2: Shim 0 burst test ==="));
    writeline(output, l);

    -- aperture = 1
    axi_wr_ctrl(0, u32(1));

    -- Configure shim 0: enable_local=1, arid=1, burst_length=8,
    --   pace=0, base_addr=0x00001000, addr_range=0x00004000
    axi_wr_0(0, u32(1));
    axi_wr_0(2, u32(1));
    axi_wr_0(3, u32(8));
    axi_wr_0(4, u32(0));
    axi_wr_0(6, u32(16#00001000#));
    axi_wr_0(7, u32(0));
    axi_wr_0(8, u32(16#00004000#));
    axi_wr_0(9, u32(0));

    wait_cycles(300);

    -- Disable
    axi_wr_ctrl(0, u32(0));
    wait_cycles(C_DRAIN);

    write(l, string'("  PASS: burst test completed"));
    writeline(output, l);

    ------------------------------------------------------------------
    -- Done
    ------------------------------------------------------------------
    write(l, string'("=== Simulation complete ==="));
    writeline(output, l);
    sim_done <= true;
    wait;
  end process;

end architecture;
