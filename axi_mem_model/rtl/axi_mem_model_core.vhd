-----------------------------------------------------------------------
--Filename         : axi_mem_model_core.vhd
--Description      : Core beat-sequencing engine for axi_mem_model.
--                 : Receives delayed AR info from the AR-side
--                 : axis_latency_gen and generates per-beat response
--                 : entries for the beat-gap axis_latency_gen.
--                 :
--                 : Emulates address-based read data patterns:
--                 : 32-bit address words for buses >= 4 bytes,
--                 : 16-bit address values for 2-byte buses, and
--                 : 8-bit address values for 1-byte buses.
--                 :
--                 : Two-process register-transfer style (Gaisler).
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_mem_model_core is
  generic (
    GC_DATA_BYTES  : positive := 64;    -- Bus width in bytes
    GC_ADDR_WIDTH  : positive := 49;    -- Address width
    GC_ID_WIDTH    : positive := 6      -- ID width
  );
  port (
    aclk    : in  std_logic;
    aresetn : in  std_logic;

    -- Delayed AR info from AR-side axis_latency_gen
    -- Packed: {arid, araddr, arlen}
    s_axis_tdata   : in  std_logic_vector(GC_ID_WIDTH + GC_ADDR_WIDTH + 8 - 1 downto 0);
    s_axis_tvalid  : in  std_logic;
    s_axis_tready  : out std_logic;

    -- Per-beat response to R-side axis_latency_gen
    -- Packed: {rid, rdata, rresp, rlast}
    m_axis_tdata   : out std_logic_vector(GC_ID_WIDTH + 8*GC_DATA_BYTES + 2 + 1 - 1 downto 0);
    m_axis_tvalid  : out std_logic;
    m_axis_tready  : in  std_logic
  );
end entity;

architecture rtl of axi_mem_model_core is

  constant C_RDATA_WIDTH : positive := 8 * GC_DATA_BYTES;

  -- -----------------------------------------------------------------
  -- AR info field offsets (s_axis_tdata)
  -- Layout: [arid][araddr][arlen]  — MSB to LSB
  -- -----------------------------------------------------------------
  constant C_ARLEN_LOW   : natural := 0;
  constant C_ARLEN_HIGH  : natural := 7;
  constant C_ADDR_LOW    : natural := C_ARLEN_HIGH + 1;
  constant C_ADDR_HIGH   : natural := C_ADDR_LOW + GC_ADDR_WIDTH - 1;
  constant C_ID_LOW      : natural := C_ADDR_HIGH + 1;
  constant C_ID_HIGH     : natural := C_ID_LOW + GC_ID_WIDTH - 1;

  -- -----------------------------------------------------------------
  -- Beat response field offsets (m_axis_tdata)
  -- Layout: [rid][rdata][rresp][rlast]  — MSB to LSB
  -- -----------------------------------------------------------------
  constant C_RLAST_LOW   : natural := 0;
  constant C_RLAST_HIGH  : natural := 0;           -- 1 bit
  constant C_RRESP_LOW   : natural := C_RLAST_HIGH + 1;
  constant C_RRESP_HIGH  : natural := C_RRESP_LOW + 1;  -- 2 bits
  constant C_RDATA_LOW   : natural := C_RRESP_HIGH + 1;
  constant C_RDATA_HIGH  : natural := C_RDATA_LOW + C_RDATA_WIDTH - 1;
  constant C_RID_LOW     : natural := C_RDATA_HIGH + 1;
  constant C_RID_HIGH    : natural := C_RID_LOW + GC_ID_WIDTH - 1;

  constant C_AR_WIDTH : natural := C_ID_HIGH + 1;   -- s_axis_tdata width
  constant C_R_WIDTH  : natural := C_RID_HIGH + 1;  -- m_axis_tdata width

  subtype ar_payload_t is std_logic_vector(C_AR_WIDTH-1 downto 0);
  subtype r_payload_t  is std_logic_vector(C_R_WIDTH-1 downto 0);
  subtype rdata_t      is std_logic_vector(C_RDATA_WIDTH-1 downto 0);
  subtype ar_id_t      is std_logic_vector(GC_ID_WIDTH-1 downto 0);
  subtype ar_addr_t    is unsigned(GC_ADDR_WIDTH-1 downto 0);
  subtype ar_len_t     is unsigned(7 downto 0);

  function is_supported_data_width(data_bytes : positive) return boolean is
  begin
    return (data_bytes = 1)  or (data_bytes = 2)  or
           (data_bytes = 4)  or (data_bytes = 8)  or
           (data_bytes = 16) or (data_bytes = 32) or
           (data_bytes = 64) or (data_bytes = 128);
  end function;

  function get_arid(payload : ar_payload_t) return ar_id_t is
  begin
    return payload(C_ID_HIGH downto C_ID_LOW);
  end function;

  function get_araddr(payload : ar_payload_t) return ar_addr_t is
  begin
    return unsigned(payload(C_ADDR_HIGH downto C_ADDR_LOW));
  end function;

  function get_arlen(payload : ar_payload_t) return ar_len_t is
  begin
    return unsigned(payload(C_ARLEN_HIGH downto C_ARLEN_LOW));
  end function;

  function beat_addr(base_addr : ar_addr_t; beat_idx : ar_len_t) return ar_addr_t is
  begin
    -- Consecutive beats advance by GC_DATA_BYTES in the address space
    -- (AXI INCR semantics for a read burst of width GC_DATA_BYTES).
    return base_addr + to_unsigned(to_integer(beat_idx) * GC_DATA_BYTES, GC_ADDR_WIDTH);
  end function;

  function make_rdata(addr : ar_addr_t) return rdata_t is
    variable v_data   : rdata_t := (others => '0');
    variable v_addr32 : unsigned(31 downto 0);
  begin
    -- Deterministic address-derived data pattern, sized to bus width:
    --   ≥4 bytes: each 32-bit word returns a 32-bit address
    --   2 bytes:  16-bit address value
    --   1 byte:    8-bit address value
    if GC_DATA_BYTES >= 4 then
      v_addr32 := resize(addr, 32);
      for word_idx in 0 to GC_DATA_BYTES/4 - 1 loop
        v_data(32*word_idx+31 downto 32*word_idx) :=
          std_logic_vector(v_addr32 + word_idx*4);
      end loop;
    elsif GC_DATA_BYTES = 2 then
      v_data(15 downto 0) := std_logic_vector(resize(addr, 16));
    else  -- GC_DATA_BYTES = 1
      v_data(7 downto 0) := std_logic_vector(resize(addr, 8));
    end if;

    return v_data;
  end function;

  function pack_rbeat(id   : ar_id_t;
                      data : rdata_t;
                      last : std_logic) return r_payload_t is
    variable payload : r_payload_t := (others => '0');
  begin
    payload(C_RLAST_LOW) := last;
    payload(C_RRESP_HIGH downto C_RRESP_LOW) := "00";
    payload(C_RDATA_HIGH downto C_RDATA_LOW) := data;
    payload(C_RID_HIGH   downto C_RID_LOW)   := id;
    return payload;
  end function;

  -- -----------------------------------------------------------------
  -- State machine
  -- Pushes beats at 1/cycle into the R-side gen; gen's FIFO
  -- depth handles pipelining and inter-beat spacing.
  -- -----------------------------------------------------------------
  type state_t is (S_WAIT_AR, S_SEND_BEATS);

  type reg_t is record
    state    : state_t;
    beat_idx : unsigned(7 downto 0);
    cur_id   : ar_id_t;
    cur_addr : ar_addr_t;
    cur_len  : ar_len_t;
    -- Registered R-side output
    r_tdata  : std_logic_vector(C_R_WIDTH-1 downto 0);
    r_tvalid : std_logic;
  end record;

  constant C_REG_DEFAULT : reg_t := (
    state    => S_WAIT_AR,
    beat_idx => (others => '0'),
    cur_id   => (others => '0'),
    cur_addr => (others => '0'),
    cur_len  => (others => '0'),
    r_tdata  => (others => '0'),
    r_tvalid => '0'
  );

  signal r, r_in : reg_t := C_REG_DEFAULT;

