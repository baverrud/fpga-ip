-----------------------------------------------------------------------
--Filename         : axis_cdc.vhd
--Description      : AXI4-Stream clock-domain converter (CDC) using a
--                 : Gray-pointer asynchronous FIFO core.
--                 :
--                 : KEY PROPERTIES
--                 :  - HIGH THROUGHPUT: sustains one word per clock on
--                 :    each side (line rate) regardless of the clock
--                 :    relationship between the domains. The source may
--                 :    be faster, slower, equal to, or fully unrelated
--                 :    to the destination clock.
--                 :  - SMALL, CONFIGURABLE STORAGE: the internal buffer
--                 :    is a power-of-two dual-port RAM whose depth is
--                 :    set by GC_CDC_DEPTH (default 8). Pick the
--                 :    smallest depth that meets your throughput and
--                 :    burst needs. NOTE: the FWFT combinational read
--                 :    requires a distributed-RAM (LUTRAM) implementation
--                 :    at ANY depth - block RAM has a registered read and
--                 :    cannot be used here, so keep the depth small.
--                 :  - INDUSTRY-STANDARD SAFE CDC: only the Gray-coded
--                 :    pointers cross the boundary (one bit changes per
--                 :    increment), each re-timed through a 2..4 flip-
--                 :    flop synchronizer chain (ASYNC_REG). The data
--                 :    moves through a dual-port RAM (write port in the
--                 :    source domain, read port in the destination
--                 :    domain), so no multi-bit value is ever sampled
--                 :    while changing.
--                 :  - First-Word Fall-Through (FWFT): the output is a
--                 :    combinational read of the RAM, giving minimum
--                 :    read latency and full line rate on the read side.
--                 :  - Full/empty flags are conservative (full asserts
--                 :    early, empty asserts late by the synchronizer
--                 :    latency), which is what makes overflow/underflow
--                 :    impossible.
--                 :  - One shared reset with asynchronous assertion and
--                 :    synchronous de-assertion in each clock domain.
--Author           : Rune Baeverrud
--Current Revision : 2.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axis_cdc is
  generic (
    -- Width of the AXI-Stream payload word being crossed.
    GC_TDATA_WIDTH : positive := 32;
    -- Internal FIFO depth. Must be a power of two (checked at
    -- elaboration). Keep it as small as your throughput needs allow;
    -- the FWFT combinational read always infers distributed RAM, so a
    -- large depth is expensive in LUTs.
    GC_CDC_DEPTH : positive range 2 to 1024 := 8;
    -- Flip-flops per pointer synchronizer chain (2..4). 2 is the
    -- minimum for safe re-timing; 3..4 increases MTBF at the cost of
    -- a few cycles of added fill/drain latency.
    GC_SYNC_STAGES : positive range 2 to 4 := 2
  );
  port (
    -- ==================================================================
    -- Source domain (write side), clocked by s_axis_aclk
    -- ==================================================================
    s_axis_aclk   : in  std_logic;                                    -- source clock
    aresetn       : in  std_logic;                                    -- shared reset (async assert, sync release)
    s_axis_tdata  : in  std_logic_vector(GC_TDATA_WIDTH-1 downto 0);  -- payload to cross
    s_axis_tvalid : in  std_logic;                                    -- upstream has a valid word
    s_axis_tready : out std_logic;                                    -- this CDC accepts a word

    -- ==================================================================
    -- Destination domain (read side), clocked by m_axis_aclk
    -- ==================================================================
    m_axis_aclk   : in  std_logic;                                    -- destination clock
    m_axis_tdata  : out std_logic_vector(GC_TDATA_WIDTH-1 downto 0);  -- crossed payload
    m_axis_tvalid : out std_logic;                                    -- valid crossed word on m_axis_tdata
    m_axis_tready : in  std_logic                                     -- downstream consumer accepts
  );
end entity;

