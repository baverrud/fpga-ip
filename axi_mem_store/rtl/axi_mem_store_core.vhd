-----------------------------------------------------------------------
--Filename         : axi_mem_store_core.vhd
--Description      : AXI read slave backed by a byte-addressed memory.
--                 : Simulation only: the store is a process variable and a
--                 : whole beat is read in one clock.
--                 : Memory contents are populated through a clocked byte
--                 : write port and are preserved across AXI reset.
--                 : Out-of-range read beats return zero data and SLVERR.
--                 : Beats follow AXI INCR byte lanes: each beat is the
--                 : aligned GC_DATA_BYTES window, and the byte at address A
--                 : is on lane A mod GC_DATA_BYTES. Full-width bursts only.
--                 : An accepted out-of-range byte write is reported by a
--                 : one-clock pulse on mem_wr_error and is not stored.
--                 : A byte written on an edge is included in a beat loaded
--                 : on that same edge.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_mem_store_core is
  generic (
    GC_DATA_BYTES     : positive := 64;    -- R data width in bytes: 1, 2, 4 ... 128
    GC_ADDR_WIDTH     : positive := 32;    -- Byte address width (ar_addr, mem_wr_addr)
    GC_ID_WIDTH       : positive := 6;     -- AXI ID width, echoed from AR to R
    GC_MEM_SIZE_BYTES : positive := 16384  -- Store size, mapped from address 0
  );
  port (
    aclk    : in  std_logic;  -- Single clock for every port
    aresetn : in  std_logic;  -- Synchronous, active low; never clears the store

    -- Byte population write port (one byte per clock, no backpressure).
    mem_wr_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0); -- Byte address
    mem_wr_data  : in  std_logic_vector(7 downto 0);               -- Byte value
    mem_wr_valid : in  std_logic;                                  -- Write request
    mem_wr_ready : out std_logic; -- High when a byte write is accepted (out of reset).
    mem_wr_error : out std_logic; -- One-clock pulse on an out-of-range write.

    -- AXI4 read-address channel.
    ar_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);   -- Returned on r_id
    ar_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0); -- Start byte address
    ar_len   : in  std_logic_vector(7 downto 0);               -- Beats minus one
    ar_valid : in  std_logic;
    ar_ready : out std_logic; -- Idle, or the final R beat is being consumed

    -- AXI4 read-data channel (all fields registered).
    r_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : out std_logic_vector(8*GC_DATA_BYTES-1 downto 0); -- Little endian
    r_resp  : out std_logic_vector(1 downto 0);                 -- "00" OKAY, "10" SLVERR
    r_last  : out std_logic;
    r_valid : out std_logic;
    r_ready : in  std_logic
  );
end entity;