begin

  assert is_supported_data_width(GC_DATA_BYTES)
    report "axi_mem_model_core: GC_DATA_BYTES must be 2^n for n=0..7"
    severity failure;

  -- =================================================================
  -- p_comb : Combinatorial next-state and output logic
  -- =================================================================
  p_comb : process(r, s_axis_tdata, s_axis_tvalid, m_axis_tready)
    variable v           : reg_t;
    variable v_beat_addr : ar_addr_t;
    variable v_next_idx  : ar_len_t;
    variable v_last      : std_logic;
  begin
    v := r;

    -- Defaults
    s_axis_tready <= '0';

    case r.state is

      when S_WAIT_AR =>
        -- Clear R-side valid (we may be returning from a burst) and
        -- assert AR ready unconditionally — the AR-side latency gen
        -- handles its own FIFO backpressure.
        v.r_tvalid := '0';
        s_axis_tready <= '1';
        if s_axis_tvalid = '1' then
          v.cur_id   := get_arid(s_axis_tdata);
          v.cur_addr := get_araddr(s_axis_tdata);
          v.cur_len  := get_arlen(s_axis_tdata);
          v.beat_idx := (others => '0');

          v_last := '1' when v.cur_len = 0 else '0';
          v.r_tdata := pack_rbeat(v.cur_id, make_rdata(v.cur_addr), v_last);
          v.r_tvalid := '1';
          v.state    := S_SEND_BEATS;
        end if;

      when S_SEND_BEATS =>
        -- Push beats at max rate; R-side gen's timer provides
        -- inter-beat spacing.  m_axis_tready drops when gen's
        -- FIFO fills (natural backpressure).
        if m_axis_tready = '1' and r.r_tvalid = '1' then
          if r.beat_idx = r.cur_len then
            v.r_tvalid := '0';
            v.state    := S_WAIT_AR;
          else
            v_next_idx  := r.beat_idx + 1;
            v_beat_addr := beat_addr(r.cur_addr, v_next_idx);
            v_last      := '1' when v_next_idx = r.cur_len else '0';

            v.beat_idx := v_next_idx;
            v.r_tdata  := pack_rbeat(r.cur_id, make_rdata(v_beat_addr), v_last);
            -- stay in S_SEND_BEATS
          end if;
        end if;

    end case;

    -- Drive registered outputs
    m_axis_tdata  <= r.r_tdata;
    m_axis_tvalid <= r.r_tvalid;

    r_in <= v;
  end process p_comb;

  -- =================================================================
  -- p_reg : Synchronous register update with reset
  -- =================================================================
  p_reg : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        r <= C_REG_DEFAULT;
      else
        r <= r_in;
      end if;
    end if;
  end process p_reg;

end architecture;
