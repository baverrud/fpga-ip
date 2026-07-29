-----------------------------------------------------------------------
--Filename         : axis_latency_gen.vhd
--Description      : AXI-Stream latency generator with configurable
--                 : base delay and per-entry CDF-based jitter.
--                 : Stores {tdata, t_departure} in a single wider
--                 : axis_fifo. Departure decided at entry time.
--                 : Timer wrap handled by signed subtraction.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axis_latency_gen is
  generic (
    GC_DATA_WIDTH  : positive := 32;
    GC_FIFO_DEPTH  : positive := 16;
    GC_TIMER_WIDTH : positive := 32;

    -- Jitter generator generics (passed to jitter_gen)
    GC_JG_SEED     : std_logic_vector(31 downto 0) := x"DEADBEEF";
    GC_JG_SEED0    : std_logic_vector(63 downto 0) := x"DEADBEEFCAFEBABE";
    GC_JG_SEED1    : std_logic_vector(63 downto 0) := x"0123456789ABCDEF";
    GC_JG_VAL_0    : integer := 0;
    GC_JG_VAL_1    : integer := 1;
    GC_JG_VAL_2    : integer := 5;
    GC_JG_VAL_3    : integer := 20;
    GC_JG_TH_0     : integer := 128;
    GC_JG_TH_1     : integer := 192;
    GC_JG_TH_2     : integer := 240
  );
  port (
    aclk           : in  std_logic;
    aresetn        : in  std_logic;

    -- Slave AXI-Stream
    s_axis_tdata   : in  std_logic_vector(GC_DATA_WIDTH-1 downto 0);
    s_axis_tvalid  : in  std_logic;
    s_axis_tready  : out std_logic;

    -- Master AXI-Stream
    m_axis_tdata   : out std_logic_vector(GC_DATA_WIDTH-1 downto 0);
    m_axis_tvalid  : out std_logic;
    m_axis_tready  : in  std_logic;

    -- Configuration
    base_delay     : in  unsigned(GC_TIMER_WIDTH-1 downto 0);

    -- Status
    fifo_count     : out unsigned(log2ceil(GC_FIFO_DEPTH) downto 0)
  );
end entity;

architecture rtl of axis_latency_gen is

  -- -----------------------------------------------------------------
  -- Global free-running timer
  -- -----------------------------------------------------------------
  signal global_timer : unsigned(GC_TIMER_WIDTH-1 downto 0) := (others => '0');

  -- -----------------------------------------------------------------
  -- Wider FIFO: stores {s_axis_tdata, t_departure}
  -- -----------------------------------------------------------------
  constant C_FIFO_WIDTH : positive := GC_DATA_WIDTH + GC_TIMER_WIDTH;

  signal tf_data         : std_logic_vector(C_FIFO_WIDTH-1 downto 0);
  signal tf_valid        : std_logic;
  signal tf_ready        : std_logic;
  signal ff_data         : std_logic_vector(C_FIFO_WIDTH-1 downto 0);
  signal ff_valid        : std_logic;
  signal ff_ready        : std_logic;

  -- Split view of FIFO output
  signal ff_tdata        : std_logic_vector(GC_DATA_WIDTH-1 downto 0);
  signal ff_t_departure  : unsigned(GC_TIMER_WIDTH-1 downto 0);

  -- -----------------------------------------------------------------
  -- Jitter generator
  -- -----------------------------------------------------------------
  signal jg_step         : std_logic;
  signal jg_jitter       : unsigned(15 downto 0);  -- GC_JITTER_WIDTH=16

  -- -----------------------------------------------------------------
  -- Write-side computed departure time
  -- -----------------------------------------------------------------
  signal t_departure     : unsigned(GC_TIMER_WIDTH-1 downto 0);

  -- -----------------------------------------------------------------
  -- Read-side modular time difference for wrap-safe comparison.
  --
  -- The subtraction must stay GC_TIMER_WIDTH wide so it wraps exactly
  -- like the timer. The subtractor bits are the same whether viewed as
  -- unsigned or signed; the important part is the interpretation of the
  -- MSB:
  --   MSB = 1 -> signed result is negative -> departure is in future
  --   MSB = 0 -> signed result is >= 0     -> departure has arrived
  --
  -- Example with an 8-bit timer:
  --   global_timer = 251, t_departure = 4
  --   251 - 4 = 247 = 0xF7 = -9 as signed(8)
  --   Negative means "not yet", so the entry waits through rollover.
  --
  -- Do NOT zero-extend before subtracting:
  --   signed('0' & 251) - signed('0' & 4) = +247
  -- which would incorrectly release before the timer wraps.
  --
  -- This elapsed-time test is valid when the maximum configured delay is
  -- below half the timer range: base_delay + jitter < 2^(N-1).
  -- -----------------------------------------------------------------
  signal v_time_diff     : signed(GC_TIMER_WIDTH-1 downto 0) := (others => '0');
  signal time_arrived    : std_logic;

