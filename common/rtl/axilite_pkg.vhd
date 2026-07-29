-- =====================================================================
-- axilite_pkg.vhd - AXI4-Lite unified record + VHDL-2019 mode views
-- =====================================================================
-- ARM IHI 0022E, Appendix A.  Single-beat register-access subset of
-- AXI4.  Only the generic axilite_t type is provided here — use record
-- constraints at the signal declaration site to set vector widths.
--
-- The unified axilite_t record has 5 unconstrained std_logic_vector
-- elements (awaddr, wdata, wstrb, araddr, rdata).  See
-- doc/AXI_STANDARDS.md for the full signal set.
-- =====================================================================
library ieee;
use ieee.std_logic_1164.all;

package axilite_pkg is

  -- ===================================================================
  -- Unified record — 5 unconstrained elements (awaddr, wdata, wstrb,
  -- araddr, rdata).
  -- ===================================================================

  type axilite_t is record
    -- Write Address channel
    awaddr   : std_logic_vector;              -- address of the register
    awprot   : std_logic_vector(2 downto 0);  -- protection: privilege/security/instruction
    awvalid  : std_logic;                     -- address+control valid
    awready  : std_logic;                     -- slave: address accepted
    -- Write Data channel
    wdata    : std_logic_vector;              -- write data (one beat)
    wstrb    : std_logic_vector;              -- byte enables
    wvalid   : std_logic;                     -- data+strobe valid
    wready   : std_logic;                     -- slave: data accepted
    -- Write Response channel
    bresp    : std_logic_vector(1 downto 0);  -- response code: OKAY/SLVERR/DECERR
    bvalid   : std_logic;                     -- slave: response valid
    bready   : std_logic;                     -- master: response accepted
    -- Read Address channel
    araddr   : std_logic_vector;              -- address of the register
    arprot   : std_logic_vector(2 downto 0);  -- protection: privilege/security/instruction
    arvalid  : std_logic;                     -- address+control valid
    arready  : std_logic;                     -- slave: address accepted
    -- Read Data channel
    rdata    : std_logic_vector;              -- read data (one beat)
    rresp    : std_logic_vector(1 downto 0);  -- response code: OKAY/SLVERR/DECERR
    rvalid   : std_logic;                     -- slave: data+response valid
    rready   : std_logic;                     -- master: data accepted
  end record;

  view master_axilite of axilite_t is
    -- AW channel
    awaddr, awprot, awvalid : out;
    awready : in;
    -- W channel
    wdata, wstrb, wvalid : out;
    wready : in;
    -- B channel
    bresp, bvalid : in;
    bready : out;
    -- AR channel
    araddr, arprot, arvalid : out;
    arready : in;
    -- R channel
    rdata, rresp, rvalid : in;
    rready : out;
  end view;
  alias slave_axilite is master_axilite'converse;

  -- ===================================================================
  -- Constrained subtype — Zynq MPSoC AXI4-Lite (40-bit addr, 32-bit data)
  -- ===================================================================

  subtype axilite_m40_t is axilite_t (
    awaddr(39 downto 0),
    wdata (31 downto 0),
    wstrb ( 3 downto 0),
    araddr(39 downto 0),
    rdata (31 downto 0)
  );

  -- ===================================================================
  -- Array type for multi-bus designs
  -- ===================================================================
  -- Use for internal signals in top-level designs.  The mode view
  -- (master/slave) is determined at the entity port, not the type.
  -- Example:
  --   signal axilite : axilite_m40_array_t(0 to 7);
  -- ===================================================================

  type axilite_m40_array_t is array (natural range <>) of axilite_m40_t;

  -- ===================================================================
  -- AXI4-Lite BFM helpers (M40 bus + 16-bit register map window)
  --
  -- These are intended for testbenches. They implement a robust single-
  -- beat AXI-Lite write/read sequence synchronized to aclk.
  -- ===================================================================
  procedure axilite_write(
    signal   aclk    : in  std_logic;
    signal   awaddr  : out std_logic_vector(39 downto 0);
    signal   awprot  : out std_logic_vector(2 downto 0);
    signal   awvalid : out std_logic;
    signal   awready : in  std_logic;
    signal   wdata   : out std_logic_vector(31 downto 0);
    signal   wstrb   : out std_logic_vector(3 downto 0);
    signal   wvalid  : out std_logic;
    signal   wready  : in  std_logic;
    signal   bready  : out std_logic;
    signal   bvalid  : in  std_logic;
    constant addr    : in  std_logic_vector(15 downto 0);
    constant dat     : in  std_logic_vector(31 downto 0);
    constant strb    : in  std_logic_vector( 3 downto 0) := x"F"
  );

  procedure axilite_read(
    signal   aclk    : in  std_logic;
    signal   araddr  : out std_logic_vector(39 downto 0);
    signal   arprot  : out std_logic_vector(2 downto 0);
    signal   arvalid : out std_logic;
    signal   arready : in  std_logic;
    signal   rready  : out std_logic;
    signal   rvalid  : in  std_logic;
    signal   rdata   : in  std_logic_vector(31 downto 0);
    constant addr    : in  std_logic_vector(15 downto 0);
    variable dat     : out std_logic_vector(31 downto 0)
  );