architecture rtl of axis_cdc is

  ---------------------------------------------------------------------
  -- CDC CORE CONCEPT (read this first)
  ---------------------------------------------------------------------
  -- A CDC between two unrelated clocks must obey two rules:
  --   (1) A multi-bit bus must NEVER be sampled while it is changing,
  --       otherwise a bit can be captured partway through its transition
  --       and the word is corrupted.
  --   (2) A control value that crosses a boundary must be re-timed so
  --       that any metastability in the capturing flip-flop is resolved
  --       before the value is used.
  --
  -- The asynchronous FIFO solves both with the industry-standard
  -- Gray-pointer technique:
  --
  --   Storage: a dual-port RAM. The write port is clocked by
  --   s_axis_aclk, the read port by m_axis_aclk. Data therefore never
  --   needs to be held across the boundary: it is written in one domain
  --   and read in the other (rule 1 satisfied by construction).
  --
  --   Pointers: each domain owns a binary pointer (with one extra bit to
  --   distinguish full from empty) and a Gray-encoded copy of it. Gray
  --   code changes exactly ONE bit per increment, so a pointer sampled
  --   in the other domain is always an old or adjacent value, never a
  --   corrupted combination (rule 2 satisfied).
  --
  --   Synchronizers: each Gray pointer is re-timed into the other domain
  --   through a GC_SYNC_STAGES flip-flop chain (ASYNC_REG). The
  --   synchronized pointers drive the full/empty flags.
  --
  --   Flags (conservative by design):
  --     * FULL is computed against the synchronized READ pointer, which
  --       lags reality by the synchronizer latency. Full therefore
  --       asserts EARLY - the FIFO may report full a few entries before
  --       it truly is. This can never overflow: the source simply stops
  --       writing while there is still headroom.
  --     * EMPTY is computed against the synchronized WRITE pointer,
  --       which also lags. Empty therefore asserts LATE - the FIFO may
  --       still look empty for a few cycles after a write. This can
  --       never underflow: the sink simply waits while words are already
  --       in flight toward it.
  --   The cost of these conservative flags is a few cycles of fill/drain
  --   latency; steady-state throughput is unaffected as long as the
  --   depth is at least a few entries (GC_CDC_DEPTH >= 4 recommended).
  ---------------------------------------------------------------------

  -- Static elaboration check: the depth must be a power of two for the
  -- Gray-code full/empty detection to work (assert is a concurrent
  -- statement, see below after 'begin').

  -- RAM address width (log2 of the depth).
  constant C_ADDR_W : natural := log2ceil(GC_CDC_DEPTH);
  -- Pointers are one bit wider than the address: the extra (wrap) bit is
  -- what lets full and empty be told apart.
  --   empty: wptr_gray = rptr_gray
  --   full : wptr_gray = inverted top two MSBs of rptr_gray, lower bits
  --          equal (the write pointer has lapped the read pointer by
  --          exactly one full depth).

  ---------------------------------------------------------------------
  -- Dual-port storage (write: s_axis_aclk, read: m_axis_aclk)
  ---------------------------------------------------------------------
  type ram_t is array (0 to GC_CDC_DEPTH-1) of std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal mem : ram_t;

  ---------------------------------------------------------------------
  -- Source-domain state (write pointer)
  ---------------------------------------------------------------------
  type s_rec_t is record
    wptr_bin  : unsigned(C_ADDR_W downto 0);  -- binary write pointer (incl. wrap bit)
    wptr_gray : unsigned(C_ADDR_W downto 0);  -- Gray write pointer (crosses the boundary)
  end record;

  constant C_S_DEFAULT : s_rec_t := (
    wptr_bin  => (others => '0'),
    wptr_gray => (others => '0')
  );

  signal r_s : s_rec_t := C_S_DEFAULT;  -- current write-pointer state
  signal r_s_in : s_rec_t;  -- next write-pointer state

  -- Synchronizer chain for the READ pointer Gray value (read -> write
  -- domain). Index 0 samples the asynchronous input.
  type sync_chain_t is array (natural range <>) of unsigned(C_ADDR_W downto 0);
  signal rptr_gray_sync_chain : sync_chain_t(0 to GC_SYNC_STAGES-1) := (others => (others => '0'));

  -- Metastability-resolved read pointer, used by the write side.
  signal rptr_gray_sync : unsigned(C_ADDR_W downto 0) := (others => '0');

  ---------------------------------------------------------------------
  -- Destination-domain state (read pointer)
  ---------------------------------------------------------------------
  type m_rec_t is record
    rptr_bin  : unsigned(C_ADDR_W downto 0);  -- binary read pointer (incl. wrap bit)
    rptr_gray : unsigned(C_ADDR_W downto 0);  -- Gray read pointer (crosses the boundary)
  end record;

  constant C_M_DEFAULT : m_rec_t := (
    rptr_bin  => (others => '0'),
    rptr_gray => (others => '0')
  );

  signal r_m : m_rec_t := C_M_DEFAULT;  -- current read-pointer state
  signal r_m_in : m_rec_t;  -- next read-pointer state

  -- Synchronizer chain for the WRITE pointer Gray value (write -> read
  -- domain).
  signal wptr_gray_sync_chain : sync_chain_t(0 to GC_SYNC_STAGES-1) := (others => (others => '0'));

  -- Metastability-resolved write pointer, used by the read side.
  signal wptr_gray_sync : unsigned(C_ADDR_W downto 0) := (others => '0');

  ---------------------------------------------------------------------
  -- Synthesis attributes
  ---------------------------------------------------------------------
  -- ASYNC_REG (Xilinx/AMD) tells the placer/router to keep the
  -- synchronizer flip-flops adjacent and to not merge/re-time them,
  -- which is required for the MTBF assumptions to hold. Unknown tools
  -- ignore the attribute.
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of rptr_gray_sync_chain : signal is "TRUE";
  attribute ASYNC_REG of wptr_gray_sync_chain : signal is "TRUE";

  -- The external reset asserts both domains asynchronously. These two
  -- local chains make de-assertion synchronous to the respective clocks;
  -- no functional flop uses the raw reset release edge.
  signal s_reset_sync : std_logic_vector(1 downto 0) := (others => '0');
  signal m_reset_sync : std_logic_vector(1 downto 0) := (others => '0');
  signal s_resetn_local : std_logic;
  signal m_resetn_local : std_logic;
  attribute ASYNC_REG of s_reset_sync : signal is "TRUE";
  attribute ASYNC_REG of m_reset_sync : signal is "TRUE";

