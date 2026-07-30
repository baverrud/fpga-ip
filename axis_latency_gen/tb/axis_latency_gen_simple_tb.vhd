-----------------------------------------------------------------------
--Filename         : axis_latency_gen_simple_tb.vhd
--Description      : Simple testbench for axis_latency_gen.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity axis_latency_gen_simple_tb is
end entity;

architecture sim of axis_latency_gen_simple_tb is

  constant C_CLK_PERIOD : time := 10 ns;

  -- ===================================================================
  -- Main DUT (GC_TIMER_WIDTH=32) signals
  -- ===================================================================
  signal aclk              : std_logic := '1';
  signal aresetn           : std_logic := '0';

  signal s_axis_tdata      : std_logic_vector(31 downto 0) := (others => '0');
  signal s_axis_tvalid     : std_logic := '0';
  signal s_axis_tready     : std_logic;

  signal m_axis_tdata      : std_logic_vector(31 downto 0);
  signal m_axis_tvalid     : std_logic;
  signal m_axis_tready     : std_logic := '1';

  signal base_delay        : unsigned(7 downto 0) := to_unsigned(10, 8);
  signal enable_base_delay : std_logic := '1';
  signal enable_jitter     : std_logic := '1';

  -- fifo_count: log2ceil(GC_FIFO_DEPTH) + 1 = 5 bits for depth 16
  signal fifo_count        : unsigned(4 downto 0);

  signal sim_done       : boolean := false;

  -- =================================================================
  -- Full-rate capture signals (for Phase 14 back-to-back verification)
  -- A concurrent process samples m_axis_tdata every cycle where
  -- m_axis_tvalid='1', enabling verification after back-to-back writes.
  -- =================================================================
  type t_slv32_array is array (natural range <>) of std_logic_vector(31 downto 0);
  signal captured_data  : t_slv32_array(0 to 15) := (others => (others => '0'));
  signal captured_cnt   : natural := 0;
  signal capture_done   : std_logic := '0';

  -- -----------------------------------------------------------------
  -- AXI4-Stream Write BFM: drives tdata/tvalid until tready asserts.
  -- Waits one clock cycle for the DUT to sample before releasing valid.
  -- -----------------------------------------------------------------
  procedure axis_write(
    signal   clk    : in  std_logic;
    signal   tdata  : out std_logic_vector;
    signal   tvalid : out std_logic;
    signal   tready : in  std_logic;
    constant data   : in  std_logic_vector
  ) is
  begin
    tdata  <= data;
    tvalid <= '1';
    loop
      wait until rising_edge(clk);
      exit when tready = '1';
    end loop;
    tvalid <= '0';
  end procedure;

  -- -----------------------------------------------------------------
  -- AXI4-Stream Read BFM: asserts tready, captures tdata on valid.
  -- Returns the data word via the `data` out parameter.
  -- -----------------------------------------------------------------
  procedure axis_read(
    signal   clk    : in  std_logic;
    signal   tready : out std_logic;
    signal   tvalid : in  std_logic;
    signal   tdata  : in  std_logic_vector;
    variable data   : out std_logic_vector
  ) is
  begin
    tready <= '1';
    loop
      wait until rising_edge(clk);
      exit when tvalid = '1';
    end loop;
    data := tdata;
    tready <= '0';
  end procedure;

  -- -----------------------------------------------------------------
  -- AXI4-Stream Pop BFM: asserts tready until tvalid, then releases.
  -- Used when only the handshake matters (data content not checked).
  -- -----------------------------------------------------------------
  procedure axis_pop(
    signal   clk    : in  std_logic;
    signal   tready : out std_logic;
    signal   tvalid : in  std_logic
  ) is
  begin
    tready <= '1';
    loop
      wait until rising_edge(clk);
      exit when tvalid = '1';
    end loop;
    tready <= '0';
  end procedure;


  procedure wait_cycles(signal clk : in std_logic; n : in integer) is
  begin
    for i in 1 to n loop
      wait until rising_edge(clk);
    end loop;
  end procedure;


begin

  aclk <= not aclk after C_CLK_PERIOD / 2 when not sim_done else '0';

  -- =================================================================
  -- Main DUT: 32-bit timer width. Used for phases 1-3 and 5-7:
  -- standard delay, burst with backpressure, idle, FIFO full,
  -- in-flight reset, and data ordering. The timer never wraps during
  -- these tests (2^32 cycles >> simulation length).
  -- =================================================================
  u_dut : entity work.axis_latency_gen
    generic map (
      GC_DATA_WIDTH      => 32,
      GC_FIFO_DEPTH      => 16,
      GC_TIMER_WIDTH     => 8,
      GC_JG_JITTER_WIDTH => 8,
      GC_JG_SEED         => x"11111111",
      GC_JG_VAL_0        => 1,
      GC_JG_VAL_1        => 2,
      GC_JG_VAL_2        => 3,
      GC_JG_VAL_3        => 4,

      GC_JG_TH_0         => 128,
      GC_JG_TH_1         => 192,
      GC_JG_TH_2         => 240
    )
    port map (
      aclk              => aclk,
      aresetn           => aresetn,
      s_axis_tdata      => s_axis_tdata,
      s_axis_tvalid     => s_axis_tvalid,
      s_axis_tready     => s_axis_tready,
      m_axis_tdata      => m_axis_tdata,
      m_axis_tvalid     => m_axis_tvalid,
      m_axis_tready     => m_axis_tready,
      base_delay        => base_delay,
      enable_base_delay => enable_base_delay,
      enable_jitter     => enable_jitter,
      fifo_count        => fifo_count
    );




  -- == Test sequence ==
  process
    variable l      : line;
    variable t_sent : time;
    variable t_rcvd : time;
    variable i         : natural;
    variable cnt_rx    : natural;
    variable v_rx_data : std_logic_vector(31 downto 0);
  begin

    aresetn       <= '0';
    s_axis_tdata  <= (others => '0');
    s_axis_tvalid <= '0';
    m_axis_tready <= '1';

    base_delay        <=  to_unsigned(2, 8);
    enable_base_delay <= '0';
    enable_jitter     <= '0';


    wait_cycles(aclk, 2);
    aresetn <= '1';

    for i in 0 to 7 loop
      axis_write(aclk, s_axis_tdata, s_axis_tvalid, s_axis_tready,
                 std_logic_vector(to_unsigned(10#500# + i, 32)));
    end loop;



    
    wait_cycles(aclk, 10);
    -- ============================================================
    -- Done
    -- ============================================================
    write(l, string'("All tests passed.")); writeline(output, l);
    sim_done <= true;
    wait;
  end process;

end architecture;