begin

  -- ================================================================
  -- Global timer
  -- ================================================================
  process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        global_timer <= (others => '0');
      else
        global_timer <= global_timer + 1;
      end if;
    end if;
  end process;

  -- ================================================================
  -- Jitter generator (stepped on each incoming transfer)
  -- ================================================================
  u_jitter_gen : entity work.jitter_gen
    generic map (
      GC_JITTER_WIDTH => 16,
      GC_SEED  => GC_JG_SEED,
      GC_SEED0 => GC_JG_SEED0,
      GC_SEED1 => GC_JG_SEED1,
      GC_VAL_0 => GC_JG_VAL_0, GC_VAL_1 => GC_JG_VAL_1,
      GC_VAL_2 => GC_JG_VAL_2, GC_VAL_3 => GC_JG_VAL_3,
      GC_TH_0  => GC_JG_TH_0,  GC_TH_1  => GC_JG_TH_1,
      GC_TH_2  => GC_JG_TH_2
    )
    port map (
      clk    => aclk,
      rstn   => aresetn,
      step   => jg_step,
      enable => '1',
      jitter => jg_jitter
    );

  -- ================================================================
  -- Write side: compute t_departure and push into FIFO
  -- ================================================================
  jg_step        <= s_axis_tvalid and tf_ready;
  t_departure    <= global_timer + base_delay + resize(jg_jitter, GC_TIMER_WIDTH);

  tf_data        <= s_axis_tdata & std_logic_vector(t_departure);
  tf_valid       <= s_axis_tvalid;

  s_axis_tready  <= tf_ready;

  -- ================================================================
  -- Axis FIFO (wider: data + timestamp)
  -- ================================================================
  u_fifo : entity work.axis_fifo
    generic map (
      GC_TDATA_WIDTH => C_FIFO_WIDTH,
      GC_DATA_DEPTH  => GC_FIFO_DEPTH
    )
    port map (
      aclk           => aclk,
      aresetn        => aresetn,
      s_axis_tdata   => tf_data,
      s_axis_tvalid  => tf_valid,
      s_axis_tready  => tf_ready,
      m_axis_tdata   => ff_data,
      m_axis_tvalid  => ff_valid,
      m_axis_tready  => ff_ready,
      fifo_count     => fifo_count
    );

  ff_tdata       <= ff_data(C_FIFO_WIDTH-1 downto GC_TIMER_WIDTH);
  ff_t_departure <= unsigned(ff_data(GC_TIMER_WIDTH-1 downto 0));

  -- ================================================================
  -- Read side: release when time has arrived
  -- ================================================================
  v_time_diff  <= signed(global_timer - ff_t_departure) when ff_valid = '1' else
                  (others => '0');
  time_arrived <= '1' when (ff_valid = '1') and (v_time_diff >= 0) else '0';

  -- Pop FIFO when: entry available, time has arrived, downstream ready
  ff_ready       <= time_arrived and m_axis_tready;

  m_axis_tdata   <= ff_tdata;
  m_axis_tvalid  <= time_arrived;

end architecture;