begin

  -- Static elaboration check: the depth must be a power of two for the
  -- Gray-code full/empty detection to work.
  assert is_power_of_two(GC_CDC_DEPTH)
    report "GC_CDC_DEPTH must be a power of 2"
    severity failure;

  ---------------------------------------------------------------------
  -- SOURCE DOMAIN (s_axis_aclk)
  ---------------------------------------------------------------------

  -- Reset synchronizer: asynchronous assertion, two source-clock release
  -- cycles. The second stage is the only reset indication used by logic.
  p_s_reset_sync : process(s_axis_aclk, aresetn)
  begin
    if aresetn = '0' then
      s_reset_sync <= (others => '0');
    elsif rising_edge(s_axis_aclk) then
      s_reset_sync <= s_reset_sync(0) & '1';
    end if;
  end process;

  s_resetn_local <= s_reset_sync(1);

  -- Write port of the dual-port RAM. A word is stored at the current
  -- write address on a valid/ready handshake.
  p_mem_w : process(s_axis_aclk)
  begin
    if rising_edge(s_axis_aclk) then
      if (s_resetn_local = '1') and (s_axis_tvalid = '1') and (s_axis_tready = '1') then
        mem(to_integer(r_s.wptr_bin(C_ADDR_W-1 downto 0))) <= s_axis_tdata;
      end if;
    end if;
  end process;

  -- Re-time the read pointer (Gray) into the write domain.
  p_sync_rptr : process(s_axis_aclk, aresetn)
  begin
    if aresetn = '0' then
      rptr_gray_sync_chain <= (others => (others => '0'));
    elsif rising_edge(s_axis_aclk) then
      if s_resetn_local = '0' then
        rptr_gray_sync_chain <= (others => (others => '0'));
      else
        rptr_gray_sync_chain(0) <= r_m.rptr_gray;  -- asynchronous input from read domain
        for i in 1 to GC_SYNC_STAGES-1 loop
          rptr_gray_sync_chain(i) <= rptr_gray_sync_chain(i-1);
        end loop;
      end if;
    end if;
  end process;

  rptr_gray_sync <= rptr_gray_sync_chain(GC_SYNC_STAGES-1);

  -- Write-side combinational logic.
  --  - s_axis_tready uses the CURRENT full check. The final free slot is
  --    accepted, and ready goes low immediately after that write because
  --    the registered pointer is now full.
  --  - On an accepted write the pointer advances (binary + Gray).
  p_s_comb : process(r_s, s_axis_tvalid, rptr_gray_sync, s_resetn_local)
    variable v            : s_rec_t;
    variable v_wptr_next  : unsigned(C_ADDR_W downto 0);
    variable v_wgray_next : unsigned(C_ADDR_W downto 0);
    variable v_not_full   : boolean;
  begin
    v := r_s;  -- default: hold current pointer

    v_wptr_next  := r_s.wptr_bin + 1;
    v_wgray_next := bin2gray(v_wptr_next);
    -- Computed in a variable so the SAME value drives both tready and
    -- the pointer update. Reading the driven output signal here would
    -- use its stale previous-cycle value and corrupt the FIFO.
    v_not_full := not is_gray_full(r_s.wptr_gray, rptr_gray_sync);
    s_axis_tready <= '1' when (s_resetn_local = '1') and v_not_full else '0';

    if (s_resetn_local = '1') and (s_axis_tvalid = '1') and v_not_full then
      v.wptr_bin  := v_wptr_next;
      v.wptr_gray := v_wgray_next;
    end if;

    r_s_in <= v;
  end process;

  -- Write-pointer register (async reset, synchronous release).
  p_s_reg : process(s_axis_aclk, aresetn)
  begin
    if aresetn = '0' then
      r_s <= C_S_DEFAULT;
    elsif rising_edge(s_axis_aclk) then
      if s_resetn_local = '0' then
        r_s <= C_S_DEFAULT;
      else
        r_s <= r_s_in;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------
  -- DESTINATION DOMAIN (m_axis_aclk)
  ---------------------------------------------------------------------

  -- Reset synchronizer: asynchronous assertion, two destination-clock
  -- release cycles. The second stage is the only reset indication used by
  -- destination logic.
  p_m_reset_sync : process(m_axis_aclk, aresetn)
  begin
    if aresetn = '0' then
      m_reset_sync <= (others => '0');
    elsif rising_edge(m_axis_aclk) then
      m_reset_sync <= m_reset_sync(0) & '1';
    end if;
  end process;

  m_resetn_local <= m_reset_sync(1);

  -- Re-time the write pointer (Gray) into the read domain.
  p_sync_wptr : process(m_axis_aclk, aresetn)
  begin
    if aresetn = '0' then
      wptr_gray_sync_chain <= (others => (others => '0'));
    elsif rising_edge(m_axis_aclk) then
      if m_resetn_local = '0' then
        wptr_gray_sync_chain <= (others => (others => '0'));
      else
        wptr_gray_sync_chain(0) <= r_s.wptr_gray;  -- asynchronous input from write domain
        for i in 1 to GC_SYNC_STAGES-1 loop
          wptr_gray_sync_chain(i) <= wptr_gray_sync_chain(i-1);
        end loop;
      end if;
    end if;
  end process;

  wptr_gray_sync <= wptr_gray_sync_chain(GC_SYNC_STAGES-1);

  -- First-Word Fall-Through read: the output is a combinational read of
  -- the RAM at the current read address. m_axis_tvalid (below) tells the
  -- consumer whether this data is valid. Because the read is
  -- combinational, the read side runs at line rate with minimum latency.
  m_axis_tdata <= mem(to_integer(r_m.rptr_bin(C_ADDR_W-1 downto 0)));

  -- Read-side combinational logic.
  --  - m_axis_tvalid is the NOT-EMPTY check against the CURRENT read
  --    pointer and the synchronized write pointer. Empty asserts late
  --    (conservative), so an underflow is impossible: the consumer is
  --    only told data is valid once the write side has made it visible.
  --  - On an accepted read the pointer advances (binary + Gray).
  p_m_comb : process(r_m, m_axis_tready, wptr_gray_sync, m_resetn_local)
    variable v            : m_rec_t;
    variable v_rptr_next  : unsigned(C_ADDR_W downto 0);
    variable v_rgray_next : unsigned(C_ADDR_W downto 0);
    variable v_not_empty  : boolean;
  begin
    v := r_m;  -- default: hold current pointer

    v_rptr_next  := r_m.rptr_bin + 1;
    v_rgray_next := bin2gray(v_rptr_next);

    -- Not empty (current occupancy): there is a word to present.
    -- Computed in a variable so the SAME value drives both tvalid and
    -- the pointer update (see the p_s_comb note on stale signal reads).
    v_not_empty := not is_gray_empty(r_m.rptr_gray, wptr_gray_sync);
    m_axis_tvalid <= '1' when (m_resetn_local = '1') and v_not_empty else '0';

    if (m_resetn_local = '1') and v_not_empty and (m_axis_tready = '1') then
      v.rptr_bin  := v_rptr_next;
      v.rptr_gray := v_rgray_next;
    end if;

    r_m_in <= v;
  end process;

  -- Read-pointer register (async reset, synchronous release).
  p_m_reg : process(m_axis_aclk, aresetn)
  begin
    if aresetn = '0' then
      r_m <= C_M_DEFAULT;
    elsif rising_edge(m_axis_aclk) then
      if m_resetn_local = '0' then
        r_m <= C_M_DEFAULT;
      else
        r_m <= r_m_in;
      end if;
    end if;
  end process;

end architecture;