-- Three processes share the work:
--   p_comb   : burst state machine.  Decides ar_ready, the next state, and
--              which beat (if any) must be loaded on the next clock edge.
--   p_reg    : registers the state machine record.
--   p_memory : owns the store as a process variable.  It applies byte
--              writes and loads the beat that p_comb requested, so r_data
--              and r_resp are registered on the same edge as the state.
-- p_comb never reads the store, so population writes do not re-evaluate it.
architecture sim of axi_mem_store_core is

  -- Constants
  constant C_RDATA_WIDTH : positive := 8 * GC_DATA_BYTES;          -- R data bus width in bits
  -- Eight spare bits hold base + 255 beats, so a burst address never wraps.
  constant C_WIDE_WIDTH  : positive := GC_ADDR_WIDTH + 8;
  constant C_INDEX_WIDTH : positive := log2ceil(GC_MEM_SIZE_BYTES) + 1; -- Store index bits
  constant C_LANE_BITS   : natural  := log2ceil(GC_DATA_BYTES);   -- Byte-lane select bits
  -- Exclusive upper bound of the store, in the wide (non-wrapping) domain.
  constant C_MEM_LIMIT   : unsigned(C_WIDE_WIDTH-1 downto 0) :=
    to_unsigned(GC_MEM_SIZE_BYTES, C_WIDE_WIDTH);

  -- Types
  subtype rdata_t     is std_logic_vector(C_RDATA_WIDTH-1 downto 0); -- One R beat
  subtype ar_id_t     is std_logic_vector(GC_ID_WIDTH-1 downto 0);
  subtype ar_addr_t   is unsigned(GC_ADDR_WIDTH-1 downto 0);          -- Port-width address
  subtype ar_len_t    is unsigned(7 downto 0);                        -- Beat count minus one
  subtype wide_addr_t is unsigned(C_WIDE_WIDTH-1 downto 0);           -- Wrap-free address

  -- Byte-addressed store; element N holds the byte at address N.
  type memory_t is array (natural range <>) of std_logic_vector(7 downto 0);

  -- Helpers

  -- AXI data widths: powers of two from 1 to 128 bytes.
  function is_supported_data_width(data_bytes : positive) return boolean is
  begin
    return (data_bytes = 1)  or (data_bytes = 2)  or
           (data_bytes = 4)  or (data_bytes = 8)  or
           (data_bytes = 16) or (data_bytes = 32) or
           (data_bytes = 64) or (data_bytes = 128);
  end function;

  -- Every beat is the aligned GC_DATA_BYTES window; AXI ignores lower lanes.
  -- Clearing the lane bits makes an unaligned first beat return its whole
  -- window, so the byte at address A always sits on lane A mod GC_DATA_BYTES.
  function aligned_beat(addr : ar_addr_t) return ar_addr_t is
    variable v_addr : ar_addr_t := addr;
  begin
    if C_LANE_BITS > 0 then  -- 1-byte beats have no lane bits to clear
      v_addr(C_LANE_BITS-1 downto 0) := (others => '0');
    end if;
    return v_addr;
  end function;

  -- Address of beat beat_idx of an INCR burst starting at base_addr.
  -- Computed in the wide domain: base < 2**GC_ADDR_WIDTH and the offset is at
  -- most 255 beats of at most 2**GC_ADDR_WIDTH bytes, so the sum cannot
  -- overflow and a burst near the top of the address space cannot wrap back
  -- into the store.
  function beat_addr(base_addr : ar_addr_t; beat_idx : ar_len_t)
    return wide_addr_t is
  begin
    return resize(base_addr, C_WIDE_WIDTH) +
           to_unsigned(to_integer(beat_idx) * GC_DATA_BYTES, C_WIDE_WIDTH);
  end function;

  -- True when addr lies inside the store.  Used for single-byte writes and
  -- for aligned beats: because the size is a multiple of the beat width
  -- (asserted below), an aligned beat that starts inside also ends inside.
  function in_memory(addr : wide_addr_t) return boolean is
  begin
    return addr < C_MEM_LIMIT;
  end function;

  -- Store index of an in-range address.  Narrowing first keeps to_integer
  -- away from address bits above the integer range (e.g. a 49-bit bus).
  function mem_index(addr : wide_addr_t) return natural is
  begin
    return to_integer(resize(addr, C_INDEX_WIDTH));
  end function;

  -- State machine

  -- Bursts are serialized: a new AR is taken while idle, or on the cycle the
  -- final R beat of the current burst is consumed (zero-gap back-to-back).
  type state_t is (
    S_WAIT_AR,     -- Idle: no R beat presented, ar_ready high
    S_SEND_BEATS   -- A burst is in progress: r_valid high
  );

  -- r_data and r_resp are not in the record: p_memory registers them, because
  -- only that process can read the store.
  type reg_t is record
    state    : state_t;                     -- Current burst phase
    beat_idx : ar_len_t;                    -- Beat currently presented on R
    cur_id   : ar_id_t;                     -- ID of the active burst, drives r_id
    cur_addr : ar_addr_t;                   -- Aligned address of beat 0
    cur_len  : ar_len_t;                    -- Beats - 1 (AXI encoding)
    r_last   : std_logic;                   -- Registered r_last
    r_valid  : std_logic;                   -- Registered r_valid
  end record;

  constant C_REG_DEFAULT : reg_t := (
    state    => S_WAIT_AR,
    beat_idx => (others => '0'),
    cur_id   => (others => '0'),
    cur_addr => (others => '0'),
    cur_len  => (others => '0'),
    r_last   => '0',
    r_valid  => '0'
  );

  signal r, r_in : reg_t := C_REG_DEFAULT;  -- Current and next state

  -- Load request from p_comb to p_memory, sampled on the next clock edge.
  signal load_en   : std_logic;    -- '1': load the beat at load_addr
  signal load_addr : wide_addr_t;  -- Aligned beat address (wide domain)

  -- Registered beat payload, owned by p_memory.
  signal r_data_i : rdata_t := (others => '0');
  signal r_resp_i : std_logic_vector(1 downto 0) := "00";

