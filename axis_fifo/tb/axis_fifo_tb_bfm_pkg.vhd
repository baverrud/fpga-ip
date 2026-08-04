-----------------------------------------------------------------------
--Filename         : axis_fifo_tb_bfm_pkg.vhd
--Description      : Shared AXI-Stream BFMs for axis_fifo testbenches.
--                 : Encapsulates protocol-correct valid/ready handshakes
--                 : for write, read, and pop helper operations.
--Author           : Rune Baeverrud
--Current Revision : 1.0
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

package axis_fifo_tb_bfm_pkg is

  procedure axis_write(
    signal   clk    : in  std_logic;
    signal   tdata  : out std_logic_vector;
    signal   tvalid : out std_logic;
    signal   tready : in  std_logic;
    constant data   : in  std_logic_vector
  );

  procedure axis_read(
    signal   clk    : in  std_logic;
    signal   tready : out std_logic;
    signal   tvalid : in  std_logic;
    signal   tdata  : in  std_logic_vector;
    variable data   : out std_logic_vector
  );

  procedure axis_pop(
    signal   clk    : in  std_logic;
    signal   tready : out std_logic;
    signal   tvalid : in  std_logic
  );

end package;

package body axis_fifo_tb_bfm_pkg is

  procedure axis_write(
    signal   clk    : in  std_logic;
    signal   tdata  : out std_logic_vector;
    signal   tvalid : out std_logic;
    signal   tready : in  std_logic;
    constant data   : in  std_logic_vector
  ) is
  begin
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
