-----------------------------------------------------------------------
--Filename         : axis_downsizer.vhd
--Description      : AXI4-Stream width converter (downsizer), N:1.
--                 : Unpacks one wide beat of GC_M_TDATA_WIDTH * GC_RATIO
--                 : bits into GC_RATIO narrow beats of GC_M_TDATA_WIDTH
--                 : bits, LSB-first per AMBA AXI4-Stream (the first
--                 : narrow word comes from the low bits of the wide word).
--                 :
--                 : HIGH FMAX / LOW LOGIC (the design goal):
--                 :  - The wide data path is a pure holding register (zero
--                 :    combinational logic on the wide bus). A slice-select
--                 :    mux feeds a fully REGISTERED narrow output stage, so
--                 :    the output runs at full line rate (one narrow beat
--                 :    per clock) while the input accepts one wide beat
--                 :    every GC_RATIO output cycles.
--                 :  - Registered s_axis_tready: the input ready depends
--                 :    only on a registered empty flag, so there is no
--                 :    input-to-output combinational ready path and no
--                 :    over-commit when the downstream stalls.
--                 :  - Canonical two-process method: state record (rec_t)
--                 :    + combinational p_comb + register p_reg, per the
--                 :    fpga-rules hdl_coding_rules.
--                 :
--                 : AXI R-CHANNEL SIDEBANDS: carries rresp and rid through.
--                 : One input wide beat represents one group of GC_RATIO
--                 : narrow beats, so the input rresp/rid are uniform across
--                 : the whole group by construction and are forwarded on
--                 : every output beat. Mapping: tdata=rdata, tlast=rlast,
--                 : rresp=rresp, rid=rid.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axis_downsizer is
  generic (
    -- Narrow (output) beat width in bits.
    GC_M_TDATA_WIDTH : positive := 128;
    -- Width downsize ratio: input width = GC_M_TDATA_WIDTH * GC_RATIO.
    GC_RATIO : positive := 4;
    -- AXI R ID width carried through (registered pass-through).
    GC_ID_WIDTH : positive := 4
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;  -- synchronous, active low

    -- Slave interface (wide input)
    s_axis_tdata : in std_logic_vector((GC_M_TDATA_WIDTH*GC_RATIO)-1 downto 0);
    s_axis_tlast : in std_logic := '0';                                             -- packet end (on the last slice)
    s_axis_rresp : in std_logic_vector(1 downto 0) := (others => '0');              -- AXI R response (per group)
    s_axis_rid   : in std_logic_vector(GC_ID_WIDTH-1 downto 0) := (others => '0');  -- AXI R ID (per group)
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;

    -- Master interface (narrow output)
    m_axis_tdata  : out std_logic_vector(GC_M_TDATA_WIDTH-1 downto 0);
    m_axis_tlast  : out std_logic;
    m_axis_rresp  : out std_logic_vector(1 downto 0);
    m_axis_rid    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic
  );
end entity;

architecture rtl of axis_downsizer is

  constant C_M_WIDTH : positive := GC_M_TDATA_WIDTH * GC_RATIO;

  ---------------------------------------------------------------------
  -- State record (all registered state; single source for reset).
  --
  -- Input stage (in_data): holds one wide beat while its GC_RATIO narrow
  -- slices are emitted. in_valid is cleared as soon as the group's last
  -- slice is committed to the output stage, which is what lets the input
  -- accept the next wide beat exactly one output cycle before the previous
  -- group finishes draining (no output bubble).
  --
  -- Registered output stage (out_data): holds one narrow beat for the
  -- master. slic selects which slice of in_data is in the output stage.
  ---------------------------------------------------------------------
  type rec_t is record
    in_data   : std_logic_vector(C_M_WIDTH-1 downto 0);         -- wide beat being sliced
    in_valid  : std_logic;                                      -- in_data holds a group
    in_tlast  : std_logic;                                      -- packet end on the wide beat
    in_rresp  : std_logic_vector(1 downto 0);                   -- response for the group
    in_rid    : std_logic_vector(GC_ID_WIDTH-1 downto 0);       -- ID for the group
    slic      : integer range 0 to GC_RATIO-1;                  -- slice in the output stage
    out_data  : std_logic_vector(GC_M_TDATA_WIDTH-1 downto 0);  -- narrow output beat
    out_tlast : std_logic;
    out_rresp : std_logic_vector(1 downto 0);
    out_rid   : std_logic_vector(GC_ID_WIDTH-1 downto 0);
    out_valid : std_logic;
    s_ready   : std_logic;
  end record;

  constant C_REC_DEFAULT : rec_t := (
    in_data   => (others => '0'),
    in_valid  => '0',
    in_tlast  => '0',
    in_rresp  => (others => '0'),
    in_rid    => (others => '0'),
    slic      => 0,
    out_data  => (others => '0'),
    out_tlast => '0',
    out_rresp => (others => '0'),
    out_rid   => (others => '0'),
    out_valid => '0',
    s_ready   => '1');

  signal r : rec_t := C_REC_DEFAULT;  -- current state
  signal r_in : rec_t;  -- next state

