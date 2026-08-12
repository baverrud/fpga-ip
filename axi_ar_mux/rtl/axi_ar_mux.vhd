-----------------------------------------------------------------------
--Filename         : axi_ar_mux.vhd
--Description      : Credit-Based AXI Read-Address (AR) Multiplexer:
--                 :  - Merges GC_NUM_CLIENTS request interfaces into one
--                 :    AXI4 AR channel (ar_id generated from client index).
--                 :  - Per-client credit tracking (depth = R-side FIFO).
--                 :  - Fair round-robin arbitration over eligible requests.
--                 :  - Registered AR outputs with per-client input buffers.
--                 :    req_ready is independent of ar_ready.
--                 :  - Sustains one AR transaction per clock (line rate)
--                 :    when the downstream and clients keep up.
--                 :  - r_pop credit returns from the R-side demux FIFO pops.
--                 :  - Two-process record-based state architecture with
--                 :    fully synchronous active-low reset (aresetn).
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;  -- slv_array_t, slv8_array_t, log2ceil

entity axi_ar_mux is
  generic (
    GC_NUM_CLIENTS     : positive := 4;
    GC_ADDR_WIDTH      : positive := 32;
    GC_ID_WIDTH        : positive := 4;                            -- AR ID width
    GC_FIFO_DEPTH      : positive range 2 to positive'high := 32;  -- client beat credits
    GC_R_BEATS_PER_POP : positive := 1                             -- client beats per r_pop
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;  -- synchronous, active low

    -- Client request interfaces (slave)
    req_addr  : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);
    req_len   : in  slv8_array_t(0 to GC_NUM_CLIENTS-1);                           -- ARLEN (beats - 1)
    req_size  : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(2 downto 0);                -- ARSIZE
    req_burst : in  slv_array_t(0 to GC_NUM_CLIENTS-1)(1 downto 0);                -- ARBURST
    req_valid : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);
    req_ready : out std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- Credit returns (one pulse per R-side FIFO pop)
    r_pop : in std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- AXI Read-Address Channel (master -> downstream)
    ar_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : out std_logic_vector(7 downto 0);
    ar_size  : out std_logic_vector(2 downto 0);
    ar_burst : out std_logic_vector(1 downto 0);
    ar_valid : out std_logic;
    ar_ready : in  std_logic
  );
end entity axi_ar_mux;

