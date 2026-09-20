-----------------------------------------------------------------------
--Filename         : axi_mem_image_core.vhd
--Description      : AXI read burst sequencer backed by mem_image.
--                 :
--                 : This core deliberately follows axi_mem_model_core's
--                 : handshake behavior.  It accepts one delayed AR
--                 : transaction, presents its beats at one beat per cycle
--                 : to the R-side latency generator, and can accept the
--                 : next AR on the cycle that the final R beat is consumed.
--                 :
--                 : The fetch side channel is the only functional change:
--                 : fetch_addr selects a byte address in mem_image,
--                 : fetch_data supplies the corresponding beat, and
--                 : fetch_hit tells this core whether the complete beat
--                 : was inside one loaded image region.  An image miss is
--                 : returned as zero data with AXI SLVERR.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axi_mem_image_core is
  generic (
    GC_DATA_BYTES : positive := 64;
    GC_ADDR_WIDTH : positive := 49;
    GC_ID_WIDTH   : positive := 6
  );
  port (
    aclk    : in  std_logic;
    aresetn : in  std_logic;

    -- Delayed AXI read-address channel from the wrapper's AR latency FIFO.
    ar_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : in  std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : in  std_logic_vector(7 downto 0);
    ar_valid : in  std_logic;
    ar_ready : out std_logic;

    -- Beat stream sent into the wrapper's R latency FIFO.
    r_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : out std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : out std_logic_vector(1 downto 0);
    r_last  : out std_logic;
    r_valid : out std_logic;
    r_ready : in  std_logic;

    -- Combinational memory lookup side channel.
    fetch_en   : out std_logic;
    fetch_addr : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    fetch_data : in  std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    fetch_hit  : in  std_logic
  );
end entity;

architecture rtl of axi_mem_image_core is

  constant C_RDATA_WIDTH : positive := 8 * GC_DATA_BYTES;

  subtype rdata_t   is std_logic_vector(C_RDATA_WIDTH-1 downto 0);
  subtype ar_id_t   is std_logic_vector(GC_ID_WIDTH-1 downto 0);
  subtype ar_addr_t is unsigned(GC_ADDR_WIDTH-1 downto 0);
  subtype ar_len_t  is unsigned(7 downto 0);

  -- axi_mem_model supports the AXI-sized powers of two from 1 to 128 bytes.
  function is_supported_data_width(data_bytes : positive) return boolean is
  begin
    return (data_bytes = 1) or (data_bytes = 2) or
           (data_bytes = 4) or (data_bytes = 8) or
           (data_bytes = 16) or (data_bytes = 32) or
           (data_bytes = 64) or (data_bytes = 128);
  end function;

  -- AXI INCR bursts advance by one native data beat per R beat.
  function beat_addr(base_addr : ar_addr_t; beat_idx : ar_len_t)
    return ar_addr_t is
  begin
    return base_addr +
           to_unsigned(to_integer(beat_idx) * GC_DATA_BYTES, GC_ADDR_WIDTH);
  end function;

  -- A missing image beat is an AXI slave error.  A hit is an ordinary OKAY
  -- response, including a byte range that contains an uninitialized hole.
  function response_for_hit(hit : std_logic) return std_logic_vector is
  begin
    if hit = '1' then
      return "00";                    -- AXI OKAY
    end if;
    return "10";                      -- AXI SLVERR
  end function;

  type state_t is (S_WAIT_AR, S_SEND_BEATS);

  -- All externally visible R-channel fields are registered.  This keeps
  -- them stable while r_ready is low and gives the latency generator a
  -- normal ready/valid stream to buffer.
  type reg_t is record
    state    : state_t;
    beat_idx : unsigned(7 downto 0);
    cur_id   : ar_id_t;
    cur_addr : ar_addr_t;
    cur_len  : ar_len_t;
    r_id     : ar_id_t;
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
    r_id     => (others => '0'),
    r_data   => (others => '0'),
    r_resp   => (others => '0'),
    r_last   => '0',
    r_valid  => '0'
  );

  signal r, r_in : reg_t := C_REG_DEFAULT;

