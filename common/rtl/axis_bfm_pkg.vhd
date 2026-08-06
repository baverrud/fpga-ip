-----------------------------------------------------------------------
--Filename         : axis_bfm_pkg.vhd
--Description      : Shared AXI4-Stream BFM procedures for VHDL testbenches.
--                 : Holds valid until ready and ready until valid, so every
--                 : helper completes only on a real rising-edge handshake.
--Author           : Rune Baeverrud
--Current Revision : 1.0
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

package axis_bfm_pkg is

  -- Push one beat into an AXI4-Stream slave.
  procedure axis_write(
    signal   clk    : in  std_logic;
    signal   tdata  : out std_logic_vector;
    signal   tvalid : out std_logic;
    signal   tready : in  std_logic;
    constant data   : in  std_logic_vector
  );

  -- Pop one beat from an AXI4-Stream master and return its payload.
  procedure axis_read(
    signal   clk    : in  std_logic;
    signal   tready : out std_logic;
    signal   tvalid : in  std_logic;
    signal   tdata  : in  std_logic_vector;
    variable data   : out std_logic_vector
  );

  -- Pop one beat from an AXI4-Stream master and discard its payload.
  procedure axis_pop(
    signal   clk    : in  std_logic;
    signal   tready : out std_logic;
    signal   tvalid : in  std_logic
  );

end package;

package body axis_bfm_pkg is

  procedure axis_write(
    signal   clk    : in  std_logic;
    signal   tdata  : out std_logic_vector;
    signal   tvalid : out std_logic;
    signal   tready : in  std_logic;
    constant data   : in  std_logic_vector
  ) is
  begin
    -- VALID and payload remain asserted until a rising-edge handshake.
    tdata  <= data;
    tvalid <= '1';
    loop
      wait until rising_edge(clk);
      exit when tready = '1';
    end loop;
    tvalid <= '0';
  end procedure;

  procedure axis_read(
    signal   clk    : in  std_logic;
    signal   tready : out std_logic;
    signal   tvalid : in  std_logic;
    signal   tdata  : in  std_logic_vector;
    variable data   : out std_logic_vector
  ) is
  begin
    -- READY remains asserted until a rising-edge handshake.
    tready <= '1';
    loop
      wait until rising_edge(clk);
      exit when tvalid = '1';
    end loop;
    data   := tdata;
    tready <= '0';
  end procedure;

  procedure axis_pop(
    signal   clk    : in  std_logic;
    signal   tready : out std_logic;
    signal   tvalid : in  std_logic
  ) is
  begin
    tready <= '1';
    loop
      wait until rising_edge(clk);
      exit when tvalid = '1';
    end loop;
    tready <= '0';
  end procedure;

end package body;
