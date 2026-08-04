-- =====================================================================
-- axis_pkg.vhd - AXI-Stream record + VHDL-2019 mode views
-- =====================================================================
-- All sideband signals (except tlast) are unconstrained std_logic_vector.
-- 1-bit safe-width stubs when unused -- NEVER null ranges (crash Vivado GUI).
-- aclk/aresetn are NOT in the record -- they remain as separate ports
-- in VHDL (unlike the SV version which puts them in the interface).
--
-- Signal declaration:
--   signal s : axis_t(
--       tdata(31 downto 0),
--       tuser(0 downto 0),       -- 1-bit stub
--       ...
--   );
--
-- =====================================================================
-- AXI4-Stream Signal Width Reference (ARM IHI 0051A)
-- =====================================================================
--
-- Legend:
--   U   = unconstrained (width set by user / application)
--   F   = fixed width (mandated by the AXI4-Stream spec)
--   D   = derived from data width (DATA_W / 8 for tkeep/tstrb)
--
-- Signal   Width     Fixed/Unc.  Notes
-- -------- --------- ----------- ----------------------------------------
-- tdata    U         unconf.    Payload (any width, typically 8/16/32/64/128)
-- tlast    1-bit     F          End-of-packet marker
-- tuser    U         unconf.    User-defined sideband
-- tid      U         unconf.    Stream ID tag
-- tdest    U         unconf.    Destination / routing tag
-- tkeep    D         derived    Byte lane valid (DATA_W / 8)
-- tstrb    D         derived    Byte lane strobe (DATA_W / 8)
-- tvalid   1-bit     F          Valid handshake
-- tready   1-bit     F          Ready handshake
-- =====================================================================
library ieee;
use ieee.std_logic_1164.all;

package axis_pkg is

  type axis_t is record
    tdata  : std_logic_vector;   -- payload
    tlast  : std_logic;          -- end-of-packet (always 1 bit)
    tuser  : std_logic_vector;   -- 1-bit stub when unused
    tid    : std_logic_vector;
    tdest  : std_logic_vector;
    tkeep  : std_logic_vector;
    tstrb  : std_logic_vector;
    tvalid : std_logic;
    tready : std_logic;
  end record;

  -- ===================================================================
  -- Unified record mode view
  -- ===================================================================
  -- Declares the direction for every element of the unconstrained
  -- axis_t record.  The slave-side view is derived via VHDL-2019
  -- `'converse`, which automatically swaps all in/out directions.

  -- master (Tx): drives payload + framing, samples back-pressure.
  view master_axis of axis_t is
    tdata  : out;
    tlast  : out;
    tuser  : out;
    tid    : out;
    tdest  : out;
    tkeep  : out;
    tstrb  : out;
    tvalid : out;
    tready : in;
  end view;

  -- slave (Rx): converse of master.
  alias slave_axis is master_axis'converse;

  -- ===================================================================
  -- Option A: Fully constrained 32-bit record (no per-signal constraints)
  -- ===================================================================
  -- All vector widths are fixed in the type -- signal declarations need
  -- NO record constraint syntax.  Trade-off: one type per width combo.
  -- ===================================================================
  type axis_32b_t is record
    tdata  : std_logic_vector(31 downto 0);  -- 32-bit payload
    tlast  : std_logic;                       -- end-of-packet
    tuser  : std_logic_vector(0 downto 0);   -- 1-bit stub
    tid    : std_logic_vector(0 downto 0);
    tdest  : std_logic_vector(0 downto 0);
    tkeep  : std_logic_vector(0 downto 0);
    tstrb  : std_logic_vector(0 downto 0);
    tvalid : std_logic;
    tready : std_logic;
  end record;

  view master_32b of axis_32b_t is
    tdata, tlast, tuser, tid, tdest, tkeep, tstrb, tvalid : out;
    tready : in;
  end view;
  alias slave_32b is master_32b'converse;

  -- ===================================================================
  -- Option B: Array of streams (N independent channels in one bundle)
  -- ===================================================================
  type axis_array_t is array (natural range <>) of axis_t;

end package;
