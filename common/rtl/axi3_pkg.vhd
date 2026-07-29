-- =====================================================================
-- axi3_pkg.vhd - AXI3 records + VHDL-2019 mode views
-- =====================================================================
-- ARM IHI 0022C (AMBA 3).  Both a unified axi3_t record and per-channel
-- sub-records (aw/w/b/ar/r) are provided.  Per-channel records each have
-- <=4 unconstrained elements (w_t has 4 due to wid) for broad tool
-- compatibility.  See doc/AXI_STANDARDS.md for the full signal set.
--
-- AXI3 differences from AXI4:
--   - awlen/arlen: 4-bit (1-16 beats) vs 8-bit (1-256)
--   - awlock/arlock: 2-bit vs 1-bit
--   - wid present in W channel (write interleaving support)
--   - No awregion/arregion
-- =====================================================================
library ieee;
use ieee.std_logic_1164.all;

package axi3_pkg is

  -- ===================================================================
  -- Unified record -- UNCONSTRAINED vectors (many unconstrained
  -- elements; prefer per-channel records for current tools)
  -- ===================================================================

  type axi3_t is record
    -- Write Address channel
    awid     : std_logic_vector;             -- transaction ID
    awaddr   : std_logic_vector;             -- address of first transfer
    awlen    : std_logic_vector(3 downto 0); -- burst length: beats = awlen+1
    awsize   : std_logic_vector(2 downto 0); -- bytes per beat: 2^awsize
    awburst  : std_logic_vector(1 downto 0); -- burst type: FIXED/INCR/WRAP
    awlock   : std_logic_vector(1 downto 0); -- atomic access (AXI3: 2-bit)
    awcache  : std_logic_vector(3 downto 0); -- memory type hints
    awprot   : std_logic_vector(2 downto 0); -- protection: privilege/security/instruction
    awqos    : std_logic_vector(3 downto 0); -- Quality of Service identifier
    awuser   : std_logic_vector;             -- user-defined sideband (per-transaction)
    awvalid  : std_logic;                    -- address+control valid
    awready  : std_logic;                    -- slave: address accepted
    -- Write Data channel (AXI3 includes wid)
    wid      : std_logic_vector;             -- write ID (interleaving tag)
    wdata    : std_logic_vector;             -- write data (one beat)
    wstrb    : std_logic_vector;             -- byte enables
    wlast    : std_logic;                    -- last beat indicator
    wuser    : std_logic_vector;             -- user-defined sideband (per-beat)
    wvalid   : std_logic;                    -- data+strobe valid
    wready   : std_logic;                    -- slave: data accepted
    -- Write Response channel
    bid      : std_logic_vector;             -- response ID (echoed from awid)
    bresp    : std_logic_vector(1 downto 0); -- response code: OKAY/EXOKAY/SLVERR/DECERR
    buser    : std_logic_vector;             -- user-defined sideband (per-response)
    bvalid   : std_logic;                    -- slave: response valid
    bready   : std_logic;                    -- master: response accepted
    -- Read Address channel (AXI3: arlen=4-bit, arlock=2-bit)
    arid     : std_logic_vector;             -- transaction ID
    araddr   : std_logic_vector;             -- address of first transfer
    arlen    : std_logic_vector(3 downto 0); -- burst length: beats = arlen+1
    arsize   : std_logic_vector(2 downto 0); -- bytes per beat: 2^arsize
    arburst  : std_logic_vector(1 downto 0); -- burst type: FIXED/INCR/WRAP
    arlock   : std_logic_vector(1 downto 0); -- atomic access (AXI3: 2-bit)
    arcache  : std_logic_vector(3 downto 0); -- memory type hints
    arprot   : std_logic_vector(2 downto 0); -- protection: privilege/security/instruction
    arqos    : std_logic_vector(3 downto 0); -- Quality of Service identifier
    aruser   : std_logic_vector;             -- user-defined sideband (per-transaction)
    arvalid  : std_logic;                    -- address+control valid
    arready  : std_logic;                    -- slave: address accepted
    -- Read Data channel
    rid      : std_logic_vector;             -- read ID (echoed from arid)
    rdata    : std_logic_vector;             -- read data (one beat)
    rresp    : std_logic_vector(1 downto 0); -- response code
    rlast    : std_logic;                    -- last beat indicator
    ruser    : std_logic_vector;             -- user-defined sideband (per-beat)
    rvalid   : std_logic;                    -- slave: data+response valid
    rready   : std_logic;                    -- master: data accepted
  end record;

  -- ===================================================================
  -- Unified record mode view
  -- ===================================================================
  -- Declares the direction for every element of the unified axi3_t
  -- record.  The slave-side view is derived via VHDL-2019 `'converse`,
  -- which automatically swaps all in/out directions.

  view master_axi3 of axi3_t is
    -- AW channel
    awid, awaddr, awlen, awsize, awburst, awlock,
    awcache, awprot, awqos, awuser,
    awvalid : out;
    awready : in;
    -- W channel (AXI3 includes wid)
    wid, wdata, wstrb, wlast, wuser, wvalid : out;
    wready : in;
    -- B channel
    bid, bresp, buser, bvalid : in;
    bready : out;
    -- AR channel
    arid, araddr, arlen, arsize, arburst, arlock,
    arcache, arprot, arqos, aruser,
    arvalid : out;
    arready : in;
    -- R channel
    rid, rdata, rresp, rlast, ruser, rvalid : in;
    rready : out;
  end view;
  alias slave_axi3 is master_axi3'converse;

  -- ===================================================================
  -- Per-channel records (<=4 unconstrained elements each)
  -- ===================================================================

  -- Write Address channel (3 unconstrained: awid, awaddr, awuser)
  -- AXI3: awlen=4-bit (1-16 beats), awlock=2-bit, no awregion
  type axi3_aw_t is record
    awid     : std_logic_vector;              -- transaction ID
    awaddr   : std_logic_vector;              -- address of first transfer
    awlen    : std_logic_vector(3 downto 0);  -- burst length: beats = awlen+1
    awsize   : std_logic_vector(2 downto 0);  -- bytes per beat: 2^awsize
    awburst  : std_logic_vector(1 downto 0);  -- burst type: FIXED/INCR/WRAP
    awlock   : std_logic_vector(1 downto 0);  -- atomic access (AXI3: 2-bit)
    awcache  : std_logic_vector(3 downto 0);  -- memory type hints
    awprot   : std_logic_vector(2 downto 0);  -- protection: privilege/security/instruction
    awqos    : std_logic_vector(3 downto 0);  -- Quality of Service identifier
    awuser   : std_logic_vector;              -- user-defined sideband (per-transaction)
    awvalid  : std_logic;                     -- address+control valid
    awready  : std_logic;                     -- slave: address accepted
  end record;

  -- Write Data channel (4 unconstrained: wid, wdata, wstrb, wuser)
  -- AXI3 includes wid for write interleaving support (removed in AXI4)
  type axi3_w_t is record
    wid    : std_logic_vector;               -- write ID (AXI3: interleaving tag)
    wdata  : std_logic_vector;               -- write data (one beat)
    wstrb  : std_logic_vector;               -- byte enables: wstrb[i] qualifies byte lane i
    wlast  : std_logic;                      -- last beat indicator
    wuser  : std_logic_vector;               -- user-defined sideband (per-beat)
    wvalid : std_logic;                      -- data+strobe valid
    wready : std_logic;                      -- slave: data accepted
  end record;

  -- Write Response channel (2 unconstrained: bid, buser)
  type axi3_b_t is record
    bid    : std_logic_vector;                -- response ID (echoed from awid)
    bresp  : std_logic_vector(1 downto 0);   -- response: OKAY/EXOKAY/SLVERR/DECERR
    buser  : std_logic_vector;                -- user-defined sideband (per-response)
    bvalid : std_logic;                       -- slave: response valid
    bready : std_logic;                       -- master: response accepted
  end record;

  -- Read Address channel (3 unconstrained: arid, araddr, aruser)
  -- AXI3: arlen=4-bit, arlock=2-bit (same as AW channel)
  type axi3_ar_t is record
    arid     : std_logic_vector;              -- transaction ID (tags read transaction)
    araddr   : std_logic_vector;              -- address of first transfer
    arlen    : std_logic_vector(3 downto 0);  -- burst length: beats = arlen+1
    arsize   : std_logic_vector(2 downto 0);  -- bytes per beat: 2^arsize
    arburst  : std_logic_vector(1 downto 0);  -- burst type: FIXED/INCR/WRAP
    arlock   : std_logic_vector(1 downto 0);  -- atomic access (AXI3: 2-bit)
    arcache  : std_logic_vector(3 downto 0);  -- memory type hints
    arprot   : std_logic_vector(2 downto 0);  -- protection: privilege/security/instruction
    arqos    : std_logic_vector(3 downto 0);  -- Quality of Service identifier
    aruser   : std_logic_vector;              -- user-defined sideband (per-transaction)
    arvalid  : std_logic;                     -- address+control valid
    arready  : std_logic;                     -- slave: address accepted
  end record;

  -- Read Data channel (3 unconstrained: rid, rdata, ruser)
  type axi3_r_t is record
    rid    : std_logic_vector;                -- read ID (echoed from arid)
    rdata  : std_logic_vector;                -- read data (one beat)
    rresp  : std_logic_vector(1 downto 0);   -- response: OKAY/EXOKAY/SLVERR/DECERR
    rlast  : std_logic;                       -- last beat indicator
    ruser  : std_logic_vector;                -- user-defined sideband (per-beat)
    rvalid : std_logic;                       -- slave: data+response valid
    rready : std_logic;                       -- master: data accepted
  end record;

  -- ===================================================================
  -- Per-channel mode views
  -- ===================================================================
  -- Each view declares the directions for one AXI3 sub-channel.
  -- Slave-side views are derived via VHDL-2019 `'converse`, which
  -- automatically swaps all in/out directions.

  -- Write Address channel: master drives address+control, slave accepts
  view master_aw of axi3_aw_t is
    awid, awaddr, awlen, awsize, awburst, awlock,
    awcache, awprot, awqos, awuser,
    awvalid : out;
    awready : in;
  end view;
  alias slave_aw is master_aw'converse;

  -- Write Data channel: master drives data+strobe, slave accepts
  -- (AXI3 includes wid in the data channel)
  view master_w of axi3_w_t is
    wid, wdata, wstrb, wlast, wuser, wvalid : out;
    wready : in;
  end view;
  alias slave_w is master_w'converse;

  -- Write Response channel: slave drives response, master accepts
  view master_b of axi3_b_t is
    bid, bresp, buser, bvalid : in;
    bready : out;
  end view;
  alias slave_b is master_b'converse;

  -- Read Address channel: master drives address+control, slave accepts
  view master_ar of axi3_ar_t is
    arid, araddr, arlen, arsize, arburst, arlock,
    arcache, arprot, arqos, aruser,
    arvalid : out;
    arready : in;
  end view;
  alias slave_ar is master_ar'converse;

  -- Read Data channel: slave drives data+response, master accepts
  view master_r of axi3_r_t is
    rid, rdata, rresp, rlast, ruser, rvalid : in;
    rready : out;
  end view;
  alias slave_r is master_r'converse;

end package;