begin

  assert is_supported_data_width(GC_DATA_BYTES)
    report "axi_mem_image_core: GC_DATA_BYTES must be 2^n for n=0..7"
    severity failure;

  -- The combinational process does two jobs:
  --   1. It drives the current registered R beat.
  --   2. It selects the image address whose data will be latched at the
  --      next handshake edge.  The lookup is combinational, so fetch_data
  --      and fetch_hit settle before the edge that stores the next beat.
  p_comb : process(all)
    variable v           : reg_t;
    variable v_beat_addr : ar_addr_t;
    variable v_next_idx  : ar_len_t;
    variable v_last      : std_logic;
  begin
    v := r;
    ar_ready <= '0';
    fetch_en <= '0';
    -- A known idle address prevents the file-backed store from evaluating
    -- numeric_std comparisons on uninitialized AXI signals at time zero.
    fetch_addr <= (others => '0');

    case r.state is
      when S_WAIT_AR =>
        -- The core is idle.  The AR latency generator may deliver a new
        -- request, and the address lookup is pointed at its first beat.
        v.r_valid := '0';
        ar_ready <= '1';

        if ar_valid = '1' then
          fetch_addr <= ar_addr;
          fetch_en <= '1';
          v.cur_id   := ar_id;
          v.cur_addr := unsigned(ar_addr);
          v.cur_len  := unsigned(ar_len);
          v.beat_idx := (others => '0');
          v_last     := '1' when unsigned(ar_len) = 0 else '0';
          v.r_id     := ar_id;
          v.r_data   := fetch_data;
          v.r_resp   := response_for_hit(fetch_hit);
          v.r_last   := v_last;
          v.r_valid  := '1';
          v.state    := S_SEND_BEATS;
        end if;

      when S_SEND_BEATS =>
        -- Normally look up the beat currently held on R.  When that beat is
        -- consumed, look up the next beat early so it can be registered on
        -- this same clock edge.  On the final beat, the next AR (if any) is
        -- selected for zero-idle back-to-back operation.
        v_beat_addr := beat_addr(r.cur_addr, r.beat_idx);
        fetch_addr <= std_logic_vector(v_beat_addr);
        fetch_en <= r.r_valid;

        if r.beat_idx = r.cur_len and r.r_valid = '1' and r_ready = '1' then
          ar_ready <= '1';
          if ar_valid = '1' then
            fetch_addr <= ar_addr;
            fetch_en <= '1';
          end if;
        elsif r.r_valid = '1' and r_ready = '1' and
              r.beat_idx /= r.cur_len then
          v_next_idx := r.beat_idx + 1;
          fetch_addr <= std_logic_vector(beat_addr(r.cur_addr, v_next_idx));
        end if;

        -- A beat advances only on a valid/ready handshake.  While stalled,
        -- every R field and the current image address remain stable.
        if r_ready = '1' and r.r_valid = '1' then
          if r.beat_idx = r.cur_len then
            -- Final beat consumed.  Capture a waiting AR immediately when
            -- possible; otherwise return to the idle state.
            if ar_valid = '1' then
              v.cur_id   := ar_id;
              v.cur_addr := unsigned(ar_addr);
              v.cur_len  := unsigned(ar_len);
              v.beat_idx := (others => '0');
              v_last     := '1' when unsigned(ar_len) = 0 else '0';
              v.r_id     := ar_id;
              v.r_data   := fetch_data;
              v.r_resp   := response_for_hit(fetch_hit);
              v.r_last   := v_last;
            else
              v.r_valid := '0';
              v.state   := S_WAIT_AR;
            end if;
          else
            -- Intermediate beat: advance the address and last flag while
            -- preserving the transaction ID.
            v_next_idx  := r.beat_idx + 1;
            v_beat_addr := beat_addr(r.cur_addr, v_next_idx);
            v_last      := '1' when v_next_idx = r.cur_len else '0';
            v.beat_idx  := v_next_idx;
            v.r_id      := r.cur_id;
            v.r_data    := fetch_data;
            v.r_resp    := response_for_hit(fetch_hit);
            v.r_last    := v_last;
          end if;
        end if;
    end case;

    -- Registered R outputs are driven from the current state, not from the
    -- speculative next-state variable.  This is what holds a beat during
    -- downstream backpressure.
    r_id    <= r.r_id;
    r_data  <= r.r_data;
    r_resp  <= r.r_resp;
    r_last  <= r.r_last;
    r_valid <= r.r_valid;
    r_in    <= v;
  end process;

  -- Synchronous active-low reset, matching axi_mem_model_core.
  p_reg : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        r <= C_REG_DEFAULT;
      else
        r <= r_in;
      end if;
    end if;
  end process;

end architecture;
