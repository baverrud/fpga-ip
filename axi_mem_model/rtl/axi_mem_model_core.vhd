-----------------------------------------------------------------------
--Filename         : axi_mem_model_core.vhd
--Description      : Core beat-sequencing engine for axi_mem_model.
--
--                 Sits between two axis_latency_gen instances:
--                   IN:  delayed AR info   ← AR-side gen
--                   OUT: per-beat response → R-side (beat-gap) gen
--
--                 On each AR it generates (cur_len+1) beats at maximum
--                 rate (1 per cycle), pushing them into the R-side gen.
--                 The R-side gen's FIFO and timer provide inter-beat
--                 spacing and pipeline elasticity.
--
--                 Data pattern: address-derived (each beat returns a
--                 function of the address), suitable for verification.
--
--                 Zero-idle back-to-back: if the next AR arrives before
--                 the last beat is consumed, the next transaction starts
--                 immediately without dropping r_valid.
--
--                 Two-process register-transfer style (Gaisler).
--
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

    -- AXI4 AR channel — receives delayed ARs from the AR-side gen
    ar_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : in  std_logic_vector(7 downto 0);
    ar_valid : in  std_logic;
    ar_ready : out std_logic;

    -- AXI4 R channel — drives beats into the R-side (beat-gap) gen
    r_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : out std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : out std_logic_vector(1 downto 0);
    r_last  : out std_logic;
    r_valid : out std_logic;
    r_ready : in  std_logic
  );
end entity;

architecture rtl of axi_mem_model_core is

  constant C_RDATA_WIDTH : positive := 8 * GC_DATA_BYTES;

  -- Convenience subtypes
  subtype rdata_t      is std_logic_vector(C_RDATA_WIDTH-1 downto 0);
  subtype ar_id_t      is std_logic_vector(GC_ID_WIDTH-1 downto 0);
  subtype ar_addr_t    is unsigned(GC_ADDR_WIDTH-1 downto 0);
  subtype ar_len_t     is unsigned(7 downto 0);

  -- =================================================================
  -- Helper: validate bus width at elaboration
  -- =================================================================
  function is_supported_data_width(data_bytes : positive) return boolean is
  begin
    return (data_bytes = 1)  or (data_bytes = 2)  or
           (data_bytes = 4)  or (data_bytes = 8)  or
           (data_bytes = 16) or (data_bytes = 32) or
           (data_bytes = 64) or (data_bytes = 128);
  end function;

  -- =================================================================
  -- Helper: compute beat address within a burst
  --   AXI INCR semantics: each consecutive beat advances by
  --   GC_DATA_BYTES.  beat_idx=0 → base_addr, beat_idx=1 → +DATA_BYTES.
  -- =================================================================
  function beat_addr(base_addr : ar_addr_t; beat_idx : ar_len_t) return ar_addr_t is
  begin
    return base_addr + to_unsigned(to_integer(beat_idx) * GC_DATA_BYTES, GC_ADDR_WIDTH);
  end function;

  -- =================================================================
  -- Helper: deterministic address-derived data pattern
  --   Sized to bus width:
  --     ≥4 bytes : each 32-bit word slot holds its byte address
  --                e.g. addr=0x1000 → word0=0x1000, word1=0x1004...
  --     2 bytes  : 16-bit address value
  --     1 byte   : 8-bit address value
  -- =================================================================
  function make_rdata(addr : ar_addr_t) return rdata_t is
    variable v_data   : rdata_t := (others => '0');
    variable v_addr32 : unsigned(31 downto 0);
  begin
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

  -- =================================================================
  -- State machine
  --   S_WAIT_AR    — idle, waiting for the next AR
  --   S_SEND_BEATS — pushing beats at 1/cycle into the R-side gen
  --
  --   The R-side gen's FIFO absorbs pipeline bubbles; its internal
  --   timer enforces the actual inter-beat gap.  This core just
  --   produces beats as fast as the R-side gen can accept them.
  -- =================================================================
  type state_t is (S_WAIT_AR, S_SEND_BEATS);

  type reg_t is record
    state    : state_t;               -- Current state
    beat_idx : unsigned(7 downto 0);  -- Next beat index (0-based)
    cur_id   : ar_id_t;               -- AR ID of current transaction
    cur_addr : ar_addr_t;             -- Base address of current transaction
    cur_len  : ar_len_t;              -- Burst length (0 = single beat)

    -- Registered R-channel outputs (combed in p_comb, clocked in p_reg)
    r_id    : ar_id_t;
    r_data  : rdata_t;
    r_resp  : std_logic_vector(1 downto 0);
    r_last  : std_logic;
    r_valid : std_logic;
  end record;

  constant C_REG_DEFAULT : reg_t := (
    state    => S_WAIT_AR,
    beat_idx => (others => '0'),
    cur_id   => (others => '0'),
    cur_addr => (others => '0'),
    cur_len  => (others => '0'),
    r_id     => (others => '0'),
    r_data   => (others => '0'),
    r_resp   => (others => '0'),
    r_last   => '0',
    r_valid  => '0'
  );

  signal r, r_in : reg_t := C_REG_DEFAULT;

