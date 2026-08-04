-----------------------------------------------------------------------
--Filename         : axi_monitor_ar.vhd
--Description      : Passive AXI4 Read-Address (AR) channel monitor.
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
    aperture : in  std_logic;   -- measurement window
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

  signal ar_seen    : unsigned(31 downto 0) := (others => '0');
  signal ar_stall   : unsigned(31 downto 0) := (others => '0');
  signal sb_bp_cnt  : unsigned(31 downto 0) := (others => '0');

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
  -- Counter process -- single clocked process (simple counters only).
  -- Every AR handshake is counted; a stalled-valid cycle (ar_valid=1,
  -- ar_ready=0) is counted separately.  A handshake while the
  -- scoreboard FIFO is full (sb_tready=0) is recorded as backpressure
  -- (the corresponding R beats will report as underflow downstream).
  ---------------------------------------------------------------------
  p_counters : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        ar_seen   <= (others => '0');
        ar_stall  <= (others => '0');
        sb_bp_cnt <= (others => '0');
      elsif stat_rst = '1' then
        ar_seen   <= (others => '0');
        ar_stall  <= (others => '0');
        sb_bp_cnt <= (others => '0');
      else
        if enable = '1' and aperture = '1' then
          if ar_valid = '1' and ar_ready = '1' then
            ar_seen <= ar_seen + 1;
            if sb_tready = '0' then
              sb_bp_cnt <= sb_bp_cnt + 1;
            end if;
          elsif ar_valid = '1' and ar_ready = '0' then
            ar_stall <= ar_stall + 1;
          end if;
        end if;
      end if;
    end if;
  end process p_counters;

  stat_ar_seen         <= std_logic_vector(ar_seen);
  stat_ar_stall        <= std_logic_vector(ar_stall);
  stat_sb_backpressure <= std_logic_vector(sb_bp_cnt);

end architecture;