architecture arch of axi_ar_mux is

  -- Credit counter width: represent 0 .. GC_FIFO_DEPTH exactly. Credit
  -- returns are saturated at the configured limit as a defensive guard.
  constant C_CREDIT_W : positive := log2ceil(GC_FIFO_DEPTH + 1);

  type credit_array_t is array (0 to GC_NUM_CLIENTS-1) of unsigned(C_CREDIT_W-1 downto 0);

  function f_beats(req_len : std_logic_vector(7 downto 0)) return integer is
  begin
    return to_integer(unsigned(req_len)) + 1;
  end function;

  -- Clamp a beat count for credit arithmetic (exact: any granted burst is at
  -- most the credit, which is <= GC_FIFO_DEPTH, and a burst larger than the
  -- whole credit can never be granted). Storing the clamped value in the
  -- client buffer keeps the credit subtract/compare at C_CREDIT_W bits.
  function f_clamp_beats(b : integer) return integer is
  begin
    if b > GC_FIFO_DEPTH then
      return GC_FIFO_DEPTH + 1;
    end if;
    return b;
  end function;

  -- Exact live-burst credit check kept at C_CREDIT_W bits: a live burst can
  -- only fit when its ARLEN is representable within the credit width
  -- (credit_after < 2^C_CREDIT_W), so the high bits of req_len only need a
  -- zero check and the low bits a narrow comparison.
  function f_fits_live(credit_after : unsigned(C_CREDIT_W-1 downto 0);
                       req_len : std_logic_vector(7 downto 0)) return boolean is
  begin
    if C_CREDIT_W >= 8 then
      return to_integer(credit_after) >= f_beats(req_len);
    end if;
    if unsigned(req_len(7 downto C_CREDIT_W)) /= 0 then
      return false;
    end if;
    return to_integer(credit_after) > to_integer(unsigned(req_len(C_CREDIT_W-1 downto 0)));
  end function;

  type client_buf_t is record
    valid : std_logic;
    addr  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    len   : std_logic_vector(7 downto 0);
    size  : std_logic_vector(2 downto 0);
    burst : std_logic_vector(1 downto 0);
    beats : integer range 0 to GC_FIFO_DEPTH + 1;
  end record;

  type client_buf_array_t is array (0 to GC_NUM_CLIENTS-1) of client_buf_t;

  constant C_BUF_DEFAULT : client_buf_t := (
    valid => '0',
    addr  => (others => '0'),
    len   => (others => '0'),
    size  => (others => '0'),
    burst => (others => '0'),
    beats => 0
  );

  -- Active AR is held until downstream acceptance. A pending AR slot and one
  -- buffer per client decouple client ready from ar_ready and allow a
  -- registered exact grant without losing same-client line rate.
  type rec_t is record
    active_valid : std_logic;
    active_id    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
    active_addr  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    active_len   : std_logic_vector(7 downto 0);
    active_size  : std_logic_vector(2 downto 0);
    active_burst : std_logic_vector(1 downto 0);
    active_beats : integer range 0 to 256;

    pending_valid : std_logic;
    pending_id    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
    pending_addr  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    pending_len   : std_logic_vector(7 downto 0);
    pending_size  : std_logic_vector(2 downto 0);
    pending_burst : std_logic_vector(1 downto 0);
    pending_beats : integer range 0 to 256;

    client_buf : client_buf_array_t;
    rr_pointer : integer range 0 to GC_NUM_CLIENTS-1;
    credit_cnt : credit_array_t;

    grant_valid : std_logic;
    grant_idx   : integer range 0 to GC_NUM_CLIENTS-1;
  end record;

  constant C_REC_DEFAULT : rec_t := (
    active_valid  => '0',
    active_id     => (others => '0'),
    active_addr   => (others => '0'),
    active_len    => (others => '0'),
    active_size   => (others => '0'),
    active_burst  => (others => '0'),
    active_beats  => 0,
    pending_valid => '0',
    pending_id    => (others => '0'),
    pending_addr  => (others => '0'),
    pending_len   => (others => '0'),
    pending_size  => (others => '0'),
    pending_burst => (others => '0'),
    pending_beats => 0,
    client_buf    => (others => C_BUF_DEFAULT),
    rr_pointer    => GC_NUM_CLIENTS - 1,
    credit_cnt    => (others => to_unsigned(GC_FIFO_DEPTH, C_CREDIT_W)),
    grant_valid   => '0',
    grant_idx     => 0
  );

  signal r : rec_t := C_REC_DEFAULT;
  signal r_in : rec_t;

