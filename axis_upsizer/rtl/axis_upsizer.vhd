-----------------------------------------------------------------------
--Filename         : axis_upsizer.vhd
--Description      : AXI4-Stream width converter (upsizer), 1:N.
--                 : Packs GC_RATIO narrow beats of GC_S_TDATA_WIDTH bits
--                 : into one wide beat of GC_S_TDATA_WIDTH * GC_RATIO
--                 : bits, LSB-first per AMBA AXI4-Stream (the first
--                 : narrow word occupies the low bits of the wide word).
--                 :
--                 : HIGH FMAX / LOW LOGIC (the design goal):
--                 :  - The data path is a pure shift-register accumulator
--                 :    (register concatenation, zero combinational logic)
--                 :    feeding a fully REGISTERED output stage, so the
--                 :    wide payload path has no muxes and no logic.
--                 :  - Full input line rate: the two-stage architecture
--                 :    lets the accumulator prefetch the next group while
--                 :    the output stage still holds the current one.
--                 :  - Registered s_axis_tready with a one-narrow-beat skid
--                 :    register. This removes the input-to-output ready path
--                 :    while retaining full input line rate when flowing.
--                 :  - Canonical two-process method: state record (rec_t)
--                 :    + combinational p_comb + register p_reg, per the
--                 :    fpga-rules hdl_coding_rules.
--                 :
--                 : Assumes packet lengths are multiples of GC_RATIO
--                 : (no TKEEP/TSTRB required). s_axis_tlast is OR'd across
--                 : the group and forwarded on the matching output beat.
--                 :
--                 : AXI R-CHANNEL SIDEBANDS: carries rresp on every wide
--                 : output beat and passes rid through. Responses must be
--                 : uniform across each packed group; a mismatch is an
--                 : assertion failure because one output beat has one
--                 : response. Mapping: tdata=rdata, tlast=rlast,
--                 : rresp=rresp, rid=rid.
--Author           : Rune Baeverrud
--Current Revision : 1.20
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axis_upsizer is
  generic (
    -- Narrow (input) beat width in bits.
    GC_S_TDATA_WIDTH : positive := 128;
    -- Width upsize ratio: output width = GC_S_TDATA_WIDTH * GC_RATIO.
    GC_RATIO : positive := 4;
    -- AXI R ID width carried through (registered pass-through).
    GC_ID_WIDTH : positive := 4
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;  -- synchronous, active low

    -- Slave interface (narrow input)
    s_axis_tdata : in std_logic_vector(GC_S_TDATA_WIDTH-1 downto 0);
    s_axis_tlast : in std_logic := '0';                                             -- burst end (ratio-aligned)
    s_axis_rresp : in std_logic_vector(1 downto 0) := (others => '0');              -- AXI R response (per beat)
    s_axis_rid   : in std_logic_vector(GC_ID_WIDTH-1 downto 0) := (others => '0');  -- AXI R ID (pass-through)
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;

    -- Master interface (wide output)
    m_axis_tdata  : out std_logic_vector((GC_S_TDATA_WIDTH*GC_RATIO)-1 downto 0);
    m_axis_tlast  : out std_logic;
    m_axis_rresp  : out std_logic_vector(1 downto 0);
    m_axis_rid    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic
  );
end entity;

architecture rtl of axis_upsizer is

  constant C_M_WIDTH : positive := GC_S_TDATA_WIDTH * GC_RATIO;

  ---------------------------------------------------------------------
  -- State record (all registered state; single source for reset).
  --
  -- Accumulator (source of the wide word). New narrow beat enters at the
  -- TOP (MSB) and existing content shifts DOWN, so after GC_RATIO beats
  -- the FIRST beat is in the LOW bits:
  --   acc = [beat R-1 | ... | beat 1 | beat 0]   (LSB-first packing)
  --
  -- Registered output stage (holds one wide beat for the master).
  -- The skid register holds one narrow beat when the output stage and the
  -- accumulator are full and downstream backpressure arrives. It lets the
  -- input ready signal remain registered without losing line rate.
  ---------------------------------------------------------------------
  type rec_t is record
    acc        : std_logic_vector(C_M_WIDTH-1 downto 0);         -- group under assembly
    cnt        : integer range 0 to GC_RATIO;                    -- beats in acc
    tlast_acc  : std_logic;                                      -- tlast OR'd across group
    rresp_acc  : std_logic_vector(1 downto 0);                   -- response for group
    rid_acc    : std_logic_vector(GC_ID_WIDTH-1 downto 0);       -- ID for group
    out_data   : std_logic_vector(C_M_WIDTH-1 downto 0);         -- wide output beat
    out_tlast  : std_logic;
    out_rresp  : std_logic_vector(1 downto 0);
    out_rid    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
    out_valid  : std_logic;
    skid_data  : std_logic_vector(GC_S_TDATA_WIDTH-1 downto 0);
    skid_tlast : std_logic;
    skid_rresp : std_logic_vector(1 downto 0);
    skid_rid   : std_logic_vector(GC_ID_WIDTH-1 downto 0);
    skid_valid : std_logic;
    s_ready    : std_logic;
  end record;

  constant C_REC_DEFAULT : rec_t := (
    acc        => (others => '0'),
    cnt        => 0,
    tlast_acc  => '0',
    rresp_acc  => (others => '0'),
    rid_acc    => (others => '0'),
    out_data   => (others => '0'),
    out_tlast  => '0',
    out_rresp  => (others => '0'),
    out_rid    => (others => '0'),
    out_valid  => '0',
    skid_data  => (others => '0'),
    skid_tlast => '0',
    skid_rresp => (others => '0'),
    skid_rid   => (others => '0'),
    skid_valid => '0',
    s_ready    => '1');

  signal r : rec_t := C_REC_DEFAULT;  -- current state
  signal r_in : rec_t;  -- next state

