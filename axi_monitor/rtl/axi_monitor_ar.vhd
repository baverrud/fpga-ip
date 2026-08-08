-----------------------------------------------------------------------
--Filename         : axi_monitor_ar.vhd
--Description      : Passive AXI3/AXI4 Read-Address (AR) channel monitor.
--                   Taps the AR channel (ar_valid/ar_ready are both
--                   inputs -- this block never drives the bus).  On
--                   every ar_valid & ar_ready handshake it captures a
--                   scoreboard descriptor {araddr, arid, timestamp,
--                   arlen} and reports AR-side statistics.
--
--                   Purely combinational tap:  there is NO state
--                   machine, so a transaction cannot be missed.  Every
--                   cycle with a valid handshake is captured and
--                   counted.  The descriptor is presented
--                   combinationally on the same cycle as the handshake.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_monitor_ar is
  generic (
    GC_ADDR_WIDTH : positive := 49;
    GC_ID_WIDTH   : positive := 6;
    GC_TIME_WIDTH : positive := 48
  );
  port (
    aclk        : in  std_logic;
    aresetn     : in  std_logic;
    global_time : in  unsigned(GC_TIME_WIDTH-1 downto 0);

    -- Control
    enable   : in  std_logic;   -- per-instance enable (0 = tap inert)
    stat_rst : in  std_logic;

    -- AR channel taps (all inputs -- passive monitor)
    ar_valid : in  std_logic;
    ar_ready : in  std_logic;
    ar_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : in  std_logic_vector(7 downto 0);   -- beats-1

    -- Scoreboard push (one descriptor per burst)
    sb_tdata  : out std_logic_vector(GC_ADDR_WIDTH + GC_ID_WIDTH + GC_TIME_WIDTH + 8 - 1 downto 0);
    sb_tvalid : out std_logic;
    sb_tready : in  std_logic;

    -- Statistics
    stat_ar_seen         : out std_logic_vector(31 downto 0);
    stat_ar_stall        : out std_logic_vector(31 downto 0);
    stat_sb_backpressure : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of axi_monitor_ar is

  -- Scoreboard field positions -- must match axi_monitor_r packing order.
  -- Entry format (MSB to LSB):  {araddr, arid, timestamp, arlen}
  constant C_BEATS_LOW  : natural := 0;
  constant C_BEATS_HIGH : natural := 7;
  constant C_TS_LOW     : natural := C_BEATS_HIGH + 1;
  constant C_TS_HIGH    : natural := C_TS_LOW + GC_TIME_WIDTH - 1;
  constant C_ID_LOW     : natural := C_TS_HIGH + 1;
  constant C_ID_HIGH    : natural := C_ID_LOW + GC_ID_WIDTH - 1;
  constant C_ADDR_LOW   : natural := C_ID_HIGH + 1;
  constant C_ADDR_HIGH  : natural := C_ADDR_LOW + GC_ADDR_WIDTH - 1;

  -- State record -- the three AR-side counters.
  type rec_t is record
    ar_seen   : unsigned(31 downto 0);  -- AR handshakes counted
    ar_stall  : unsigned(31 downto 0);  -- valid-not-ready cycles
    sb_bp_cnt : unsigned(31 downto 0);  -- handshakes with FIFO full
  end record;

  constant C_DEFAULT : rec_t := (
    ar_seen   => (others => '0'),
    ar_stall  => (others => '0'),
    sb_bp_cnt => (others => '0')
  );

  signal r    : rec_t := C_DEFAULT;  -- current state (registered)
  signal r_in : rec_t;               -- next state (combinational output)

begin

  ---------------------------------------------------------------------
  -- Combinational descriptor capture -- same cycle as the handshake.
  -- Gated by enable:  when the instance is disabled, no descriptor is
  -- pushed (and the R monitor, disabled in lock-step, stops consuming).
  ---------------------------------------------------------------------
  sb_tdata(C_ADDR_HIGH downto C_ADDR_LOW) <= ar_addr;
  sb_tdata(C_ID_HIGH downto C_ID_LOW)     <= ar_id;
  sb_tdata(C_TS_HIGH downto C_TS_LOW)     <= std_logic_vector(global_time);
  sb_tdata(C_BEATS_HIGH downto C_BEATS_LOW) <= ar_len;
  sb_tvalid <= ar_valid and ar_ready and enable;

  ---------------------------------------------------------------------
  -- Combinational process -- computes next counter state.
  -- Every AR handshake is counted; a stalled-valid cycle (ar_valid=1,
  -- ar_ready=0) is counted separately.  A handshake while the
  -- scoreboard FIFO is full (sb_tready=0) is recorded as backpressure
  -- (the corresponding R beats will report as underflow downstream).
  -- All counters are gated by enable only:  the tap counts every
  -- handshake while the instance is enabled.  Aperture is a generator
  -- concept (see axi_ar_gen) and does not reach the monitor.
  ---------------------------------------------------------------------
  p_comb : process(all)
    variable v : rec_t;
  begin
    v := r;  -- recover current state as default for all fields

    if enable = '1' then
      if ar_valid = '1' and ar_ready = '1' then
        v.ar_seen := r.ar_seen + 1;
        if sb_tready = '0' then
          v.sb_bp_cnt := r.sb_bp_cnt + 1;
        end if;
      elsif ar_valid = '1' and ar_ready = '0' then
        v.ar_stall := r.ar_stall + 1;
      end if;
    end if;

    -- stat_rst takes priority:  override the counters at the end so a
    -- coincident handshake cannot resurrect them.  Reset values are
    -- single-sourced from C_DEFAULT.
    if stat_rst = '1' then
      v.ar_seen   := C_DEFAULT.ar_seen;
      v.ar_stall  := C_DEFAULT.ar_stall;
      v.sb_bp_cnt := C_DEFAULT.sb_bp_cnt;
    end if;

    r_in <= v;  -- latch next state
  end process p_comb;

  ---------------------------------------------------------------------
  -- Register process -- updates state on rising clock edge.
  ---------------------------------------------------------------------
  p_reg : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        r <= C_DEFAULT;
      else
        r <= r_in;
      end if;
    end if;
  end process p_reg;

  stat_ar_seen         <= std_logic_vector(r.ar_seen);
  stat_ar_stall        <= std_logic_vector(r.ar_stall);
  stat_sb_backpressure <= std_logic_vector(r.sb_bp_cnt);

end architecture;
