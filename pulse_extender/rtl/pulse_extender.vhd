-----------------------------------------------------------------------
--Filename         : pulse_extender.vhd
--Description      : Level-gated pulse extender.
--                 : When the output is idle, a high level on trigger
--                 : drives pulse_out high for exactly GC_PULSE_LEN
--                 : clock cycles. The trigger is sampled only while the
--                 : output is idle (no edge detection); a held-high
--                 : trigger restarts the pulse each time it expires.
--                 : pulse_out is a registered output (no combinational
--                 : path from the counter to the port).
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity pulse_extender is
  generic (
    GC_PULSE_LEN : positive := 4  -- output pulse length in clock cycles
  );
  port (
    clk       : in  std_logic;  -- clock
    rstn      : in  std_logic;  -- active-low synchronous reset
    trigger   : in  std_logic;  -- trigger input (sampled only while idle)
    pulse_out : out std_logic   -- extended output pulse
  );
end entity;

architecture rtl of pulse_extender is

  -- State record
  type rec_t is record
    cnt   : natural range 0 to GC_PULSE_LEN;  -- remaining pulse cycles
    pulse : std_logic;                        -- registered pulse output
  end record;

  constant C_REC_DEFAULT : rec_t := (cnt => 0, pulse => '0');

  signal r    : rec_t := C_REC_DEFAULT;  -- current state
  signal r_in : rec_t;                   -- next state

begin

  -- Registered output: high while the pulse counter is active.
  pulse_out <= r.pulse;

  -- Combinational process
  p_comb : process(all)
    variable v : rec_t;
  begin
    v := r;  -- (1) default: recover current state

    if trigger = '1' and r.cnt = 0 then
      -- Start a new pulse: trigger is sampled only while idle
      v.cnt := GC_PULSE_LEN;
    elsif r.cnt > 0 then
      -- Count down while the pulse is active
      v.cnt := r.cnt - 1;
    end if;

    -- Derive the output from the next-state counter so the registered
    -- pulse_out changes on the same edges as the previous combinational
    -- version (no added latency, exact GC_PULSE_LEN cycles).
    v.pulse := '1' when v.cnt > 0 else '0';

    r_in <= v;  -- latch next state
  end process;

  -- Register process (global reset only)
  p_reg : process(clk)
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        r <= C_REC_DEFAULT;
      else
        r <= r_in;
      end if;
    end if;
  end process;

end architecture;
