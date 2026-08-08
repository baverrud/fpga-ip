-----------------------------------------------------------------------
--Filename         : pulse_extender_top.vhd
--Description      : Synthesis wrapper for pulse_extender.
--                 : Passes the pulse-length generic through to the core.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity pulse_extender_top is
  generic (
    GC_PULSE_LEN : positive := 4  -- output pulse length in clock cycles
  );
  port (
    clk       : in  std_logic;
    rstn      : in  std_logic;
    trigger   : in  std_logic;
    pulse_out : out std_logic
  );
end entity;

architecture rtl of pulse_extender_top is
begin

  u_pulse_extender : entity work.pulse_extender
    generic map (
      GC_PULSE_LEN => GC_PULSE_LEN
    )
    port map (
      clk       => clk,
      rstn      => rstn,
      trigger   => trigger,
      pulse_out => pulse_out
    );

end architecture;
