-----------------------------------------------------------------------
--Filename         : pulse_extender_inst.vhd
--Description      : Instantiation template for pulse_extender_top.
--                 : Passes the pulse-length generic through to the core.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity pulse_extender_inst is
  generic (
    -- Pulse configuration
    GC_PULSE_LEN : positive := 4  -- output pulse length in clock cycles
  );
end entity;

architecture rtl of pulse_extender_inst is
  signal clk : std_logic;
  signal rstn : std_logic;
  signal trigger : std_logic;
  signal pulse_out : std_logic;

begin

  u_pulse_extender : entity work.pulse_extender
    generic map (
      GC_PULSE_LEN => GC_PULSE_LEN
    )
    port map (
      -- Clock, reset, and trigger
      clk     => clk,
      rstn    => rstn,
      trigger => trigger,

      -- Extended output pulse
      pulse_out => pulse_out
    );

end architecture;
