-----------------------------------------------------------------------
--Filename         : axi_mem_store_core.vhd
--Description      : AXI read slave backed by a byte-addressed memory.
--                 : Memory contents are populated through a clocked byte
--                 : write port and are preserved across AXI reset.
--                 : Out-of-range read beats return zero data and SLVERR.
--                 : Beats follow AXI INCR byte lanes: each beat is the
--                 : aligned GC_DATA_BYTES window, and the byte at address A
--                 : is on lane A mod GC_DATA_BYTES. Full-width bursts only.
--                 : An accepted out-of-range byte write is reported by a
--                 : one-clock pulse on mem_wr_error and is not stored.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_mem_store_core is
  generic (
    GC_DATA_BYTES     : positive := 64;
    GC_ADDR_WIDTH     : positive := 32;
    GC_ID_WIDTH       : positive := 6;
    GC_MEM_SIZE_BYTES : positive := 16384
  );
  port (
    aclk    : in  std_logic;
    aresetn : in  std_logic;

    -- Byte population write port.
    mem_wr_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    mem_wr_data  : in  std_logic_vector(7 downto 0);
    mem_wr_valid : in  std_logic;
    mem_wr_ready : out std_logic; -- High when a byte write is accepted.
    mem_wr_error : out std_logic; -- One-clock pulse on an out-of-range write.

    -- AXI4 read-address channel.
    ar_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : in  std_logic_vector(7 downto 0);
    ar_valid : in  std_logic;
    ar_ready : out std_logic;

    -- AXI4 read-data channel.
    r_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : out std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : out std_logic_vector(1 downto 0);
    r_last  : out std_logic;
    r_valid : out std_logic;
    r_ready : in  std_logic
  );
end entity;