end package;

package body axilite_pkg is

  procedure wait_cycles(
    signal   aclk : in std_logic;
    constant n    : in natural
  ) is
  begin
    for i in 1 to n loop
      wait until rising_edge(aclk);
    end loop;
  end procedure;

  procedure axilite_write(
    signal   aclk    : in  std_logic;
    signal   awaddr  : out std_logic_vector(39 downto 0);
    signal   awprot  : out std_logic_vector(2 downto 0);
    signal   awvalid : out std_logic;
    signal   awready : in  std_logic;
    signal   wdata   : out std_logic_vector(31 downto 0);
    signal   wstrb   : out std_logic_vector(3 downto 0);
    signal   wvalid  : out std_logic;
    signal   wready  : in  std_logic;
    signal   bready  : out std_logic;
    signal   bvalid  : in  std_logic;
    constant addr    : in  std_logic_vector(15 downto 0);
    constant dat     : in  std_logic_vector(31 downto 0);
    constant strb    : in  std_logic_vector( 3 downto 0) := x"F"
  ) is
  begin
    awaddr  <= X"000000" & addr;
    awprot  <= "000";
    awvalid <= '1';
    wdata   <= dat;
    wstrb   <= strb;
    wvalid  <= '1';
    wait_cycles(aclk, 1);
    while awready = '0' or wready = '0' loop
      wait_cycles(aclk, 1);
    end loop;
    awvalid <= '0';
    wvalid  <= '0';
    bready  <= '1';
    wait_cycles(aclk, 1);
    while bvalid = '0' loop
      wait_cycles(aclk, 1);
    end loop;
    wait_cycles(aclk, 1);
    bready <= '0';
  end procedure;

  procedure axilite_read(
    signal   aclk    : in  std_logic;
    signal   araddr  : out std_logic_vector(39 downto 0);
    signal   arprot  : out std_logic_vector(2 downto 0);
    signal   arvalid : out std_logic;
    signal   arready : in  std_logic;
    signal   rready  : out std_logic;
    signal   rvalid  : in  std_logic;
    signal   rdata   : in  std_logic_vector(31 downto 0);
    constant addr    : in  std_logic_vector(15 downto 0);
    variable dat     : out std_logic_vector(31 downto 0)
  ) is
  begin
    araddr  <= X"000000" & addr;
    arprot  <= "000";
    arvalid <= '1';
    wait_cycles(aclk, 1);
    while arready = '0' loop
      wait_cycles(aclk, 1);
    end loop;
    arvalid <= '0';
    rready  <= '1';
    wait_cycles(aclk, 1);
    while rvalid = '0' loop
      wait_cycles(aclk, 1);
    end loop;
    wait_cycles(aclk, 1);
    dat := rdata;
    wait_cycles(aclk, 1);
    rready <= '0';
  end procedure;

end package body;