begin

  -- Elaboration checks

  -- The bus widths are intentionally restricted to the widths supported by
  -- the surrounding memory-model wrappers and their testbenches.
  assert is_supported_data_width(GC_DATA_BYTES)
    report "axi_mem_store_core: GC_DATA_BYTES must be 2^n for n=0..7"
    severity failure;

  assert GC_MEM_SIZE_BYTES >= GC_DATA_BYTES
    report "axi_mem_store_core: memory must hold at least one data beat"
    severity failure;

  -- Required by in_memory: a beat that starts inside the store ends inside.
  assert (GC_MEM_SIZE_BYTES mod GC_DATA_BYTES) = 0
    report "axi_mem_store_core: GC_MEM_SIZE_BYTES must be a multiple of GC_DATA_BYTES"
    severity failure;

  -- Every byte must be addressable; wider addresses are fine (reads above the
  -- store return SLVERR).  Also bounds the beat offset used by beat_addr.
  assert GC_ADDR_WIDTH >= log2ceil(GC_MEM_SIZE_BYTES)
    report "axi_mem_store_core: GC_ADDR_WIDTH cannot address GC_MEM_SIZE_BYTES"
    severity failure;

  -- Outputs

  mem_wr_ready <= aresetn;  -- Writes are accepted whenever out of reset

  -- Every R field is a register output, so all stay stable under backpressure.
  r_id    <= r.cur_id;   -- Constant for the whole burst
  r_data  <= r_data_i;
  r_resp  <= r_resp_i;
  r_last  <= r.r_last;
  r_valid <= r.r_valid;

  -- Store, byte writes and beat loads
  -- Owns the store.  Reset aborts the protocol but keeps the contents.
  p_memory : process(aclk)
    -- Initialized to zero; never cleared by aresetn.
    variable mem    : memory_t(0 to GC_MEM_SIZE_BYTES-1) :=
      (others => (others => '0'));
    variable v_data : rdata_t;   -- Beat being assembled
    variable v_base : natural;   -- Store index of the beat's lane 0
  begin
    if rising_edge(aclk) then
      mem_wr_error <= '0';  -- Default: the error is a one-clock pulse
      if aresetn = '0' then
        r_data_i <= (others => '0');
        r_resp_i <= "00";
      else
        -- Byte write.  Handled before the beat load below, so a byte written
        -- on this edge is already visible to a beat loaded on this edge.
        if mem_wr_valid = '1' then
          if in_memory(resize(unsigned(mem_wr_addr), C_WIDE_WIDTH)) then
            mem(mem_index(resize(unsigned(mem_wr_addr), C_WIDE_WIDTH))) :=
              mem_wr_data;
          else
            mem_wr_error <= '1';  -- Accepted but out of range: not stored
          end if;
        end if;

        -- Beat load, requested by p_comb for a new burst or the next beat.
        -- Without a request the current beat is held unchanged.
        if load_en = '1' then
          v_data := (others => '0');  -- An out-of-range beat returns zero data
          if in_memory(load_addr) then
            v_base := mem_index(load_addr);
            -- Lane b carries the byte at address load_addr + b (little endian).
            for byte_idx in 0 to GC_DATA_BYTES-1 loop
              v_data(8*byte_idx+7 downto 8*byte_idx) := mem(v_base + byte_idx);
            end loop;
            r_resp_i <= "00";  -- OKAY
          else
            r_resp_i <= "10";  -- SLVERR
          end if;
          r_data_i <= v_data;
        end if;
      end if;
    end if;
  end process;

  -- Burst state machine (combinational next state)
  p_comb : process(all)
    variable v      : reg_t;         -- Next state, built from the current one
    variable v_load : boolean;       -- A beat must be loaded on the next edge
    variable v_addr : wide_addr_t;   -- Address of that beat

    -- Capture the AR on the channel and request its first beat.  Used both
    -- from idle and for a back-to-back burst after a final beat.
    procedure start_burst is
    begin
      v.cur_id   := ar_id;
      v.cur_addr := aligned_beat(unsigned(ar_addr));
      v.cur_len  := unsigned(ar_len);
      v.beat_idx := (others => '0');
      v.r_last   := '1' when unsigned(ar_len) = 0 else '0';  -- Single-beat burst
      v.r_valid  := '1';
      v.state    := S_SEND_BEATS;
      v_load     := true;
      v_addr     := beat_addr(v.cur_addr, v.beat_idx);
    end procedure;
  begin
    -- Defaults: hold the current state, load nothing, refuse AR.
    v        := r;
    v_load   := false;
    v_addr   := (others => '0');  -- Known value while no load is requested
    ar_ready <= '0';

    case r.state is
      when S_WAIT_AR =>
        -- Idle: accept any AR (r_valid is already low here).
        ar_ready <= aresetn;
        if ar_valid = '1' then
          start_burst;
        end if;

      when S_SEND_BEATS =>
        -- R fields advance only on a handshake, so they hold under backpressure.
        if r.r_valid = '1' and r_ready = '1' then
          if r.beat_idx = r.cur_len then
            -- Final beat consumed.  ar_ready is raised only now, never while
            -- the final beat is stalled, so at most one burst is in flight.
            ar_ready <= '1';
            if ar_valid = '1' then
              start_burst;          -- Next burst starts with no idle cycle
            else
              v.r_valid := '0';
              v.state   := S_WAIT_AR;
            end if;
          else
            -- Intermediate beat consumed: present the next beat.
            v.beat_idx := r.beat_idx + 1;
            v.r_last   := '1' when v.beat_idx = r.cur_len else '0';
            v_load     := true;
            v_addr     := beat_addr(r.cur_addr, v.beat_idx);
          end if;
        end if;
    end case;

    load_en   <= '1' when v_load else '0';
    load_addr <= v_addr;
    r_in      <= v;
  end process;

  -- State register (synchronous active-low reset)
  p_reg : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        r <= C_REG_DEFAULT;  -- Aborts any burst; the store is untouched
      else
        r <= r_in;
      end if;
    end if;
  end process;

end architecture;