architecture rtl of axi_mem_store_core is

  -- The AXI data bus is addressed and assembled a byte at a time.  The
  -- response payload is registered so it remains stable during backpressure.
  constant C_RDATA_WIDTH    : positive := 8 * GC_DATA_BYTES;
  constant C_BEAT_CALC_WIDTH : positive := GC_ADDR_WIDTH + 8;
  -- Keep the memory index conversion narrower than the AXI address.  This
  -- avoids converting a large, out-of-range AXI address to an integer.
  constant C_MEM_INDEX_WIDTH : positive := log2ceil(GC_MEM_SIZE_BYTES) + 1;
  -- Upper memory bound as an exclusive limit in the full AXI address domain.
  -- It is one bit wider than the AXI address so that a limit equal to a
  -- power-of-two memory size stays representable: with an exactly wide bound
  -- the limit would truncate to zero and reject every write.  A beat is valid
  -- only when its last byte is below this limit.
  constant C_MEM_SIZE_ADDR_WIDE : unsigned(GC_ADDR_WIDTH downto 0) :=
    to_unsigned(GC_MEM_SIZE_BYTES, GC_ADDR_WIDTH + 1);
  -- Address bits that select a byte lane within one data beat.
  constant C_LANE_BITS : natural := log2ceil(GC_DATA_BYTES);

  subtype rdata_t   is std_logic_vector(C_RDATA_WIDTH-1 downto 0);
  subtype ar_id_t  is std_logic_vector(GC_ID_WIDTH-1 downto 0);
  subtype ar_addr_t is unsigned(GC_ADDR_WIDTH-1 downto 0);
  subtype ar_len_t  is unsigned(7 downto 0);

  -- The store is byte addressed.  It is initialized to zero, but reset does
  -- not clear it: reset aborts protocol state without destroying test data.
  type memory_t is array (natural range <>) of std_logic_vector(7 downto 0);
  signal memory : memory_t(0 to GC_MEM_SIZE_BYTES-1) :=
    (others => (others => '0'));

  function is_supported_data_width(data_bytes : positive) return boolean is
  begin
    return (data_bytes = 1)  or (data_bytes = 2)  or
           (data_bytes = 4)  or (data_bytes = 8)  or
           (data_bytes = 16) or (data_bytes = 32) or
           (data_bytes = 64) or (data_bytes = 128);
  end function;

  -- AXI INCR bursts advance by one native data beat for every R transfer.
  -- Keep the calculation wider than the address port so a burst cannot wrap
  -- into address zero before the range check sees the carry.
  function beat_addr_wide(base_addr : ar_addr_t; beat_idx : ar_len_t)
    return unsigned is
  begin
    return resize(base_addr, C_BEAT_CALC_WIDTH) +
           to_unsigned(to_integer(beat_idx) * GC_DATA_BYTES,
                       C_BEAT_CALC_WIDTH);
  end function;

  -- Clear the byte-lane offset. An unaligned first beat returns its whole
  -- aligned window; the lanes below the start offset are ignored by AXI.
  function aligned_beat(addr : ar_addr_t) return ar_addr_t is
    variable v_addr : ar_addr_t := addr;
  begin
    if C_LANE_BITS > 0 then
      v_addr(C_LANE_BITS-1 downto 0) := (others => '0');
    end if;
    return v_addr;
  end function;

  -- Check the complete native data beat, not just its first byte.  A beat
  -- that crosses the upper memory boundary is returned as one SLVERR beat.
  function beat_in_range(addr : ar_addr_t) return boolean is
    variable v_last_byte : unsigned(GC_ADDR_WIDTH downto 0);
  begin
    -- The extra carry bit prevents an address near all-ones from wrapping
    -- into the low address range before the validity check is made.
    v_last_byte := resize(addr, GC_ADDR_WIDTH + 1) +
                   to_unsigned(GC_DATA_BYTES - 1, GC_ADDR_WIDTH + 1);
    return v_last_byte < C_MEM_SIZE_ADDR_WIDE;
  end function;

  function beat_in_range_wide(addr : unsigned) return boolean is
  begin
    return addr < resize(C_MEM_SIZE_ADDR_WIDE, addr'length);
  end function;

  -- This conversion is called only after beat_in_range has succeeded, so the
  -- narrowed address is known to fit in the memory array.
  function mem_index(addr : ar_addr_t) return natural is
  begin
    return to_integer(resize(addr, C_MEM_INDEX_WIDTH));
  end function;

  -- Read one complete AXI beat.  Byte zero occupies the least significant
  -- byte of RDATA, matching the byte-addressed little-endian contract.
  -- An invalid beat deliberately returns zero data for deterministic errors.
  impure function make_rdata(addr : ar_addr_t; valid : boolean)
    return rdata_t is
    variable v_data : rdata_t := (others => '0');
    variable v_base : natural;
  begin
    if valid then
      v_base := mem_index(addr);
      for byte_idx in 0 to GC_DATA_BYTES-1 loop
        v_data(8*byte_idx+7 downto 8*byte_idx) :=
          memory(v_base + byte_idx);
      end loop;
    end if;
    return v_data;
  end function;

  -- AXI response encoding: OKAY for an in-range beat, SLVERR otherwise.
  function response_for_range(valid : boolean) return std_logic_vector is
  begin
    if valid then
      return "00";
    end if;
    return "10";
  end function;

  -- The core serializes bursts.  It accepts a new AR while idle, or on the
  -- same cycle that the current final R beat is consumed.
  type state_t is (S_WAIT_AR, S_SEND_BEATS);

  type reg_t is record
    state    : state_t;               -- Current burst phase.
    beat_idx : ar_len_t;               -- Index of the currently held beat.
    cur_id   : ar_id_t;                -- ID copied from the active AR.
    cur_addr : ar_addr_t;              -- Aligned address of the burst's first beat.
    cur_len  : ar_len_t;               -- AXI length, encoded as beats - 1.
    -- Once any beat of the burst falls outside memory, the remainder of the
    -- burst is answered with SLVERR.  Latching this avoids trusting a wrapped
    -- address to decide validity.
    cur_invalid : std_logic;
    r_id     : ar_id_t;                -- Registered R-channel fields.
    r_data   : rdata_t;
    r_resp   : std_logic_vector(1 downto 0);
    r_last   : std_logic;
    r_valid  : std_logic;
  end record;

  constant C_REG_DEFAULT : reg_t := (
    state    => S_WAIT_AR,
    beat_idx => (others => '0'),
    cur_id   => (others => '0'),
    cur_addr => (others => '0'),
    cur_len  => (others => '0'),
    cur_invalid => '0',
    r_id     => (others => '0'),
    r_data   => (others => '0'),
    r_resp   => "00",
    r_last   => '0',
    r_valid  => '0'
  );

  signal r, r_in : reg_t := C_REG_DEFAULT;
  signal mem_wr_error_i : std_logic := '0';

begin

  -- The bus widths are intentionally restricted to the widths supported by
  -- the surrounding memory-model wrappers and their testbenches.
  assert is_supported_data_width(GC_DATA_BYTES)
    report "axi_mem_store_core: GC_DATA_BYTES must be 2^n for n=0..7"
    severity failure;

  assert GC_MEM_SIZE_BYTES >= GC_DATA_BYTES
    report "axi_mem_store_core: memory must hold at least one data beat"
    severity failure;

  assert (GC_MEM_SIZE_BYTES mod GC_DATA_BYTES) = 0
    report "axi_mem_store_core: GC_MEM_SIZE_BYTES must be a multiple of GC_DATA_BYTES"
    severity failure;

  -- Addressing every byte needs only log2ceil(GC_MEM_SIZE_BYTES) bits: the
  -- highest address is GC_MEM_SIZE_BYTES - 1.  The exclusive limit used by
  -- the range checks is widened separately and must not constrain the width.
  assert GC_ADDR_WIDTH >= log2ceil(GC_MEM_SIZE_BYTES)
    report "axi_mem_store_core: GC_ADDR_WIDTH cannot address GC_MEM_SIZE_BYTES"
    severity failure;

  -- Population is accepted whenever the protocol is out of reset. Invalid
  -- write addresses are ignored; the AXI read path reports invalid reads.
  mem_wr_ready <= aresetn;
  mem_wr_error <= mem_wr_error_i;

  p_memory : process(aclk)
  begin
    if rising_edge(aclk) then
      mem_wr_error_i <= '0';
      if aresetn = '1' and mem_wr_valid = '1' then
        -- Widened for the same reason as beat_in_range, so an address one
        -- past the top of a power-of-two memory is still compared correctly.
        if resize(unsigned(mem_wr_addr), GC_ADDR_WIDTH + 1) <
           C_MEM_SIZE_ADDR_WIDE then
          -- A byte write is the only writer of the memory array.  Read logic
          -- observes the new value after this clock edge.
          memory(mem_index(unsigned(mem_wr_addr))) <= mem_wr_data;
        else
          -- An accepted invalid write is reported for exactly this cycle.
          mem_wr_error_i <= '1';
        end if;
      end if;
    end if;
  end process;

  p_comb : process(all)
    variable v           : reg_t;
    variable v_beat_addr : ar_addr_t;
    variable v_beat_addr_wide : unsigned(C_BEAT_CALC_WIDTH-1 downto 0);
    variable v_next_idx  : ar_len_t;
    variable v_valid     : boolean;
    variable v_last      : std_logic;

    procedure p_start_burst(variable state : inout reg_t;
                             constant id : in ar_id_t;
                             constant addr : in ar_addr_t;
                             constant len : in ar_len_t) is
      variable aligned_addr : ar_addr_t;
      variable valid        : boolean;
    begin
      aligned_addr := aligned_beat(addr);
      valid := beat_in_range(aligned_addr);
      state.cur_id       := id;
      state.cur_addr     := aligned_addr;
      state.cur_len      := len;
      state.beat_idx     := (others => '0');
      state.cur_invalid  := '1' when not valid else '0';
      state.r_id         := id;
      state.r_data       := make_rdata(aligned_addr, valid);
      state.r_resp       := response_for_range(valid);
      state.r_last       := '1' when len = 0 else '0';
      state.r_valid      := '1';
      state.state        := S_SEND_BEATS;
    end procedure;
  begin
    v := r;
    ar_ready <= '0';

    case r.state is
      when S_WAIT_AR =>
        -- The latency wrapper supplies a valid AR only when it has a request
        -- ready.  Capture it and form the first registered R beat here.
        v.r_valid := '0';
        ar_ready <= aresetn;

        if ar_valid = '1' then
          p_start_burst(v, ar_id, unsigned(ar_addr), unsigned(ar_len));
        end if;

      when S_SEND_BEATS =>
        -- Look ahead only on the final R handshake.  This prevents an AR from
        -- being accepted while the current R beat is stalled.
        if r.beat_idx = r.cur_len and r.r_valid = '1' and r_ready = '1' then
          ar_ready <= '1';
        end if;

        if r_ready = '1' and r.r_valid = '1' then
          if r.beat_idx = r.cur_len then
            -- The current burst is complete.  Replace it immediately when a
            -- new AR is already valid; otherwise return to the idle state.
            if ar_valid = '1' then
              p_start_burst(v, ar_id, unsigned(ar_addr), unsigned(ar_len));
            else
              v.r_valid := '0';
              v.state   := S_WAIT_AR;
            end if;
          else
            -- Advance only after an R handshake.  This is what holds every
            -- R field stable while the downstream interface applies backpressure.
            v_next_idx      := r.beat_idx + 1;
            v_beat_addr_wide := beat_addr_wide(r.cur_addr, v_next_idx);
            v_beat_addr     := v_beat_addr_wide(GC_ADDR_WIDTH-1 downto 0);
            -- A beat already declared invalid keeps the burst invalid, so a
            -- wrapped address can never be re-admitted as an OKAY beat.
            v_valid     := (r.cur_invalid = '0') and
                           beat_in_range_wide(v_beat_addr_wide);
            v.cur_invalid := '1' when not v_valid else '0';
            v_last      := '1' when v_next_idx = r.cur_len else '0';
            v.beat_idx  := v_next_idx;
            v.r_id      := r.cur_id;
            v.r_data    := make_rdata(v_beat_addr, v_valid);
            v.r_resp    := response_for_range(v_valid);
            v.r_last    := v_last;
          end if;
        end if;
    end case;

    -- Drive the current registered response, not the speculative next state.
    -- The next state is committed only by p_reg on the active clock edge.
    r_id    <= r.r_id;
    r_data  <= r.r_data;
    r_resp  <= r.r_resp;
    r_last  <= r.r_last;
    r_valid <= r.r_valid;
    r_in    <= v;
  end process;

  p_reg : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        -- Reset cancels the active transaction but deliberately leaves memory
        -- contents untouched for testbench reuse across protocol resets.
        r <= C_REG_DEFAULT;
      else
        r <= r_in;
      end if;
    end if;
  end process;

end architecture;
