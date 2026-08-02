-----------------------------------------------------------------------
--Filename         : axi_read_tester_reg_tb.vhd
--Description      : VHDL-2008 testbench for axi_read_tester_reg.
--                   Drives the flat AXI4-Lite port with axilite_bfm_pkg,
--                   connects axi_mem_model to the flat AXI4 AR/R ports,
--                   and runs a realistic 1000-cycle traffic window.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;
use work.axilite_bfm_pkg.all;

entity axi_read_tester_reg_tb is
end entity;

architecture sim of axi_read_tester_reg_tb is

  constant C_CLK_PERIOD : time    := 10 ns;
  constant C_DATA_BYTES : natural := 16;
  constant C_ADDR_WIDTH : natural := 49;
  constant C_ID_WIDTH   : natural := 6;
  constant C_TIME_WIDTH : natural := 48;
  constant C_RUN_CYCLES : natural := 1000;
  constant C_DRAIN_CYCLES : natural := 5000;

  signal clk      : std_logic := '0';
  signal rst_n    : std_logic := '0';
  signal sim_done : boolean := false;

  signal global_time : unsigned(C_TIME_WIDTH-1 downto 0) := (others => '0');
  signal enable_global : std_logic := '0';
  signal aperture      : std_logic := '0';
  signal stat_rst      : std_logic := '0';
  signal err_rst       : std_logic := '0';
  signal led           : std_logic;

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

  -- Flat AXI4 read-address channel.
  signal ar_id     : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr   : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len    : std_logic_vector(7 downto 0);
  signal ar_valid  : std_logic;
  signal ar_ready  : std_logic;

  -- Flat AXI4 read-data channel.
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

  function reg_addr(index : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(index * 4, 16));
  end function;

  function i_data_addr(index : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(16#8000# + index * 4, 16));
  end function;

begin

  clk <= not clk after C_CLK_PERIOD / 2 when not sim_done else '0';

  p_global_time : process(clk)
  begin
    if rising_edge(clk) and rst_n = '1' then
      global_time <= global_time + 1;
    end if;
  end process;

  u_dut : entity work.axi_read_tester_reg
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_TIME_WIDTH    => C_TIME_WIDTH,
      GC_STAT_WIDTH    => 48,
      GC_SB_FIFO_DEPTH => 256
    )
    port map (
      aclk           => clk,
      aresetn        => rst_n,
      global_time    => std_logic_vector(global_time),
      enable_global  => enable_global,
      aperture       => aperture,
      stat_rst       => stat_rst,
      err_rst        => err_rst,
      led            => led,
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
      ar_id           => ar_id,
      ar_addr         => ar_addr,
      ar_len          => ar_len,
      ar_size         => open,
      ar_burst        => open,
      ar_lock         => open,
      ar_cache        => open,
      ar_prot         => open,
      ar_qos          => open,
      ar_region       => open,
      ar_user         => open,
      ar_valid        => ar_valid,
      ar_ready        => ar_ready,
      r_id            => r_id,
      r_data          => r_data,
      r_resp          => r_resp,
      r_last          => r_last,
      r_user          => (others => '0'),
      r_valid         => r_valid,
      r_ready         => r_ready
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
    variable data : std_logic_vector(31 downto 0);
    variable xactions : natural;
    variable beats : natural;

    procedure write_reg(
      constant index : in natural;
      constant value : in std_logic_vector(31 downto 0)
    ) is
    begin
      axilite_write(
        clk, axilite_awaddr, axilite_awprot, axilite_awvalid, axilite_awready,
        axilite_wdata, axilite_wstrb, axilite_wvalid, axilite_wready,
        axilite_bready, axilite_bvalid, reg_addr(index), value
      );
    end procedure;

    procedure read_reg(
      constant address : in std_logic_vector(15 downto 0);
      variable value   : out std_logic_vector(31 downto 0)
    ) is
    begin
      axilite_read(
        clk, axilite_araddr, axilite_arprot, axilite_arvalid, axilite_arready,
        axilite_rready, axilite_rvalid, axilite_rdata, address, value
      );
    end procedure;

  begin
    report "=== axi_read_tester_reg: flat-port 1000-cycle run ===" severity note;

    rst_n <= '0';
    wait_cycles(clk, 10);
    rst_n <= '1';
    wait_cycles(clk, 5);

    stat_rst <= '1';
    err_rst  <= '1';
    wait_cycles(clk, 2);
    stat_rst <= '0';
    err_rst  <= '0';
    wait_cycles(clk, 2);

    -- Configure 16-beat reads over a 64 KiB address window.
    write_reg(0, u32(1));
    write_reg(2, u32(1));
    write_reg(3, u32(16));
    write_reg(4, u32(2));
    write_reg(5, u32(5));
    write_reg(6, x"00001000");
    write_reg(8, x"00010000");

    enable_global <= '1';
    aperture      <= '1';
    wait_cycles(clk, C_RUN_CYCLES);

    read_reg(i_data_addr(1), data);
    assert data(0) = '1'
      report "aperture readback was not asserted during the run"
      severity error;

    enable_global <= '0';
    aperture      <= '0';
    wait_cycles(clk, C_DRAIN_CYCLES);

    read_reg(i_data_addr(0), data);
    assert data(0) = '0'
      report "pipeline_busy did not clear after the drain window"
      severity error;

    read_reg(i_data_addr(2), data);
    xactions := to_integer(unsigned(data));
    assert xactions > 0
      report "no read transactions were observed"
      severity error;

    read_reg(i_data_addr(3), data);
    beats := to_integer(unsigned(data));
    assert beats > xactions
      report "read beat count did not exceed transaction count"
      severity error;

    for index in 23 to 27 loop
      read_reg(i_data_addr(index), data);
      assert data = x"00000000"
        report "an AXI read error counter was non-zero"
        severity error;
    end loop;

    report "PASS: transactions=" & integer'image(xactions) &
           ", beats=" & integer'image(beats)
      severity note;

    sim_done <= true;
    wait;
  end process;

end architecture;