begin

  assert GC_ID_WIDTH >= log2ceil(GC_NUM_CLIENTS)
    report "axi_ar_mux: GC_ID_WIDTH cannot encode GC_NUM_CLIENTS clients"
    severity failure;

  -- The exact eligibility and round-robin scan are registered before a
  -- request reaches the AR slots. Client buffers and the pending slot keep
  -- req_ready independent of ar_ready; a consumed buffer can be refilled on
  -- the same edge that its request moves to active or pending AR.
  p_logic : process(all)
    variable v                : rec_t;
    variable buf_next         : client_buf_array_t;
    variable credit_after     : credit_array_t;
    variable credit_resv      : credit_array_t;
    variable eligible         : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    variable w                : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    variable prefix           : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    variable input_ready      : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    variable input_hs         : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    variable grant_next_valid : boolean;
    variable grant_next_idx   : integer range 0 to GC_NUM_CLIENTS-1;
    variable cidx             : integer range 0 to GC_NUM_CLIENTS-1;
    variable scan_ptr         : integer range 0 to GC_NUM_CLIENTS-1;
    variable credit_next      : integer;
    variable handshake        : boolean;
    variable grant_take       : boolean;
  begin
    v := r;

    ar_valid  <= r.active_valid;
    ar_id     <= r.active_id;
    ar_addr   <= r.active_addr;
    ar_len    <= r.active_len;
    ar_size   <= r.active_size;
    ar_burst  <= r.active_burst;

    -- A grant is consumed whenever the pending AR slot is free. It then
    -- targets active AR if that slot is free at the edge, otherwise pending.
    -- The decision itself does not depend on ar_ready.
    handshake := (r.active_valid = '1') and (ar_ready = '1');
    grant_take := (r.grant_valid = '1') and (r.pending_valid = '0');

    -- Reserve the current grant and apply credit returns before evaluating a
    -- possible same-edge buffer refill. This keeps the client handshake
    -- from accepting a request that would exceed the post-edge budget.
    -- The per-client reservation subtracts stay parallel; grant_idx only
    -- selects the matching result.  They must live in this process: a
    -- separate combinational process for the subtract races p_logic in the
    -- same delta (a simulator may read the stale result and lose the debit).
    for i in 0 to GC_NUM_CLIENTS-1 loop
      credit_resv(i) := r.credit_cnt(i) - r.client_buf(i).beats;
    end loop;
    credit_after := r.credit_cnt;
    if grant_take then
      credit_after(r.grant_idx) := credit_resv(r.grant_idx);
    end if;
    for i in 0 to GC_NUM_CLIENTS-1 loop
      if r_pop(i) = '1' then
        credit_next := to_integer(credit_after(i)) + GC_R_BEATS_PER_POP;
        if credit_next > GC_FIFO_DEPTH then
          credit_after(i) := to_unsigned(GC_FIFO_DEPTH, C_CREDIT_W);
        else
          credit_after(i) := to_unsigned(credit_next, C_CREDIT_W);
        end if;
      end if;
    end loop;

    -- Consume/refill client buffers. A client with an empty buffer, or the
    -- client whose registered grant is consumed this edge, sees ready high.
    buf_next := r.client_buf;
    input_ready := (others => '0');
    input_hs := (others => '0');
    for i in 0 to GC_NUM_CLIENTS-1 loop
      if r.client_buf(i).valid = '0' then
        if req_valid(i) = '1' then
          -- Contract guard: a single request larger than the per-client
          -- credit budget can never be granted. Credits are capped at
          -- GC_FIFO_DEPTH and only return via r_pop, which cannot happen
          -- before the request is granted, so an oversized request would
          -- deadlock. Flag it at presentation time instead.
          if f_beats(req_len(i)) > GC_FIFO_DEPTH then
            assert false
              report "axi_ar_mux: request beats " &
                     integer'image(f_beats(req_len(i))) &
                     " exceeds GC_FIFO_DEPTH " & integer'image(GC_FIFO_DEPTH) &
                     "; request can never be granted"
              severity failure;
          end if;
          if f_fits_live(credit_after(i), req_len(i)) then
            input_ready(i) := '1';
          end if;
        else
          input_ready(i) := '1';
        end if;
      elsif grant_take and (r.grant_idx = i) then
        input_ready(i) := '1';
      end if;
      if (aresetn = '1') and (input_ready(i) = '1') and
         (req_valid(i) = '1') then
        input_hs(i) := '1';
      end if;
      if grant_take and (r.grant_idx = i) then
        buf_next(i).valid := '0';
      end if;
      if input_hs(i) = '1' then
        buf_next(i).valid := '1';
        buf_next(i).addr  := req_addr(i);
        buf_next(i).len   := req_len(i);
        buf_next(i).size  := req_size(i);
        buf_next(i).burst := req_burst(i);
        buf_next(i).beats := f_clamp_beats(f_beats(req_len(i)));
      end if;
    end loop;

    -- Compute the next exact grant from buffered requests and post-edge
    -- credits. The just-consumed client is re-arbitrated from its live
    -- refill (its buffer refills on the same edge), so a single eligible
    -- client can sustain line rate; exact credit is still checked, and RR
    -- keeps other clients ahead of the re-granted one for fairness.
    scan_ptr := r.rr_pointer;
    if grant_take then
      scan_ptr := r.grant_idx;
    end if;
    grant_next_valid := false;
    grant_next_idx := 0;
    for i in 0 to GC_NUM_CLIENTS-1 loop
      eligible(i) := '0';
      if (grant_take and (r.grant_idx = i)) then
        -- Live refill of the just-consumed client.
        if (req_valid(i) = '1') and f_fits_live(credit_after(i), req_len(i)) then
          eligible(i) := '1';
        end if;
      elsif (r.client_buf(i).valid = '1') and
            (to_integer(credit_after(i)) >= r.client_buf(i).beats) then
        eligible(i) := '1';
      end if;
    end loop;
    -- Parallel rotating priority encoder: first eligible client strictly
    -- after scan_ptr (wrapping). The eligible vector is rotated into a fixed
    -- window w, validity is an OR-reduce, and the index is a prefix-OR
    -- guarded mux tree - so the scan stays flat instead of a serial chain.
    for k in 0 to GC_NUM_CLIENTS-1 loop
      cidx := (scan_ptr + 1 + k) mod GC_NUM_CLIENTS;
      w(k) := eligible(cidx);
    end loop;
    grant_next_valid := false;
    grant_next_idx := 0;
    for k in 0 to GC_NUM_CLIENTS-1 loop
      grant_next_valid := grant_next_valid or (w(k) = '1');
    end loop;
    prefix(0) := w(0);
    for k in 1 to GC_NUM_CLIENTS-1 loop
      prefix(k) := prefix(k-1) or w(k);
    end loop;
    grant_next_idx := (scan_ptr + 1) mod GC_NUM_CLIENTS;
    for k in 1 to GC_NUM_CLIENTS-1 loop
      cidx := (scan_ptr + 1 + k) mod GC_NUM_CLIENTS;
      if (w(k) = '1') and (prefix(k-1) = '0') then
        grant_next_idx := cidx;
      end if;
    end loop;

    -- Retire/promote active AR first.
    if handshake then
      if r.pending_valid = '1' then
        v.active_valid := '1';
        v.active_id := r.pending_id;
        v.active_addr := r.pending_addr;
        v.active_len := r.pending_len;
        v.active_size := r.pending_size;
        v.active_burst := r.pending_burst;
        v.active_beats := r.pending_beats;
        v.pending_valid := '0';
      else
        v.active_valid := '0';
      end if;
    elsif (r.active_valid = '0') and (r.pending_valid = '1') then
      v.active_valid := '1';
      v.active_id := r.pending_id;
      v.active_addr := r.pending_addr;
      v.active_len := r.pending_len;
      v.active_size := r.pending_size;
      v.active_burst := r.pending_burst;
      v.active_beats := r.pending_beats;
      v.pending_valid := '0';
    end if;

    -- Move the registered grant into active or pending AR.
    if grant_take then
      v.rr_pointer := r.grant_idx;
      if (r.active_valid = '0') or handshake then
        v.active_valid := '1';
        v.active_id := std_logic_vector(to_unsigned(r.grant_idx, GC_ID_WIDTH));
        v.active_addr := r.client_buf(r.grant_idx).addr;
        v.active_len := r.client_buf(r.grant_idx).len;
        v.active_size := r.client_buf(r.grant_idx).size;
        v.active_burst := r.client_buf(r.grant_idx).burst;
        v.active_beats := r.client_buf(r.grant_idx).beats;
      else
        v.pending_valid := '1';
        v.pending_id := std_logic_vector(to_unsigned(r.grant_idx, GC_ID_WIDTH));
        v.pending_addr := r.client_buf(r.grant_idx).addr;
        v.pending_len := r.client_buf(r.grant_idx).len;
        v.pending_size := r.client_buf(r.grant_idx).size;
        v.pending_burst := r.client_buf(r.grant_idx).burst;
        v.pending_beats := r.client_buf(r.grant_idx).beats;
      end if;
    end if;

    v.client_buf := buf_next;
    v.credit_cnt := credit_after;
    if grant_next_valid then
      v.grant_valid := '1';
      v.grant_idx := grant_next_idx;
    else
      v.grant_valid := '0';
      v.grant_idx := 0;
    end if;

    req_ready <= (others => '0');
    if aresetn = '1' then
      req_ready <= input_ready;
    end if;

    r_in <= v;

  end process;

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
