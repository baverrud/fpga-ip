-- =====================================================================
-- axi4_pkg.vhd - AXI4 records + VHDL-2019 mode views
-- =====================================================================
-- ARM IHI 0022E (AMBA 4).  Both a unified axi4_t record and per-channel
-- sub-records (aw/w/b/ar/r) are provided.  Per-channel records each have
-- <=3 unconstrained elements for broad tool compatibility.  See
-- doc/AXI_STANDARDS.md for the full signal set.
-- =====================================================================
library ieee;
use ieee.std_logic_1164.all;

package axi4_pkg is

  -- ===================================================================
  -- Unified record -- UNCONSTRAINED vectors (many unconstrained
  -- elements; prefer per-channel records for current tools)
  -- ===================================================================

  type axi4_t is record
    -- Write Address channel
    awid     : std_logic_vector;             -- transaction ID
    awaddr   : std_logic_vector;             -- address of first transfer
    awlen    : std_logic_vector(7 downto 0); -- burst length: beats = awlen+1
    awsize   : std_logic_vector(2 downto 0); -- bytes per beat: 2^awsize
    awburst  : std_logic_vector(1 downto 0); -- burst type: FIXED/INCR/WRAP
    awlock   : std_logic;                    -- atomic access: 0=normal, 1=exclusive
    awcache  : std_logic_vector(3 downto 0); -- memory type hints
    awprot   : std_logic_vector(2 downto 0); -- protection: privilege/security/instruction
    awqos    : std_logic_vector(3 downto 0); -- Quality of Service
    awregion : std_logic_vector(3 downto 0); -- address region (AXI4 only)
    awuser   : std_logic_vector;             -- user-defined sideband (per-transaction)
    awvalid  : std_logic;                    -- address+control valid
    awready  : std_logic;                    -- slave: address accepted
    -- Write Data channel
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
    -- Read Address channel
    arid     : std_logic_vector;             -- transaction ID
    araddr   : std_logic_vector;             -- address of first transfer
    arlen    : std_logic_vector(7 downto 0); -- burst length: beats = arlen+1
    arsize   : std_logic_vector(2 downto 0); -- bytes per beat: 2^arsize
    arburst  : std_logic_vector(1 downto 0); -- burst type: FIXED/INCR/WRAP
    arlock   : std_logic;                    -- atomic access: 0=normal, 1=exclusive
    arcache  : std_logic_vector(3 downto 0); -- memory type hints
    arprot   : std_logic_vector(2 downto 0); -- protection: privilege/security/instruction
    arqos    : std_logic_vector(3 downto 0); -- Quality of Service identifier
    arregion : std_logic_vector(3 downto 0); -- address region (AXI4 only)
    aruser   : std_logic_vector;             -- user-defined sideband (per-transaction)
    arvalid  : std_logic;                    -- address+control valid
    arready  : std_logic;                    -- slave: address accepted
    -- Read Data channel
    rid      : std_logic_vector;             -- read ID (echoed from arid)
    rdata    : std_logic_vector;             -- read data (one beat)
    rresp    : std_logic_vector(1 downto 0); -- response code: OKAY/EXOKAY/SLVERR/DECERR
    rlast    : std_logic;                    -- last beat indicator
    ruser    : std_logic_vector;             -- user-defined sideband (per-beat)
    rvalid   : std_logic;                    -- slave: data+response valid
    rready   : std_logic;                    -- master: data accepted
  end record;

  -- ===================================================================
  -- Unified record mode view
  -- ===================================================================
  -- Declares the direction for every element of the unified axi4_t
  -- record.  The slave-side view is derived via VHDL-2019 `'converse`,
  -- which automatically swaps all in/out directions.

  view master_axi4 of axi4_t is
    -- AW channel
    awid, awaddr, awlen, awsize, awburst, awlock,
    awcache, awprot, awqos, awregion, awuser,
    awvalid : out;
    awready : in;
    -- W channel
    wdata, wstrb, wlast, wuser, wvalid : out;
    wready : in;
    -- B channel
    bid, bresp, buser, bvalid : in;
    bready : out;
    -- AR channel
    arid, araddr, arlen, arsize, arburst, arlock,
    arcache, arprot, arqos, arregion, aruser,
    arvalid : out;
    arready : in;
    -- R channel
    rid, rdata, rresp, rlast, ruser, rvalid : in;
    rready : out;
  end view;
  alias slave_axi4 is master_axi4'converse;

  -- ===================================================================
  -- Constrained subtype — Zynq MPSoC AXI4 slave (ID=6, ADDR=49, DATA=128)
  -- ===================================================================
  -- Matches S_AXI_HP0_FPD through S_AXI_HP3_FPD, S_AXI_HPC0_FPD,
  -- S_AXI_HPC1_FPD, and S_AXI_LPD in the ZCU104 block design wrapper.
  -- All user sidebands are stubbed to 1-bit (0 downto 0).
  --
  -- The `master`/`slave` views of axi4_t apply directly — no new views
  -- needed.
  -- ===================================================================

  subtype axi4_hp_t is axi4_t (
    awaddr( 48 downto 0),
    awid  (  5 downto 0),
    awuser(  0 downto 0),
    wdata (127 downto 0),
    wstrb ( 15 downto 0),
    wuser (  0 downto 0),
    bid   (  5 downto 0),
    buser (  0 downto 0),
    araddr( 48 downto 0),
    arid  (  5 downto 0),
    aruser(  0 downto 0),
    rid   (  5 downto 0),
    rdata (127 downto 0),
    ruser (  0 downto 0)
  );

  -- Array type for multi-bus designs
  type axi4_hp_array_t is array (natural range <>) of axi4_hp_t;

  -- ===================================================================
  -- Constrained subtype — Zynq MPSoC AXI4 HPM FPD master (ID=16, ADDR=40, DATA=128)
  -- ===================================================================
  -- Matches M_AXI_HPM0_FPD in the ZCU104 block design wrapper.
  -- W/B/R channel user sidebands not present in wrapper — stubbed to 1-bit.
  -- ===================================================================

  subtype axi4_hpm_fpd_t is axi4_t (
    awaddr( 39 downto 0),
    awid  ( 15 downto 0),
    awuser( 15 downto 0),
    wdata (127 downto 0),
    wstrb ( 15 downto 0),
    wuser (  0 downto 0),
    bid   ( 15 downto 0),
    buser (  0 downto 0),
    araddr( 39 downto 0),
    arid  ( 15 downto 0),
    aruser( 15 downto 0),
    rid   ( 15 downto 0),
    rdata (127 downto 0),
    ruser (  0 downto 0)
  );

  -- ===================================================================
  -- Constrained subtype — Zynq MPSoC AXI4 HPM LPD master (ID=16, ADDR=40, DATA=32)
  -- ===================================================================
  -- Matches M_AXI_HPM0_LPD in the ZCU104 block design wrapper.
  -- W/B/R channel user sidebands not present in wrapper — stubbed to 1-bit.
  -- ===================================================================

  subtype axi4_hpm_lpd_t is axi4_t (
    awaddr( 39 downto 0),
    awid  ( 15 downto 0),
    awuser( 15 downto 0),
    wdata ( 31 downto 0),
    wstrb (  3 downto 0),
    wuser (  0 downto 0),
    bid   ( 15 downto 0),
    buser (  0 downto 0),
    araddr( 39 downto 0),
    arid  ( 15 downto 0),
    aruser( 15 downto 0),
    rid   ( 15 downto 0),
    rdata ( 31 downto 0),
    ruser (  0 downto 0)
  );

  -- ===================================================================
  -- Per-channel records (<=3 unconstrained elements each)
  -- ===================================================================

  -- Write Address channel (3 unconstrained: awid, awaddr, awuser)
  -- AXI4: awlen=8-bit (1-256 beats), awlock=1-bit, awregion present
  type axi4_aw_t is record
    awid     : std_logic_vector;              -- transaction ID
    awaddr   : std_logic_vector;              -- address of first transfer
    awlen    : std_logic_vector(7  downto 0); -- burst length: beats = awlen+1
    awsize   : std_logic_vector(2  downto 0); -- bytes per beat: 2^awsize
    awburst  : std_logic_vector(1  downto 0); -- burst type: FIXED/INCR/WRAP
    awlock   : std_logic;                     -- atomic access: 0=normal, 1=exclusive
    awcache  : std_logic_vector(3  downto 0); -- memory type hints
    awprot   : std_logic_vector(2  downto 0); -- protection: privilege/security/instruction
    awqos    : std_logic_vector(3  downto 0); -- Quality of Service
    awregion : std_logic_vector(3  downto 0); -- address region (AXI4 only)
    awuser   : std_logic_vector;              -- user-defined sideband (per-transaction)
    awvalid  : std_logic;                     -- address+control valid
    awready  : std_logic;                     -- slave: address accepted
  end record;

  -- HP-constrained Write Address channel (matches axi4_hp_t widths)
  subtype axi4_hp_aw_t is axi4_aw_t (
    awid   ( 5 downto 0),
    awaddr (48 downto 0),
    awuser ( 0 downto 0)
  );
  type axi4_hp_aw_array_t is array (natural range <>) of axi4_hp_aw_t;

  -- Write Data channel (3 unconstrained: wdata, wstrb, wuser)
  -- AXI4: wid removed (unlike AXI3); write data only
  type axi4_w_t is record
    wdata  : std_logic_vector;                -- write data (one beat)
    wstrb  : std_logic_vector;                -- byte enables: wstrb[i] qualifies byte lane i
    wlast  : std_logic;                       -- last beat indicator
    wuser  : std_logic_vector;                -- user-defined sideband (per-beat)
    wvalid : std_logic;                       -- data+strobe valid
    wready : std_logic;                       -- slave: data accepted
  end record;

  -- HP-constrained Write Data channel (matches axi4_hp_t widths)
  subtype axi4_hp_w_t is axi4_w_t (
    wdata (127 downto 0),
    wstrb ( 15 downto 0),
    wuser (  0 downto 0)
  );
  type axi4_hp_w_array_t is array (natural range <>) of axi4_hp_w_t;

  -- Write Response channel (2 unconstrained: bid, buser)
  type axi4_b_t is record
    bid      : std_logic_vector;              -- response ID (echoed from awid)
    bresp    : std_logic_vector(1  downto 0); -- response: OKAY/EXOKAY/SLVERR/DECERR
    buser    : std_logic_vector;              -- user-defined sideband (per-response)
    bvalid   : std_logic;                     -- slave: response valid
    bready   : std_logic;                     -- master: response accepted
  end record;

  -- HP-constrained Write Response channel (matches axi4_hp_t widths)
  subtype axi4_hp_b_t is axi4_b_t (
    bid   ( 5 downto 0),
    buser ( 0 downto 0)
  );
  type axi4_hp_b_array_t is array (natural range <>) of axi4_hp_b_t;

  -- Read Address channel (3 unconstrained: arid, araddr, aruser)
  type axi4_ar_t is record
    arid     : std_logic_vector;              -- transaction ID (tags read transaction)
    araddr   : std_logic_vector;              -- address of first transfer
    arlen    : std_logic_vector(7  downto 0); -- burst length: beats = arlen+1
    arsize   : std_logic_vector(2  downto 0); -- bytes per beat: 2^arsize
    arburst  : std_logic_vector(1  downto 0); -- burst type: FIXED/INCR/WRAP
    arlock   : std_logic;                     -- atomic access: 0=normal, 1=exclusive
    arcache  : std_logic_vector(3  downto 0); -- memory type hints
    arprot   : std_logic_vector(2  downto 0); -- protection: privilege/security/instruction
    arqos    : std_logic_vector(3  downto 0); -- Quality of Service
    arregion : std_logic_vector(3  downto 0); -- address region (AXI4 only)
    aruser   : std_logic_vector;              -- user-defined sideband (per-transaction)
    arvalid  : std_logic;                     -- address+control valid
    arready  : std_logic;                     -- slave: address accepted
  end record;

  -- HP-constrained Read Address channel (matches axi4_hp_t widths)
  subtype axi4_hp_ar_t is axi4_ar_t (
    arid   ( 5 downto 0),
    araddr (48 downto 0),
    aruser ( 0 downto 0)
  );
  type axi4_hp_ar_array_t is array (natural range <>) of axi4_hp_ar_t;

  -- Read Data channel (3 unconstrained: rid, rdata, ruser)
  type axi4_r_t is record
    rid      : std_logic_vector;              -- read ID (echoed from arid)
    rdata    : std_logic_vector;              -- read data (one beat)
    rresp    : std_logic_vector(1  downto 0); -- response: OKAY/EXOKAY/SLVERR/DECERR
    rlast    : std_logic;                     -- last beat indicator
    ruser    : std_logic_vector;              -- user-defined sideband (per-beat)
    rvalid   : std_logic;                     -- slave: data+response valid
    rready   : std_logic;                     -- master: data accepted
  end record;

  -- HP-constrained Read Data channel (matches axi4_hp_t widths)
  subtype axi4_hp_r_t is axi4_r_t (
    rid   ( 5 downto 0),
    rdata (127 downto 0),
    ruser ( 0 downto 0)
  );
  type axi4_hp_r_array_t is array (natural range <>) of axi4_hp_r_t;

  -- ===================================================================
  -- Per-channel mode views
  -- ===================================================================
  -- Each view declares the directions for one AXI4 sub-channel.
  -- Slave-side views are derived via VHDL-2019 `'converse`, which
  -- automatically swaps all in/out directions.

  -- Write Address channel: master drives address+control, slave accepts
  view master_aw of axi4_aw_t is
    awid, awaddr, awlen, awsize, awburst, awlock,
    awcache, awprot, awqos, awregion, awuser,
    awvalid : out;
    awready : in;
  end view;
  alias slave_aw is master_aw'converse;

  -- Write Data channel: master drives data+strobe, slave accepts
  view master_w of axi4_w_t is
    wdata, wstrb, wlast, wuser, wvalid : out;
    wready : in;
  end view;
  alias slave_w is master_w'converse;

  -- Write Response channel: slave drives response, master accepts
  view master_b of axi4_b_t is
    bid, bresp, buser, bvalid : in;
    bready : out;
  end view;
  alias slave_b is master_b'converse;

  -- Read Address channel: master drives address+control, slave accepts
  view master_ar of axi4_ar_t is
    arid, araddr, arlen, arsize, arburst, arlock,
    arcache, arprot, arqos, arregion, aruser,
    arvalid : out;
    arready : in;
  end view;
  alias slave_ar is master_ar'converse;

  -- Read Data channel: slave drives data+response, master accepts
  view master_r of axi4_r_t is
    rid, rdata, rresp, rlast, ruser, rvalid : in;
    rready : out;
  end view;
  alias slave_r is master_r'converse;

end package;
