-----------------------------------------------------------------------
--Filename         : axis_latency_gen.vhd
--Description      : AXI-Stream latency generator with configurable
--                 : base delay and per-entry CDF-based jitter.
--                 : Stores {tdata, t_departure} in a single wider
--                 : axis_fifo. Departure decided at entry time.
--                 : Timer wrap handled by signed subtraction.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axis_latency_gen is
  generic (
    -- Data path width
    GC_DATA_WIDTH : positive := 32;
    -- FIFO depth (entries)
    GC_FIFO_DEPTH : positive := 16;
    -- Width of internal timer and base_delay port
    GC_TIMER_WIDTH : positive := 32;

    -- Jitter generator generics (passed through to jitter_gen)
    -- Jitter output width (default matches jitter_gen's GC_JITTER_WIDTH)
    GC_JG_JITTER_WIDTH : positive := 8;
    -- PRNG selection: false = xorshift32, true = xorshift128
    GC_USE_XORSHIFT128 : boolean := false;
    -- PRNG seeds (xorshift32 uses GC_JG_SEED; xorshift128 uses GC_JG_SEED0/1)
    GC_JG_SEED  : std_logic_vector(31 downto 0) := x"DEADBEEF";
    GC_JG_SEED0 : std_logic_vector(63 downto 0) := x"DEADBEEFCAFEBABE";
    GC_JG_SEED1 : std_logic_vector(63 downto 0) := x"0123456789ABCDEF";
    -- 4 target jitter values
    GC_JG_VAL_0 : integer := 0;
    GC_JG_VAL_1 : integer := 1;
    GC_JG_VAL_2 : integer := 3;
    GC_JG_VAL_3 : integer := 7;
    -- 3 cumulative thresholds (8-bit, strictly ascending, 0..255)
    GC_JG_TH_0 : integer := 128;
    GC_JG_TH_1 : integer := 192;
    GC_JG_TH_2 : integer := 240
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Slave AXI-Stream
    s_axis_tdata  : in  std_logic_vector(GC_DATA_WIDTH-1 downto 0);
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;

    -- Master AXI-Stream
    m_axis_tdata  : out std_logic_vector(GC_DATA_WIDTH-1 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;

    -- Configuration
    base_delay        : in unsigned(GC_TIMER_WIDTH-1 downto 0);
    enable_base_delay : in std_logic;
    enable_jitter     : in std_logic;

    -- Status
    fifo_count : out unsigned(log2ceil(GC_FIFO_DEPTH) downto 0)
  );
end entity;

architecture rtl of axis_latency_gen is

  -- -----------------------------------------------------------------
  -- Free-running cycle counter
  -- -----------------------------------------------------------------
  signal timer : unsigned(GC_TIMER_WIDTH-1 downto 0) := (others => '0');

  -- -----------------------------------------------------------------
  -- Wider FIFO: stores {s_axis_tdata, t_departure}
  -- -----------------------------------------------------------------
  constant C_FIFO_WIDTH : positive := GC_DATA_WIDTH + GC_TIMER_WIDTH;

  signal tf_data  : std_logic_vector(C_FIFO_WIDTH-1 downto 0);
  signal tf_valid : std_logic;
  signal tf_ready : std_logic;
  signal ff_data  : std_logic_vector(C_FIFO_WIDTH-1 downto 0);
  signal ff_valid : std_logic;
  signal ff_ready : std_logic;

  -- Split view of FIFO output
  signal ff_tdata       : std_logic_vector(GC_DATA_WIDTH-1 downto 0);
  signal ff_t_departure : unsigned(GC_TIMER_WIDTH-1 downto 0);

  -- -----------------------------------------------------------------
  -- Jitter generator
  -- -----------------------------------------------------------------
  signal jg_step   : std_logic;
  signal jg_jitter : unsigned(GC_JG_JITTER_WIDTH-1 downto 0);

  -- -----------------------------------------------------------------
  -- Write-side computed departure time
  -- -----------------------------------------------------------------
  signal t_departure : unsigned(GC_TIMER_WIDTH-1 downto 0);

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
  --   timer = 251, t_departure = 4
  --   251 - 4 = 247 = 0xF7 = -9 as signed(8)
  --   Negative means "not yet", so the entry waits through rollover.
  --
  -- Do NOT zero-extend before subtracting:
  --   signed('0' & 251) - signed('0' & 4) = +247
  -- which would incorrectly release before the timer wraps.
  --
  -- This elapsed-time test is valid when the maximum configured delay is
  -- below half the timer range: base_delay + jitter < 2^(N-1).
  --
  -- Computed as a single self-contained expression (no intermediate
  -- combinational signal): a cross-concurrent-assignment read on the
  -- shared ff_valid is a VHDL delta race.
  -- -----------------------------------------------------------------
  signal time_arrived : std_logic;

begin

  -- ================================================================
  -- Free-running cycle counter
  -- ================================================================
  process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        timer <= (others => '0');
      else
        timer <= timer + 1;
      end if;
    end if;
  end process;

  -- ================================================================
  -- Jitter generator (stepped on each incoming transfer)
  -- ================================================================
  u_jitter_gen : entity work.jitter_gen
    generic map (
      -- Jitter output width
      GC_JITTER_WIDTH => GC_JG_JITTER_WIDTH,
      -- PRNG selection: false = xorshift32, true = xorshift128
      GC_USE_XORSHIFT128 => GC_USE_XORSHIFT128,
      -- PRNG seeds
      GC_SEED  => GC_JG_SEED,
      GC_SEED0 => GC_JG_SEED0,
      GC_SEED1 => GC_JG_SEED1,
      -- 4 target jitter values
      GC_VAL_0 => GC_JG_VAL_0,
      GC_VAL_1 => GC_JG_VAL_1,
      GC_VAL_2 => GC_JG_VAL_2,
      GC_VAL_3 => GC_JG_VAL_3,
      -- 3 cumulative thresholds (8-bit, strictly ascending, 0..255)
      GC_TH_0 => GC_JG_TH_0,
      GC_TH_1 => GC_JG_TH_1,
      GC_TH_2 => GC_JG_TH_2
    )
    port map (
      -- Clock & reset
      clk  => aclk,
      rstn => aresetn,
      -- Step pulse: advance PRNG and update jitter register on each
      -- accepted write. Because jitter_gen is clocked, the updated
      -- sample is visible after this edge (used by the next write).
      step => jg_step,
      -- Enable: gated by enable_jitter port
      enable => enable_jitter,
      -- Output jitter value
      jitter => jg_jitter
    );

  -- ================================================================
  -- Write side: compute t_departure and push into FIFO
  -- ================================================================
  jg_step        <= s_axis_tvalid and tf_ready;
  -- Jitter timing semantics:
  --   * The current write uses the currently visible jg_jitter value.
  --   * jg_step='1' on this write updates jitter_gen's register on the
  --     same rising edge, so that new sample is used by the next write.
  --   * Result: jitter contribution is intentionally one accepted write
  --     delayed. The first accepted write after reset uses jitter=0.
  -- t_departure = timer + 1 (FWFT pipeline) + base_delay (gated) + jitter
  -- The +1 accounts for the axis_fifo's registered output: an entry written
  -- at timer=T appears at the FIFO output at timer=T+1. Without it, a
  -- base_delay of N would be consumed by the pipeline (timer advancing
  -- during the pipeline cycle) and the observed latency would be N rather
  -- than N+1. With the +1, base_delay maps directly to added cycles on
  -- top of the pipeline floor: base_delay=0 + enables low = 1 cycle,
  -- base_delay=1 = 2 cycles, etc.
  -- Minimum observed latency is 1 cycle (FIFO pipeline alone).
  p_departure : process (all)
  begin
    if enable_base_delay = '1' then
      t_departure <= timer + 1 + base_delay + resize(jg_jitter, GC_TIMER_WIDTH);
    else
      t_departure <= timer + 1 + resize(jg_jitter, GC_TIMER_WIDTH);
    end if;
  end process;

  tf_data        <= s_axis_tdata & std_logic_vector(t_departure);
  tf_valid       <= s_axis_tvalid;

  s_axis_tready  <= tf_ready;

  -- ================================================================
  -- Axis FIFO (wider: data + timestamp)
  -- ================================================================
  u_fifo : entity work.axis_fifo
    generic map (
      -- FIFO width = data + timestamp packed together
      GC_TDATA_WIDTH => C_FIFO_WIDTH,
      -- FIFO depth
      GC_FIFO_DEPTH => GC_FIFO_DEPTH
    )
    port map (
      -- Clock & reset
      aclk    => aclk,
      aresetn => aresetn,
      -- Slave (write) side: {tdata, t_departure} packed
      s_axis_tdata  => tf_data,
      s_axis_tvalid => tf_valid,
      s_axis_tready => tf_ready,
      -- Master (read) side: {tdata, t_departure} unpacked
      m_axis_tdata  => ff_data,
      m_axis_tvalid => ff_valid,
      m_axis_tready => ff_ready,
      -- FIFO occupancy
      fifo_count => fifo_count
    );

  ff_tdata       <= ff_data(C_FIFO_WIDTH-1 downto GC_TIMER_WIDTH);
  ff_t_departure <= unsigned(ff_data(GC_TIMER_WIDTH-1 downto 0));

  -- ================================================================
  -- Read side: release when time has arrived
  -- ================================================================
  time_arrived <= '1' when (ff_valid = '1') and
                          (signed(timer - ff_t_departure) >= 0) else '0';

  -- Pop FIFO when: entry available, time has arrived, downstream ready
  ff_ready       <= time_arrived and m_axis_tready;

  m_axis_tdata   <= ff_tdata;
  m_axis_tvalid  <= time_arrived;

end architecture;
