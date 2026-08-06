-----------------------------------------------------------------------
--Filename         : axi_ar_gen_simple_tb.vhd
--Description      : Simple, hand-editable testbench for axi_ar_gen.
--                   Uses plain signal initialization (defaults in the
--                   declarations) so tests can be added by editing the
--                   sequencer process.  The sequencer is left as a
--                   skeleton -- initial values are set, then it waits
--                   for you to add your own stimulus.
--
--                   Only axi_ar_gen is instantiated; the AR channel is
--                   tapped directly (ar_ready is driven by this TB).
--                   No monitor, no mem_model -- the focus is purely on
--                   the generator's AR output.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity axi_ar_gen_simple_tb is
end entity;

architecture sim of axi_ar_gen_simple_tb is

  constant C_CLK_PERIOD : time    := 10 ns;
  constant C_DATA_BYTES : natural := 16;
  constant C_ADDR_WIDTH : natural := 49;
  constant C_ID_WIDTH   : natural := 6;

  signal aclk     : std_logic := '0';
  signal aresetn  : std_logic := '0';
  signal sim_done : boolean  := false;

  -- Generator control -- initial values
  signal enable   : std_logic := '0';
  signal aperture : std_logic := '1';
  signal stat_rst : std_logic := '0';

  -- Generator config -- initial values
  signal arid       : std_logic_vector(C_ID_WIDTH-1 downto 0) := (others => '0');
  signal ar_length  : std_logic_vector(log2ceil(256)-1 downto 0) := x"0F";  -- 16 beats
  signal pace       : std_logic_vector(31 downto 0) := x"00000000";  -- every cycle
  signal pace_init  : std_logic_vector(31 downto 0) := x"00000000";
  signal base_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0) :=
                          std_logic_vector(to_unsigned(16#1000#, C_ADDR_WIDTH));
  signal addr_range : std_logic_vector(C_ADDR_WIDTH-1 downto 0) :=
                          std_logic_vector(to_unsigned(16#10000#, C_ADDR_WIDTH));
  signal addr_mode  : std_logic := '0';  -- linear

  -- AR channel (gen drives, TB consumes)
  signal ar_valid : std_logic;
  signal ar_ready : std_logic := '1';  -- TB always accepts
  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);
  signal ar_size  : std_logic_vector(2 downto 0);
  signal ar_burst : std_logic_vector(1 downto 0);

  -- Statistics
  signal stat_ar_stall   : std_logic_vector(31 downto 0);
  signal stat_ar_issued  : std_logic_vector(31 downto 0);
  signal stat_cfg_errors : std_logic_vector(31 downto 0);

  procedure wait_cycles(n : natural) is
  begin
    for i in 1 to n loop
      wait until rising_edge(aclk);
    end loop;
  end procedure;

begin

  aclk <= not aclk after C_CLK_PERIOD/2 when not sim_done else '0';

  ---------------------------------------------------------------------
  -- DUT:  axi_ar_gen
  ---------------------------------------------------------------------
  u_dut : entity work.axi_ar_gen
    generic map (
      GC_DATA_BYTES => C_DATA_BYTES,
      GC_ADDR_WIDTH => C_ADDR_WIDTH,
      GC_ID_WIDTH   => C_ID_WIDTH,
      GC_MAX_BURST  => 256
    )
    port map (
      aclk        => aclk,
      aresetn     => aresetn,
      enable      => enable,
      aperture    => aperture,
      stat_rst    => stat_rst,
      arid        => arid,
      ar_length   => ar_length,
      pace        => pace,
      pace_init   => pace_init,
      base_addr   => base_addr,
      addr_range  => addr_range,
      addr_mode   => addr_mode,
      ar_valid    => ar_valid,
      ar_ready    => ar_ready,
      ar_id       => ar_id,
      ar_addr     => ar_addr,
      ar_len      => ar_len,
      ar_size     => ar_size,
      ar_burst    => ar_burst,
      stat_ar_stall   => stat_ar_stall,
      stat_ar_issued  => stat_ar_issued,
      stat_cfg_errors => stat_cfg_errors
    );

  ---------------------------------------------------------------------
  -- Sequencer -- edit here to add tests.  Initial values are set in the
  -- declarations above; this block just applies reset and then waits.
  ---------------------------------------------------------------------
  p_seq : process
    variable l : line;
  begin
    -- Reset
    aresetn    <= '0';
    ar_ready   <= '0';
    enable     <= '1';
    aperture   <= '0';
    stat_rst   <= '0';
    arid       <= "001010";
    ar_length  <= x"01";
    pace       <= x"00000000";
    pace_init  <= x"00000000";
    base_addr  <= 17B"0" & x"00040000";
    addr_range <= 17B"0" & x"00040000";
    addr_mode  <= '1';
    wait_cycles(1);
    aresetn <= '1';
    wait_cycles(1);

    aperture <= '1';
    ar_ready <= '1';
    wait_cycles(2);
    aperture <= '0';

    wait_cycles(2);
    std.env.stop;
    sim_done <= true;
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
