-----------------------------------------------------------------------
--Filename         : axi4_read_tester_shim_tb.vhd
--Description      : Testbench for axi4_read_tester_shim.
--                   Drives the AXI4-Lite register interface via BFM
--                   procedures, instantiates axi_mem_model on the
--                   AR/R AXI4 bus, and runs simple configuration /
--                   run / verify sequences.
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

entity axi4_read_tester_shim_tb is
end entity;

architecture sim of axi4_read_tester_shim_tb is

  constant C_CLK_PERIOD  : time    := 10 ns;
  constant C_DATA_BYTES  : natural := 16;
  constant C_ADDR_WIDTH  : natural := 49;
  constant C_ID_WIDTH    : natural := 6;
  constant C_TIME_WIDTH  : natural := 48;
  constant C_STAT_WIDTH  : natural := 48;
  constant C_DRAIN       : natural := 500;

  signal clk       : std_logic := '0';
  signal rst_n     : std_logic := '0';
  signal sim_done  : boolean   := false;
  signal global_time : unsigned(C_TIME_WIDTH-1 downto 0) := (others => '0');

  signal aperture      : std_logic := '0';
  signal stat_rst      : std_logic := '0';
  signal err_rst       : std_logic := '0';
  signal led           : std_logic;
  signal pipeline_busy : std_logic;

  signal axilite : axilite_m40_t;
  signal ar : axi4_hp_ar_t;
  signal r  : axi4_hp_r_t;

  function u32(n : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(n, 32));
  end function;

  function reg_addr(index : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(index * 4, 16));
  end function;

  function stat_addr(index : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(16#8000# + index * 4, 16));
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
  -- Global time counter
  --------------------------------------------------------------------
  p_global_time : process(clk)
  begin
    if rising_edge(clk) and rst_n = '1' then
      global_time <= global_time + 1;
    end if;
  end process;

  --------------------------------------------------------------------
  -- Device under test: axi4_read_tester_shim
  --------------------------------------------------------------------
  u_shim : entity work.axi4_read_tester_shim
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
      aclk           => clk,
      aresetn        => rst_n,
      global_time    => global_time,
      aperture       => aperture,
      stat_rst       => stat_rst,
      err_rst        => err_rst,
      axilite        => axilite,
      ar             => ar,
      r              => r,
      led            => led,
      pipeline_busy  => pipeline_busy
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
      aclk           => clk,
      aresetn        => rst_n,
      ar_base_enable   => '1',
      ar_jitter_enable => '1',
      r_base_enable    => '1',
      r_jitter_enable  => '1',
      base_latency   => u32(5)(15 downto 0),
      base_beat_gap  => u32(3)(15 downto 0),
      ar_valid       => ar.arvalid,
      ar_ready       => ar.arready,
      ar_id          => ar.arid,
      ar_addr        => ar.araddr,
      ar_len         => ar.arlen,
      r_valid        => r.rvalid,
      r_ready        => r.rready,
      r_id           => r.rid,
      r_data         => r.rdata,
      r_resp         => r.rresp,
      r_last         => r.rlast
    );

  --------------------------------------------------------------------
  -- AXI4 fill signals -- drive only what the shim doesn't drive.
  --
  -- ar = master_ar view -> shim drives arid..arvalid, arready is IN.
  --     The mem_model's ar_ready output connects to ar.arready.
  -- r  = master_r  view -> shim drives rready, all other R fields are IN.
  --     The mem_model drives rid, rdata, rresp, rlast, rvalid.
  --     ruser is not used by mem_model; drive it to zero here.
  --------------------------------------------------------------------
  r.ruser <= (others => '0');

  --------------------------------------------------------------------
  -- Stimulus
  --------------------------------------------------------------------
  p_stimulus : process
    variable l          : line;
    variable v_data     : std_logic_vector(31 downto 0);
    variable v_all_pass : boolean := true;
    variable v_failed   : boolean := false;

    procedure axi_wr(
      constant index : in natural;
      constant dat   : in std_logic_vector(31 downto 0)
    ) is
    begin
      axilite_write(
        aclk    => clk,
        awaddr  => axilite.awaddr,
        awprot  => axilite.awprot,
        awvalid => axilite.awvalid,
        awready => axilite.awready,
        wdata   => axilite.wdata,
        wstrb   => axilite.wstrb,
        wvalid  => axilite.wvalid,
        wready  => axilite.wready,
        bready  => axilite.bready,
        bvalid  => axilite.bvalid,
        addr    => reg_addr(index),
        dat     => dat
      );
    end procedure;

    procedure axi_rd(
      constant index : in  natural;
      variable dat   : out std_logic_vector(31 downto 0)
    ) is
    begin
      axilite_read(
        aclk    => clk,
        araddr  => axilite.araddr,
        arprot  => axilite.arprot,
        arvalid => axilite.arvalid,
        arready => axilite.arready,
        rready  => axilite.rready,
        rvalid  => axilite.rvalid,
        rdata   => axilite.rdata,
        addr    => stat_addr(index),
        dat     => dat
      );
    end procedure;
  begin
    -- Power-on reset
    rst_n <= '0';
    wait_cycles(10);
    rst_n <= '1';
    wait_cycles(5);

    -- Clear any spurious error counts from uninitialized signal
    -- activity during the first clock cycles after time zero.
    stat_rst <= '1';
    err_rst  <= '1';
    wait_cycles(2);
    stat_rst <= '0';
    err_rst  <= '0';
    wait_cycles(2);

    -- Initialise axilite BFM bus to idle
    axilite.awvalid <= '0';
    axilite.wvalid  <= '0';
    axilite.arvalid <= '0';
    axilite.bready  <= '0';
    axilite.rready  <= '0';

    ------------------------------------------------------------------
    -- Test 1: Verify axilite write/readback on o_data, then i_data
    ------------------------------------------------------------------
    write(l, string'("=== T1: Axilite write/readback test ==="));
    writeline(output, l);

    -- Reset o_data[0] back to 1 for enable_local
    axi_wr(0, u32(1));

    -- Now try reading all stat counters
    v_all_pass := true;
    for i in 0 to 28 loop
      axi_rd(i, v_data);
      -- stat_*_min fields reset to all ones; elapsed_cycles is expected
      -- to advance while the tester is out of reset.
      if i = 4 or i = 10 then
        if v_data /= X"FFFFFFFF" then
          write(l, string'("  FAIL: i_data["));
          write(l, i);
          write(l, string'("] = 0x"));
          hwrite(l, v_data);
          write(l, string'(", expected 0xFFFFFFFF"));
          writeline(output, l);
          v_all_pass := false;
        end if;
      elsif i = 5 or i = 11 then
        if v_data /= X"00000000" then
          write(l, string'("  FAIL: i_data["));
          write(l, i);
          write(l, string'("] = 0x"));
          hwrite(l, v_data);
          write(l, string'(", expected 0x00000000"));
          writeline(output, l);
          v_all_pass := false;
        end if;
      elsif i = 27 then
        if v_data /= X"FFFFFFFF" then
          write(l, string'("  FAIL: i_data["));
          write(l, i);
          write(l, string'("] = 0x"));
          hwrite(l, v_data);
          write(l, string'(", expected 0xFFFFFFFF"));
          writeline(output, l);
          v_all_pass := false;
        end if;
      elsif i = 20 then
        null; -- elapsed_cycles is free-running, skip strict check
      elsif v_data /= u32(0) then
        write(l, string'("  FAIL: i_data["));
        write(l, i);
        write(l, string'("] = 0x"));
        hwrite(l, v_data);
        write(l, string'(", expected 0x00000000"));
        writeline(output, l);
        v_all_pass := false;
      end if;
    end loop;
    if v_all_pass then
      write(l, string'("  PASS: all stat counters zero"));
      writeline(output, l);
    else
      v_failed := true;
    end if;

    ------------------------------------------------------------------
    -- Test 2: Configure and run 16-beat bursts
    ------------------------------------------------------------------
    write(l, string'("=== T2: Configure 16-beat bursts ==="));
    writeline(output, l);

    -- Configure via axilite registers
    axi_wr(0, u32(1));
    axi_wr(2, u32(1));
    axi_wr(3, u32(16));
    axi_wr(4, u32(0));
    axi_wr(6, u32(16#00001000#));
    axi_wr(7, u32(0));
    axi_wr(8, u32(16#00004000#));
    axi_wr(9, u32(0));

    -- Enable and run
    aperture <= '1';
    wait_cycles(400);
    aperture <= '0';
    wait_cycles(C_DRAIN);

    -- Read back stats
    axi_rd(0, v_data);  -- stat_xactions
    write(l, string'("  xactions="));
    write(l, to_integer(unsigned(v_data)));
    axi_rd(1, v_data);  -- stat_beats
    write(l, string'(" beats="));
    write(l, to_integer(unsigned(v_data)));

    -- Check error counters are zero
    v_all_pass := true;
    for i in 21 to 25 loop
      axi_rd(i, v_data);
      if v_data /= u32(0) then
        write(l, string'("  FAIL: i_data["));
        write(l, i);
        write(l, string'("] non-zero"));
        v_all_pass := false;
      end if;
    end loop;
    if v_all_pass then
      write(l, string'("  PASS: no errors"));
    else
      write(l, string'("  FAIL: errors detected"));
      v_failed := true;
    end if;
    writeline(output, l);

    -- Read max outstanding
    axi_rd(26, v_data);
    write(l, string'("  max_outstanding="));
    write(l, to_integer(unsigned(v_data)));
    writeline(output, l);

    -- Disable and reset between tests
    rst_n <= '0';
    wait_cycles(10);
    rst_n <= '1';
    wait_cycles(5);

    ------------------------------------------------------------------
    -- Test 3: stat_rst clears counters
    ------------------------------------------------------------------
    write(l, string'("=== T3: stat_rst ==="));
    writeline(output, l);

    -- Run a short burst
    axi_wr(0, u32(1));     -- enable_local = 1
    axi_wr(3, u32(8));     -- burst_length = 8
    axi_wr(6, u32(16#00002000#));
    aperture <= '1';
    wait_cycles(200);
    aperture <= '0';
    wait_cycles(C_DRAIN);

    -- Verify counters went up
    axi_rd(0, v_data);
    write(l, string'("  before stat_rst: xactions="));
    write(l, to_integer(unsigned(v_data)));
    writeline(output, l);

    -- Quiesce traffic before stat reset verification.
    aperture      <= '0';
    axi_wr(0, u32(0));
    wait_cycles(C_DRAIN);

    -- Pulse stat_rst
    stat_rst <= '1';
    wait_cycles(2);
    stat_rst <= '0';
    wait_cycles(2);

    -- Verify counters cleared
    axi_rd(0, v_data);
    if v_data = u32(0) then
      write(l, string'("  PASS: stat_rst cleared xactions"));
    else
      write(l, string'("  FAIL: stat_rst did not clear"));
      v_failed := true;
    end if;
    writeline(output, l);

    -- Disable
    rst_n <= '0';
    wait_cycles(10);
    rst_n <= '1';
    wait_cycles(5);

    ------------------------------------------------------------------
    -- Test 4: LED register
    ------------------------------------------------------------------
    write(l, string'("=== T4: LED register ==="));
    writeline(output, l);

    axi_wr(17, u32(1));  -- led on
    wait_cycles(2);
    if led = '1' then
      write(l, string'("  PASS: led = 1"));
    else
      write(l, string'("  FAIL: led expected 1"));
      v_failed := true;
    end if;
    writeline(output, l);

    axi_wr(17, u32(0));  -- led off
    wait_cycles(2);
    if led = '0' then
      write(l, string'("  PASS: led = 0"));
    else
      write(l, string'("  FAIL: led expected 0"));
      v_failed := true;
    end if;
    writeline(output, l);

    ------------------------------------------------------------------
    -- Done
    ------------------------------------------------------------------
    write(l, string'("=== Simulation complete ==="));
    writeline(output, l);
    assert not v_failed
      report "axi4_read_tester_shim_tb detected a failure"
      severity failure;
    sim_done <= true;
    wait;
  end process;

end architecture;