begin

  -- Combinational next-state / output process (two-process method).
  --
  -- PERFORMANCE NOTE: s_axis_tready is registered, so m_axis_tready cannot
  -- form an input-to-output combinational path. The one-beat skid register
  -- absorbs a late downstream stall and the accumulator/output pair still
  -- sustain one accepted narrow beat per clock while flowing. All wide
  -- outputs are driven straight from state registers, so the 512-bit data
  -- path carries no logic and Fmax stays high.
  p_comb : process(all)
    variable v          : rec_t;
    variable v_transfer : boolean;
    variable v_accept   : boolean;
  begin
    -- (1) default: recover current state.
    v := r;

    -- The accumulator empties into the output stage this cycle when it is
    -- full AND the output stage is free (idle, or being drained this cycle
    -- - the consumer samples the old word at the edge, so the register
    -- can be overwritten).
    v_transfer := (r.cnt = GC_RATIO) and
                  ((r.out_valid = '0') or (m_axis_tready = '1'));

    -- (2) next-state and output logic.

    -- Registered outputs: the wide data path carries no combinational
    -- logic, which is what keeps Fmax high at large widths (e.g. 512 bits
    -- @ 250 MHz).
    m_axis_tdata  <= r.out_data;
    m_axis_tlast  <= r.out_tlast;
    m_axis_rresp  <= r.out_rresp;
    m_axis_rid    <= r.out_rid;
    m_axis_tvalid <= r.out_valid;

    -- Registered slave ready. Capacity is either free space in the
    -- accumulator or the one-beat skid register. The output depends only
    -- on registered state, never directly on m_axis_tready.
    s_axis_tready <= r.s_ready;

    -- Output stage handshake (drain).
    if (r.out_valid = '1') and (m_axis_tready = '1') then
      v.out_valid := '0';
    end if;

    -- Accumulator -> output transfer (may coincide with the drain above;
    -- net effect is out_valid stays high for a back-to-back stream).
    if v_transfer then
      v.out_data  := r.acc;
      v.out_tlast := r.tlast_acc;
      v.out_rresp := r.rresp_acc;
      v.out_rid   := r.rid_acc;
      v.out_valid := '1';
    end if;

    -- Narrow input handshake. If the accumulator is full and the output
    -- stage cannot accept it this cycle, the registered ready signal permits
    -- exactly one beat into the skid register. That beat is moved into a new
    -- accumulator group when the current wide beat drains.
    v_accept := (s_axis_tvalid = '1') and (r.s_ready = '1');
    if v_accept and (s_axis_tlast = '1') then
      assert (r.cnt = GC_RATIO-1) or (GC_RATIO = 1)
        report "axis_upsizer: tlast is not ratio-aligned"
        severity failure;
    end if;
    if v_transfer then
      if r.skid_valid = '1' then
        v.acc       := r.skid_data & r.acc(C_M_WIDTH-1 downto GC_S_TDATA_WIDTH);
        v.tlast_acc := r.skid_tlast;
        v.rresp_acc := r.skid_rresp;
        v.rid_acc   := r.skid_rid;
        v.cnt       := 1;
        v.skid_valid := '0';
      elsif v_accept then
        v.acc       := s_axis_tdata & r.acc(C_M_WIDTH-1 downto GC_S_TDATA_WIDTH);
        v.tlast_acc := s_axis_tlast;
        v.rresp_acc := s_axis_rresp;
        v.rid_acc   := s_axis_rid;
        v.cnt       := 1;
      else
        v.tlast_acc := '0';
        v.rresp_acc := (others => '0');
        v.rid_acc   := (others => '0');
        v.cnt       := 0;
      end if;
    elsif v_accept then
      if r.cnt < GC_RATIO then
        v.acc := s_axis_tdata & r.acc(C_M_WIDTH-1 downto GC_S_TDATA_WIDTH);
        if r.cnt = 0 then
          v.tlast_acc := s_axis_tlast;
          v.rresp_acc := s_axis_rresp;
          v.rid_acc   := s_axis_rid;
        else
          assert s_axis_rresp = r.rresp_acc
            report "axis_upsizer: rresp changed within packed group"
            severity failure;
          assert s_axis_rid = r.rid_acc
            report "axis_upsizer: rid changed within packed group"
            severity failure;
          v.tlast_acc := r.tlast_acc or s_axis_tlast;
        end if;
        v.cnt := r.cnt + 1;
      else
        v.skid_data  := s_axis_tdata;
        v.skid_tlast := s_axis_tlast;
        v.skid_rresp := s_axis_rresp;
        v.skid_rid   := s_axis_rid;
        v.skid_valid := '1';
      end if;
    elsif v_transfer then
      v.tlast_acc := '0';
      v.rresp_acc := (others => '0');
      v.rid_acc   := (others => '0');
      v.cnt       := 0;
    end if;

    -- Calculate the next registered ready value after all state movement.
    if (v.cnt < GC_RATIO) or (v.skid_valid = '0') then
      v.s_ready := '1';
    else
      v.s_ready := '0';
    end if;

    -- (3) no soft reset in this core; global aresetn only.
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