begin

  assert is_supported_data_width(GC_DATA_BYTES)
    report "axi_mem_model_core: GC_DATA_BYTES must be 2^n for n=0..7"
    severity failure;

  -- =================================================================
  -- p_comb : Combinatorial next-state and output logic
  --
  --   Reads:  current register (r), AR inputs, r_ready
  --   Writes: next register (r_in), AR/R output ports
  --
  --   All R-channel outputs are registered — they reflect r.* and get
  --   updated on the next clock edge via p_reg.
  -- =================================================================
  p_comb : process(r, ar_id, ar_addr, ar_len, ar_valid, r_ready)
    variable v           : reg_t;
    variable v_beat_addr : ar_addr_t;
    variable v_next_idx  : ar_len_t;
    variable v_last      : std_logic;
  begin
    v := r;  -- start with current state (hold by default)

    -- Default: AR not ready
    ar_ready <= '0';

    case r.state is

      -- =============================================================
      -- S_WAIT_AR : wait for the next AR to arrive
      --
      --   ar_ready is always asserted.  The AR-side gen's FIFO
      --   handles backpressure — we can accept whenever we're not
      --   actively pushing beats.
      -- =============================================================
      when S_WAIT_AR =>
        -- Clear R-side valid (in case we just finished a burst)
        v.r_valid := '0';
        ar_ready <= '1';

        if ar_valid = '1' then
          -- Capture the AR and produce the first beat immediately.
          -- For len=0 this is also the last beat.
          v.cur_id   := ar_id;
          v.cur_addr := unsigned(ar_addr);
          v.cur_len  := unsigned(ar_len);
          v.beat_idx := (others => '0');

          v_last       := '1' when v.cur_len = 0 else '0';
          v.r_id       := v.cur_id;
          v.r_data     := make_rdata(v.cur_addr);
          v.r_resp     := "00";          -- OKAY response
          v.r_last     := v_last;
          v.r_valid    := '1';
          v.state      := S_SEND_BEATS;
        end if;

      -- =============================================================
      -- S_SEND_BEATS : push beats into the R-side gen at 1/cycle
      --
      --   A beat is consumed when r_ready='1' and r.r_valid='1'.
      --   Intermediate beats advance the beat index; on the last beat
      --   we either start the next transaction (if AR already waiting)
      --   or return to S_WAIT_AR.
      -- =============================================================
      when S_SEND_BEATS =>
        -- Look-ahead: assert ar_ready on the last beat so the next AR
        -- can be accepted in the same cycle (zero-idle back-to-back).
        if r.beat_idx = r.cur_len and r.r_valid = '1' then
          ar_ready <= '1';
        end if;

        -- Beat consumed?
        if r_ready = '1' and r.r_valid = '1' then

          if r.beat_idx = r.cur_len then
            -- Last beat of current burst just consumed.

            if ar_valid = '1' then
              -- Next AR already waiting → start next transaction
              -- immediately.  r_valid stays high — zero idle cycles.
              v.cur_id   := ar_id;
              v.cur_addr := unsigned(ar_addr);
              v.cur_len  := unsigned(ar_len);
              v.beat_idx := (others => '0');
              v_last       := '1' when unsigned(ar_len) = 0 else '0';
              v.r_id       := ar_id;
              v.r_data     := make_rdata(unsigned(ar_addr));
              v.r_resp     := "00";
              v.r_last     := v_last;
              -- r_valid remains '1'

            else
              -- No next AR yet → return to WAIT_AR.
              -- r_valid goes low; ar_ready will be asserted next cycle.
              v.r_valid := '0';
              v.state   := S_WAIT_AR;
            end if;

          else
            -- Intermediate beat: advance to next index.
            v_next_idx  := r.beat_idx + 1;
            v_beat_addr := beat_addr(r.cur_addr, v_next_idx);
            v_last      := '1' when v_next_idx = r.cur_len else '0';

            v.beat_idx := v_next_idx;
            v.r_id     := r.cur_id;       -- same ID for whole burst
            v.r_data   := make_rdata(v_beat_addr);
            v.r_resp   := "00";
            v.r_last   := v_last;
            -- r_valid stays '1'
          end if;

        end if;
        -- No handshake this cycle → hold all register state.

    end case;

    -- Drive registered R outputs from the current register state.
    -- These reflect values latched on the previous clock edge.
    r_id    <= r.r_id;
    r_data  <= r.r_data;
    r_resp  <= r.r_resp;
    r_last  <= r.r_last;
    r_valid <= r.r_valid;

    r_in <= v;
  end process p_comb;

  -- =================================================================
  -- p_reg : Synchronous register update with reset
  --
  --   All state and output registers update here on the rising edge.
  --   Reset puts us in S_WAIT_AR with all outputs cleared.
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
