-----------------------------------------------------------------------
--Filename         : axi_mem_model_simple_tb.vhd
--Description      : Minimal smoke-test bench for axi_mem_model.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity axi_mem_model_simple_tb is
end entity;

architecture sim of axi_mem_model_simple_tb is

  -- =================================================================
  -- Constants
  -- =================================================================
  constant C_CLK_PERIOD    : time     := 10 ns;
  constant C_ADDR_WIDTH    : positive := 32;
  constant C_ID_WIDTH      : positive := 4;
  constant C_AR_FIFO_DEPTH : positive := 16;
  constant C_TIMER_WIDTH   : positive := 8;

  -- =================================================================
  -- Clock & control
  -- =================================================================
  signal aclk     : std_logic := '1';
  signal aresetn  : std_logic := '0';
  signal sim_done : boolean := false;

  -- =================================================================
  -- AXI4 AR channel
  -- =================================================================
  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0)    := (others => '0');
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0)  := (others => '0');
  signal ar_len   : std_logic_vector(7 downto 0)               := (others => '0');
  signal ar_valid : std_logic := '0';
  signal ar_ready : std_logic;

  -- =================================================================
  -- AXI4 R channel
  -- =================================================================
  signal r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data  : std_logic_vector(255 downto 0);
  signal r_resp  : std_logic_vector(1 downto 0);
  signal r_last  : std_logic;
  signal r_valid : std_logic;
  signal r_ready : std_logic := '1';

  type   t_slv32_arr is array (0 to 7) of std_logic_vector(31 downto 0);
  signal r_words : t_slv32_arr;

  -- =================================================================
  -- Control / enable signals
  -- =================================================================
  signal ar_base_enable   : std_logic := '1';
  signal ar_jitter_enable : std_logic := '1';
  signal r_base_enable    : std_logic := '1';
  signal r_jitter_enable  : std_logic := '1';
  signal base_latency  : std_logic_vector(C_TIMER_WIDTH-1 downto 0) := (others => '0');
  signal base_beat_gap : std_logic_vector(C_TIMER_WIDTH-1 downto 0) := (others => '0');

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
    sig <= '1';                  -- Set the signal high immediately
    wait until rising_edge(clk); -- Wait for the next clock edge
    sig <= '0';                  -- Set it back to low
    
    -- Wait for n clock cycles
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
  -- Slice r_data into 8 x 32-bit words
  -- =================================================================
  r_words(0) <= r_data(31 downto 0);
  r_words(1) <= r_data(63 downto 32);
  r_words(2) <= r_data(95 downto 64);
  r_words(3) <= r_data(127 downto 96);
  r_words(4) <= r_data(159 downto 128);
  r_words(5) <= r_data(191 downto 160);
  r_words(6) <= r_data(223 downto 192);
  r_words(7) <= r_data(255 downto 224);

  -- =================================================================
  -- DUT: axi_mem_model (32-byte bus)
  -- =================================================================
  u_dut : entity work.axi_mem_model
    generic map (
      GC_DATA_BYTES     => 32,
      GC_ADDR_WIDTH     => C_ADDR_WIDTH,
      GC_ID_WIDTH       => C_ID_WIDTH,
      GC_AR_FIFO_DEPTH  => C_AR_FIFO_DEPTH,
      GC_TIMER_WIDTH    => C_TIMER_WIDTH
    )
    port map (
      aclk             => aclk,            -- 100 MHz clock from free-running generator
      aresetn          => aresetn,         -- Active-low reset (5-cycle pulse at start)

      ar_base_enable   => ar_base_enable,  -- AR-side: enables the base latency counter
      ar_jitter_enable => ar_jitter_enable,-- AR-side: enables CDF-based jitter on first beat
      r_base_enable    => r_base_enable,   -- R-side: enables the inter-beat gap counter
      r_jitter_enable  => r_jitter_enable, -- R-side: enables CDF-based jitter on each beat
      base_latency     => base_latency,    -- AR→first-beat delay = 5 cycles
      base_beat_gap    => base_beat_gap,   -- Inter-beat spacing = 3 cycles

      ar_id            => ar_id,           -- Read transaction ID (checked on R channel)
      ar_addr          => ar_addr,         -- Start address for address-derived data
      ar_len           => ar_len,          -- Burst length = 0 → single-beat read
      ar_valid         => ar_valid,        -- Driven high for 1 cycle to launch AR
      ar_ready         => ar_ready,        -- DUT accepts when internal FIFO not full

      r_id             => r_id,            -- Must match the AR ID we sent
      r_data           => r_data,          -- Address-derived data pattern
      r_resp           => r_resp,          -- Expected OKAY (00) for valid reads
      r_last           => r_last,          -- Must be high for single-beat burst
      r_valid          => r_valid,         -- DUT asserts when R beat is available
      r_ready          => r_ready          -- Held high → accept beats immediately
    );

  -- =================================================================
  -- Stimulus process
  -- =================================================================
  process
    variable l : line;
  begin
    aresetn          <= '0';
    ar_base_enable   <= '0';
    ar_jitter_enable <= '0';
    r_base_enable    <= '0';
    r_jitter_enable  <= '0';
    base_latency     <= std_logic_vector(to_unsigned(5, C_TIMER_WIDTH));
    base_beat_gap    <= std_logic_vector(to_unsigned(3, C_TIMER_WIDTH));
    ar_valid         <= '0';
    r_ready          <= '1';
    wait until rising_edge(aclk);
    aresetn          <= '1';
    wait_cycles(aclk, 2);

    ar_len  <= std_logic_vector(to_unsigned(0, 8));
    ar_id   <= x"A";
    ar_addr <= std_logic_vector(to_unsigned(1000, C_ADDR_WIDTH));
    pulse(aclk, ar_valid, 0);

    ar_id   <= x"B";
    ar_addr <= std_logic_vector(to_unsigned(2000, C_ADDR_WIDTH));
    pulse(aclk, ar_valid, 1);

    ar_len  <= std_logic_vector(to_unsigned(7, 8));
    ar_id   <= x"C";
    ar_addr <= std_logic_vector(to_unsigned(3000, C_ADDR_WIDTH));
    pulse(aclk, ar_valid, 0);

    ar_len  <= std_logic_vector(to_unsigned(7, 8));
    ar_id   <= x"D";
    ar_addr <= std_logic_vector(to_unsigned(4000, C_ADDR_WIDTH));
    pulse(aclk, ar_valid, 0);
    wait_cycles(aclk, 25);

    sim_done <= true;
    wait;
  end process;

end architecture;
