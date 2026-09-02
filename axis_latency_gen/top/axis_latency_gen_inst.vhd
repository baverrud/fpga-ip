-----------------------------------------------------------------------
--Filename         : axis_latency_gen_inst.vhd
--Description      : Instantiation template for axis_latency_gen_top.
--                 : Passes all generics and ports through.
--                 : Converts fifo_count from unconstrained unsigned
--                 : to std_logic_vector for IP integrator compat.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axis_latency_gen_inst is
  generic (
    -- Data path
    -- Data path width (bits)
    GC_DATA_WIDTH : positive := 32;
    -- FIFO depth (entries)
    GC_FIFO_DEPTH : positive range 2 to positive'high := 16;
    -- Width of internal timer and base_delay port (bits)
    GC_TIMER_WIDTH : positive := 32;

    -- Jitter generator (passed through to jitter_gen)
    -- Jitter output width (default matches jitter_gen's GC_JITTER_WIDTH)
    GC_JG_JITTER_WIDTH : positive := 8;
    -- PRNG selection: false = xorshift32, true = xorshift128
    GC_USE_XORSHIFT128 : boolean := false;
    -- PRNG seeds (xorshift32 uses GC_JG_SEED; xorshift128 uses GC_JG_SEED0/1)
    GC_JG_SEED  : std_logic_vector(31 downto 0) := x"DEADBEEF";
    GC_JG_SEED0 : std_logic_vector(63 downto 0) := x"DEADBEEFCAFEBABE";
    GC_JG_SEED1 : std_logic_vector(63 downto 0) := x"0123456789ABCDEF";
    -- 4 target jitter values (applied with CDF probabilities below)
    GC_JG_VAL_0 : integer := 0;
    GC_JG_VAL_1 : integer := 1;
    GC_JG_VAL_2 : integer := 3;
    GC_JG_VAL_3 : integer := 7;
    -- 3 cumulative thresholds (8-bit, strictly ascending, range 0..255)
    GC_JG_TH_0 : integer := 128;
    GC_JG_TH_1 : integer := 192;
    GC_JG_TH_2 : integer := 240
  );
end entity;

architecture rtl of axis_latency_gen_inst is

  signal aclk : std_logic;
  signal aresetn : std_logic;
  signal s_axis_tdata : std_logic_vector(GC_DATA_WIDTH-1 downto 0);
  signal s_axis_tvalid : std_logic;
  signal s_axis_tready : std_logic;
  signal m_axis_tdata : std_logic_vector(GC_DATA_WIDTH-1 downto 0);
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic;
  signal base_delay : std_logic_vector(GC_TIMER_WIDTH-1 downto 0);
  signal enable_base_delay : std_logic;
  signal enable_jitter : std_logic;
  signal fifo_count : std_logic_vector(log2ceil(GC_FIFO_DEPTH) downto 0);

  constant C_FC_WIDTH : natural := log2ceil(GC_FIFO_DEPTH);

  signal fc : unsigned(C_FC_WIDTH downto 0);

begin

  u_core : entity work.axis_latency_gen
    generic map (
      GC_DATA_WIDTH      => GC_DATA_WIDTH,
      GC_FIFO_DEPTH      => GC_FIFO_DEPTH,
      GC_TIMER_WIDTH     => GC_TIMER_WIDTH,
      GC_JG_JITTER_WIDTH => GC_JG_JITTER_WIDTH,
      GC_USE_XORSHIFT128 => GC_USE_XORSHIFT128,
      GC_JG_SEED         => GC_JG_SEED,
      GC_JG_SEED0        => GC_JG_SEED0,
      GC_JG_SEED1        => GC_JG_SEED1,
      GC_JG_VAL_0        => GC_JG_VAL_0,
      GC_JG_VAL_1        => GC_JG_VAL_1,
      GC_JG_VAL_2        => GC_JG_VAL_2,
      GC_JG_VAL_3        => GC_JG_VAL_3,
      GC_JG_TH_0         => GC_JG_TH_0,
      GC_JG_TH_1         => GC_JG_TH_1,
      GC_JG_TH_2         => GC_JG_TH_2
    )
    port map (
      -- Clock and reset
      aclk    => aclk,
      aresetn => aresetn,

      -- Slave AXI4-Stream interface
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,

      -- Master AXI4-Stream interface
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,

      -- Delay and jitter controls
      base_delay        => unsigned(base_delay),
      enable_base_delay => enable_base_delay,
      enable_jitter     => enable_jitter,

      -- FIFO occupancy
      fifo_count => fc
    );

  fifo_count <= std_logic_vector(resize(fc, fifo_count'length));

end architecture;
