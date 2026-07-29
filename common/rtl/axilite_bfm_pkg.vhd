-- =====================================================================
-- axilite_bfm_pkg.vhd — AXI4-Lite BFM helpers (VHDL-2008)
-- =====================================================================
-- Standalone BFM package containing the axilite_write / axilite_read
-- procedures from axilite_pkg, extracted so they can be compiled with
-- VHDL-2008 simulators (ModelSim 2021.1) that don't support the
-- VHDL-2019 mode views in axilite_pkg.
--
-- The procedures implement a robust single-beat AXI-Lite write/read
-- sequence synchronised to aclk.  Address is 16-bit (register-map
-- window); the signal interface uses 40-bit awaddr/araddr for Zynq
-- M_AXI_GP compatibility.
-- =====================================================================
library ieee;
use ieee.std_logic_1164.all;

package axilite_bfm_pkg is

  procedure wait_cycles(
    signal   aclk : in std_logic;
    constant n    : in natural
  );

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

package body axilite_bfm_pkg is

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
