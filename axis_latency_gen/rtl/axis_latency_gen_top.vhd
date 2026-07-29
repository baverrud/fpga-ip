-----------------------------------------------------------------------
--Filename         : axis_latency_gen_top.vhd
--Description      : Synthesis wrapper for axis_latency_gen.
--                 : Passes all generics and ports through.
--                 : Converts fifo_count from unconstrained unsigned
--                 : to std_logic_vector for IP integrator compat.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axis_latency_gen_top is
  generic (
    GC_DATA_WIDTH  : positive := 32;
    GC_FIFO_DEPTH  : positive := 16;
    GC_TIMER_WIDTH : positive := 32;

    -- Jitter generator generics (passed to jitter_gen)
    -- PRNG selection: false = xorshift32, true = xorshift128
    GC_USE_XORSHIFT128 : boolean  := false;
    GC_JG_SEED         : std_logic_vector(31 downto 0) := x"DEADBEEF";
    GC_JG_SEED0        : std_logic_vector(63 downto 0) := x"DEADBEEFCAFEBABE";
    GC_JG_SEED1        : std_logic_vector(63 downto 0) := x"0123456789ABCDEF";
    GC_JG_VAL_0        : integer := 0;
    GC_JG_VAL_1        : integer := 1;
    GC_JG_VAL_2        : integer := 3;
    GC_JG_VAL_3        : integer := 7;
    GC_JG_TH_0         : integer := 128;
    GC_JG_TH_1         : integer := 192;
    GC_JG_TH_2         : integer := 240
  );
  port (
    aclk           : in  std_logic;
    aresetn        : in  std_logic;

    s_axis_tdata   : in  std_logic_vector(GC_DATA_WIDTH-1 downto 0);
    s_axis_tvalid  : in  std_logic;
    s_axis_tready  : out std_logic;

    m_axis_tdata   : out std_logic_vector(GC_DATA_WIDTH-1 downto 0);
    m_axis_tvalid  : out std_logic;
    m_axis_tready  : in  std_logic;

    base_delay         : in  std_logic_vector(GC_TIMER_WIDTH-1 downto 0);
    enable_base_delay  : in  std_logic;
    enable_jitter      : in  std_logic;

    fifo_count     : out std_logic_vector(log2ceil(GC_FIFO_DEPTH) downto 0)
  );
end entity;

architecture rtl of axis_latency_gen_top is

  constant C_FC_WIDTH : natural := log2ceil(GC_FIFO_DEPTH);

  signal fc : unsigned(C_FC_WIDTH downto 0);

begin

  u_core : entity work.axis_latency_gen
    generic map (
      GC_DATA_WIDTH      => GC_DATA_WIDTH,
      GC_FIFO_DEPTH      => GC_FIFO_DEPTH,
      GC_TIMER_WIDTH     => GC_TIMER_WIDTH,
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
      aclk           => aclk,
      aresetn        => aresetn,
      s_axis_tdata   => s_axis_tdata,
      s_axis_tvalid  => s_axis_tvalid,
      s_axis_tready  => s_axis_tready,
      m_axis_tdata   => m_axis_tdata,
      m_axis_tvalid  => m_axis_tvalid,
      m_axis_tready  => m_axis_tready,
      base_delay        => unsigned(base_delay),
      enable_base_delay => enable_base_delay,
      enable_jitter     => enable_jitter,
      fifo_count        => fc
    );

  fifo_count <= std_logic_vector(resize(fc, fifo_count'length));

end architecture;
