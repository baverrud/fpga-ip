-----------------------------------------------------------------------
--Filename         : axis_mux.vhd
--Description      : Parameterizable AXI4-Stream beat multiplexer with:
--                 :  - One input interface per selectable source.
--                 :  - Fair round-robin arbitration.
--                 :  - One-beat holding slot per input for stall safety.
--                 :  - A shared axis_fifo on the output path.
--                 :  - tdata, tvalid, and tready only; no packet framing.
--                 :  - VHDL-2008 two-process state architecture.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axis_mux is
  generic (
    GC_NUM_INPUTS : positive := 4;
    GC_TDATA_WIDTH : positive := 32;
    GC_FIFO_DEPTH : positive range 2 to positive'high := 8
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;

    -- Input AXI4-Stream beat interfaces. Each source has its own one-beat
    -- holding slot inside the mux, so a source may hold valid until accepted.
    s_axis_tdata  : in slv_array_t(0 to GC_NUM_INPUTS-1)(GC_TDATA_WIDTH-1 downto 0);
    s_axis_tvalid : in std_logic_vector(0 to GC_NUM_INPUTS-1);
    s_axis_tready : out std_logic_vector(0 to GC_NUM_INPUTS-1);

    -- Merged AXI4-Stream output. The output FIFO absorbs bursts and applies
    -- registered downstream backpressure to the selected input path.
    m_axis_tdata  : out std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in std_logic;

    -- Occupancy of the shared output FIFO, excluding the input holding slots.
    fifo_count : out unsigned(log2ceil(GC_FIFO_DEPTH) downto 0)
  );
end entity axis_mux;

architecture rtl of axis_mux is

  -- A slot stores a source beat after its input handshake and before the
  -- round-robin arbiter forwards that beat to the output FIFO. Keeping one
  -- slot per source prevents an unselected valid source from changing the
  -- selected payload while the FIFO is stalled.
  type input_slot_t is record
    valid : std_logic;
    data  : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  end record;

  type input_slot_array_t is array (0 to GC_NUM_INPUTS-1) of input_slot_t;

  type rec_t is record
    slots      : input_slot_array_t;
    rr_pointer : integer range 0 to GC_NUM_INPUTS-1;
  end record;

  constant C_SLOT_DEFAULT : input_slot_t := (
    valid => '0',
    data  => (others => '0')
  );

  -- Starting at the final input makes input zero the first winner after reset.
  constant C_REC_DEFAULT : rec_t := (
    slots      => (others => C_SLOT_DEFAULT),
    rr_pointer => GC_NUM_INPUTS - 1
  );

  signal r    : rec_t := C_REC_DEFAULT;
  signal r_in : rec_t;

  -- Internal stream between the arbiter and the required output FIFO.
  signal fifo_s_axis_tdata  : std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
  signal fifo_s_axis_tvalid : std_logic;
  signal fifo_s_axis_tready : std_logic;

begin

  -- The FIFO is intentionally part of this IP rather than left to each user.
  -- It provides a registered output-side ready/valid boundary and stores
  -- bursts that arrive faster than the downstream consumer.
  output_fifo : entity work.axis_fifo
    generic map (
      GC_TDATA_WIDTH => GC_TDATA_WIDTH,
      GC_FIFO_DEPTH  => GC_FIFO_DEPTH
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => fifo_s_axis_tdata,
      s_axis_tvalid => fifo_s_axis_tvalid,
      s_axis_tready => fifo_s_axis_tready,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,
      fifo_count    => fifo_count
    );

  -- Arbitration, input-slot updates, and output-FIFO source generation are
  -- kept in one combinational process. This avoids a delta-cycle race between
  -- a separately computed grant and the state update that consumes it.
  p_comb : process(all)
    variable v             : rec_t;
    variable input_ready   : std_logic_vector(0 to GC_NUM_INPUTS-1);
    variable selected_idx  : integer range 0 to GC_NUM_INPUTS-1;
    variable scan_idx      : integer range 0 to GC_NUM_INPUTS-1;
    variable selected_valid : boolean;
    variable fifo_push     : boolean;
  begin
    v := r;
    input_ready := (others => '0');
    selected_idx := r.rr_pointer;
    selected_valid := false;

    -- Scan strictly after the last winner, wrapping at the final input. The
    -- first valid slot found becomes the only source selected this cycle.
    for offset in 0 to GC_NUM_INPUTS-1 loop
      scan_idx := (r.rr_pointer + 1 + offset) mod GC_NUM_INPUTS;
      if (not selected_valid) and (r.slots(scan_idx).valid = '1') then
        selected_idx := scan_idx;
        selected_valid := true;
      end if;
    end loop;

    fifo_s_axis_tdata  <= (others => '0');
    fifo_s_axis_tvalid <= '0';
    if (aresetn = '1') and selected_valid then
      fifo_s_axis_tdata  <= r.slots(selected_idx).data;
      fifo_s_axis_tvalid <= '1';
    end if;

    -- A FIFO input handshake retires the selected slot. The selected source
    -- may refill its slot on the same edge, which sustains one beat per clock
    -- once the FIFO is ready and also keeps the round-robin order fair.
    fifo_push := (aresetn = '1') and selected_valid and
                 (fifo_s_axis_tready = '1');

    -- Empty slots can accept a source beat. A selected slot can also accept a
    -- replacement on the same edge that its old beat enters the FIFO.
    for i in 0 to GC_NUM_INPUTS-1 loop
      if (r.slots(i).valid = '0') or
         (fifo_push and (selected_idx = i)) then
        input_ready(i) := '1';
      end if;
    end loop;

    if aresetn = '1' then
      s_axis_tready <= input_ready;
    else
      s_axis_tready <= (others => '0');
    end if;

    -- Retire the selected slot before applying a possible replacement input.
    if fifo_push then
      v.slots(selected_idx).valid := '0';
      v.rr_pointer := selected_idx;
    end if;

    -- Capture every accepted source beat in its corresponding holding slot.
    -- At most one source beat per input can be accepted in one clock cycle.
    for i in 0 to GC_NUM_INPUTS-1 loop
      if (aresetn = '1') and (input_ready(i) = '1') and
         (s_axis_tvalid(i) = '1') then
        v.slots(i).valid := '1';
        v.slots(i).data  := s_axis_tdata(i);
      end if;
    end loop;

    r_in <= v;
  end process;

  -- All registered state, including the round-robin position and input
  -- holding slots, changes only on the active clock edge. Reset is synchronous
  -- and active low, matching the axis_fifo used on the output.
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

end architecture rtl;