begin

  -- Combinational next-state / output process (two-process method).
  --
  -- PERFORMANCE NOTE: the wide input bus (C_M_WIDTH bits) is pure storage.
  -- The only combinational logic on a data path is the narrow slice-select
  -- mux (RATIO:1 on GC_M_TDATA_WIDTH bits) feeding the registered output
  -- stage, so Fmax stays high at large widths. s_axis_tready is registered
  -- and depends only on the empty flag - never on m_axis_tready - so there
  -- is no input-to-output combinational path.
  p_comb : process(all)
    variable v           : rec_t;
    variable v_load      : boolean;
    variable v_out_drain : boolean;
    variable v_out_free  : boolean;
    variable v_next_slic : integer range 0 to GC_RATIO-1;
  begin
    -- (1) default: recover current state.
    v := r;

    -- (2) next-state and output logic.

    -- Registered outputs: the narrow data path carries only the output
    -- stage register; the wide bus is never combinational.
    m_axis_tdata  <= r.out_data;
    m_axis_tlast  <= r.out_tlast;
    m_axis_rresp  <= r.out_rresp;
    m_axis_rid    <= r.out_rid;
    m_axis_tvalid <= r.out_valid;
    s_axis_tready <= r.s_ready;

    -- Accept a new wide beat when the input stage is empty. in_valid is
    -- cleared when the group's last slice is committed to the output stage,
    -- so the input accepts one wide beat every GC_RATIO output cycles while
    -- the source streams back-to-back.
    v_load := (s_axis_tvalid = '1') and (r.s_ready = '1');
    if v_load then
      v.in_data  := s_axis_tdata;
      v.in_valid := '1';
      v.in_tlast := s_axis_tlast;
      v.in_rresp := s_axis_rresp;
      v.in_rid   := s_axis_rid;
    end if;

    -- Output stage handshake (drain).
    v_out_drain := (r.out_valid = '1') and (m_axis_tready = '1');
    if v_out_drain then
      v.out_valid := '0';
    end if;
    v_out_free := (r.out_valid = '0') or v_out_drain;

    -- Load the next narrow beat into the output stage (one per free cycle,
    -- so the output runs back-to-back at full line rate).
    if v_out_free then
      if r.in_valid = '1' then
        if r.slic = GC_RATIO-1 then
          -- Current group's last slice was in the output stage and has just
          -- drained. in_data now holds the next group (loaded at the group
          -- boundary while the last slice was stalled): emit its slice 0.
          v.out_data  := v.in_data(GC_M_TDATA_WIDTH-1 downto 0);
          if GC_RATIO = 1 then
            v.out_tlast := v.in_tlast;  -- single-slice group is the last
          else
            v.out_tlast := '0';
          end if;
          v.out_rresp := v.in_rresp;
          v.out_rid   := v.in_rid;
          v.out_valid := '1';
          v.slic      := 0;
          if GC_RATIO = 1 then
            v.in_valid := '0';  -- single-slice group fully committed
          end if;
        else
          -- Emit the next slice of the current group.
          v_next_slic := r.slic + 1;
          v.out_data  := v.in_data((v_next_slic+1)*GC_M_TDATA_WIDTH-1 downto v_next_slic*GC_M_TDATA_WIDTH);
          if v_next_slic = GC_RATIO-1 then
            v.out_tlast := v.in_tlast;  -- last slice of the group
          else
            v.out_tlast := '0';
          end if;
          v.out_rresp := v.in_rresp;
          v.out_rid   := v.in_rid;
          v.out_valid := '1';
          v.slic      := v_next_slic;
          -- Group is fully committed once its last slice leaves in_data;
          -- free the input stage (unless a new group was accepted this edge).
          if (v_next_slic = GC_RATIO-1) and (not v_load) then
            v.in_valid := '0';
          end if;
        end if;
      elsif v_load then
        -- Fresh group accepted with the output stage free: stage slice 0
        -- immediately so the output never bubbles between groups.
        v.out_data  := s_axis_tdata(GC_M_TDATA_WIDTH-1 downto 0);
        if GC_RATIO = 1 then
          v.out_tlast := s_axis_tlast;  -- single-slice group is the last
        else
          v.out_tlast := '0';
        end if;
        v.out_rresp := s_axis_rresp;
        v.out_rid   := s_axis_rid;
        v.out_valid := '1';
        v.slic      := 0;
        if GC_RATIO = 1 then
          v.in_valid := '0';  -- single-slice group fully committed
        end if;
      end if;
    end if;

    -- (3) registered slave ready: accept when the input stage is empty.
    if v.in_valid = '0' then
      v.s_ready := '1';
    else
      v.s_ready := '0';
    end if;

    r_in <= v;
  end process;

  -- Register process: global reset handled here only.
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
