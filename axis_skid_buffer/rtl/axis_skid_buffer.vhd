-----------------------------------------------------------------------
--Filename         : axis_skid_buffer.vhd
--Description      : AXI4-Stream Skid Buffer with:
--                 :  - Two-stage pipeline (pipeline register + skid
--                 :    register) for backpressure absorption.
--                 :  - Bypass path -- when no stall occurs, data flows
--                 :    pipeline-reg -> output with zero combinational
--                 :    delay beyond the register Q output.
--                 :  - Three-state FSM control (EMPTY / ONE / TWO) for
--                 :    cycle-accurate handshake management.
--                 :  - State encoding carries handshake outputs directly:
--                 :      state(1) = s_axis_tready
--                 :      state(0) = m_axis_tvalid
--                 :    Output pins are wired straight from state bits.
--                 :    No combinational cascade from upstream signals.
--                 :  - Ports conforming strictly to AMBA AXI4-Stream
--                 :    specifications.
--                 :  - Fully synchronous active-low reset logic (aresetn).
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axis_skid_buffer is
  generic (
    GC_TDATA_WIDTH  : positive   -- Width of the unified AXI-Stream TDATA bus
  );
  port (
    aclk            : in  std_logic;
    aresetn         : in  std_logic; -- Synchronous reset, active low

    -- Slave Interface (Input transaction payload)
    s_axis_tdata    : in  std_logic_vector (GC_TDATA_WIDTH-1 downto 0);
    s_axis_tvalid   : in  std_logic;
    s_axis_tready   : out std_logic;

    -- Master Interface (Output transaction payload)
    m_axis_tdata    : out std_logic_vector (GC_TDATA_WIDTH-1 downto 0);
    m_axis_tvalid   : out std_logic;
    m_axis_tready   : in  std_logic
  );
end entity;

architecture arch of axis_skid_buffer is

  -- FSM state encoding
  --   state(1) -> s_axis_tready
  --   state(0) -> m_axis_tvalid
  subtype t_state is std_logic_vector(1 downto 0);
  constant EMPTY : t_state := "10"; -- ready=1, valid=0
  constant ONE   : t_state := "11"; -- ready=1, valid=1
  constant TWO   : t_state := "01"; -- ready=0, valid=1

  -- State record
  type t_rec is record
    state           : t_state;
    pipe_data       : std_logic_vector (GC_TDATA_WIDTH-1 downto 0);
    skid_data       : std_logic_vector (GC_TDATA_WIDTH-1 downto 0);
  end record;

  -- Reset / default values
  constant C_REC_DEFAULT : t_rec := (
    state           => EMPTY,
    pipe_data       => (others => '0'),
    skid_data       => (others => '0')
  );

  signal r    : t_rec := C_REC_DEFAULT; -- current state
  signal r_in : t_rec;                  -- next state

begin

  -- Output mapping
  s_axis_tready <= r.state(1);
  m_axis_tvalid <= r.state(0);
  m_axis_tdata  <= r.pipe_data;

  -- Combinational process -- next-state logic
  p_comb : process(r, s_axis_tdata, s_axis_tvalid, m_axis_tready)
    variable v : t_rec;
  begin
    -- recover stored state
    v := r;

    case r.state is

      when EMPTY =>
        if s_axis_tvalid = '1' then
          v.pipe_data := s_axis_tdata;
          v.state     := ONE;
        end if;

      when ONE =>
        if m_axis_tready = '1' then
          -- Downstream accepted the output
          if s_axis_tvalid = '1' then
            -- New data arrives in the same cycle -- reload pipeline
            v.pipe_data := s_axis_tdata;
            -- State stays ONE
          else
            -- No new data -- pipeline drains
            v.state := EMPTY;
          end if;
        else
          -- Downstream stalls
          if s_axis_tvalid = '1' then
            -- Capture current pipeline data into skid register
            v.skid_data := r.pipe_data;
            -- Accept new data into pipeline
            v.pipe_data := s_axis_tdata;
            v.state     := TWO;
          end if;
          -- If no new data, hold state ONE (pipeline unchanged)
        end if;

      when TWO =>
        if m_axis_tready = '1' then
          -- Downstream accepted -- shift skid into pipeline
          v.pipe_data := r.skid_data;
          v.state     := ONE;
        end if;

      when others =>
        -- Safety recovery from illegal/unknown state encodings.
        v.state := EMPTY;

    end case;

    -- store state
    r_in <= v;
  end process;

  -- Registered process -- state update
  p_reg : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        r <= C_REC_DEFAULT;
      else
        r <= r_in;
      end if;
    end if;
  end process;

end architecture;
