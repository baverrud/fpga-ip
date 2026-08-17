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
--Current Revision : 1.01
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

  -- Beat counts are clamped to GC_FIFO_DEPTH + 1 everywhere, so one
  -- subtype covers all uses.
  subtype beats_t is integer range 0 to GC_FIFO_DEPTH + 1;

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

  -- Credit return with saturation at the FIFO depth.
  function f_sat_return(c : unsigned(C_CREDIT_W-1 downto 0))
                        return unsigned is
    variable v : integer;
  begin
    v := to_integer(c) + GC_R_BEATS_PER_POP;
    if v > GC_FIFO_DEPTH then
      v := GC_FIFO_DEPTH;
    end if;
    return to_unsigned(v, C_CREDIT_W);
  end function;

  -- One AR transaction slot (active or pending). The id is generated from
  -- the granting client index; no beat field is stored here (payload only -
  -- beat accounting lives in the client buffer and the credit counters).
  type slot_t is record
    valid : std_logic;
    id    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
    addr  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    len   : std_logic_vector(7 downto 0);
    size  : std_logic_vector(2 downto 0);
    burst : std_logic_vector(1 downto 0);
  end record;

  constant C_SLOT_DEFAULT : slot_t := (
    valid => '0',
    id    => (others => '0'),
    addr  => (others => '0'),
    len   => (others => '0'),
    size  => (others => '0'),
    burst => (others => '0')
  );

  -- Per-client input buffer: a presented request waiting for its grant.
  type client_buf_t is record
    valid : std_logic;
    addr  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    len   : std_logic_vector(7 downto 0);
    size  : std_logic_vector(2 downto 0);
    burst : std_logic_vector(1 downto 0);
    beats : beats_t;
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
    active  : slot_t;  -- presented on AR (held until handshake)
    pending : slot_t;  -- accepted while active is stalled

    client_buf : client_buf_array_t;
    rr_pointer : integer range 0 to GC_NUM_CLIENTS-1;
    credit_cnt : credit_array_t;

    grant_valid : std_logic;
    grant_idx   : integer range 0 to GC_NUM_CLIENTS-1;
  end record;

  constant C_REC_DEFAULT : rec_t := (
    active      => C_SLOT_DEFAULT,
    pending     => C_SLOT_DEFAULT,
    client_buf  => (others => C_BUF_DEFAULT),
    rr_pointer  => GC_NUM_CLIENTS - 1,
    credit_cnt  => (others => to_unsigned(GC_FIFO_DEPTH, C_CREDIT_W)),
    grant_valid => '0',
    grant_idx   => 0
  );

  -- Parallel rotating priority encoder: first eligible client strictly
  -- after scan_ptr (wrapping). The eligible vector is rotated into a fixed
  -- window and resolved with a prefix-OR guarded mux tree, so the scan
  -- stays flat instead of a serial chain.
  function f_rr_grant_idx(eligible : std_logic_vector;
                          scan_ptr : integer range 0 to GC_NUM_CLIENTS-1)
                          return integer is
    variable w      : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    variable prefix : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    variable idx    : integer range 0 to GC_NUM_CLIENTS-1;
    variable cidx   : integer range 0 to GC_NUM_CLIENTS-1;
  begin
    for k in 0 to GC_NUM_CLIENTS-1 loop
      cidx := (scan_ptr + 1 + k) mod GC_NUM_CLIENTS;
      w(k) := eligible(cidx);
    end loop;
    prefix(0) := w(0);
    for k in 1 to GC_NUM_CLIENTS-1 loop
      prefix(k) := prefix(k-1) or w(k);
    end loop;
    idx := (scan_ptr + 1) mod GC_NUM_CLIENTS;
    for k in 1 to GC_NUM_CLIENTS-1 loop
      cidx := (scan_ptr + 1 + k) mod GC_NUM_CLIENTS;
      if (w(k) = '1') and (prefix(k-1) = '0') then
        idx := cidx;
      end if;
    end loop;
    return idx;
  end function;

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
    variable input_ready      : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    variable input_hs         : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    variable grant_next_valid : boolean;
    variable grant_next_idx   : integer range 0 to GC_NUM_CLIENTS-1;
    variable scan_ptr         : integer range 0 to GC_NUM_CLIENTS-1;
    variable handshake        : boolean;
    variable grant_take       : boolean;
    variable place_active     : boolean;

    -- Retire the active AR slot and promote the pending slot into it. On a
    -- handshake the active slot frees (pending moves in if filled); without
    -- a handshake a filled pending slot moves into an empty active slot.
    procedure p_retire(variable s : inout rec_t;
                       constant hs : boolean) is
    begin
      if hs then
        if s.pending.valid = '1' then
          s.active        := s.pending;
          s.pending.valid := '0';
        else
          s.active.valid := '0';
        end if;
      elsif (s.active.valid = '0') and (s.pending.valid = '1') then
        s.active        := s.pending;
        s.pending.valid := '0';
      end if;
    end procedure;

    -- Move a consumed grant into the active slot when it is free this
    -- edge, otherwise into the pending slot.
    procedure p_place(variable s : inout rec_t;
                      constant idx       : integer range 0 to GC_NUM_CLIENTS-1;
                      constant to_active : boolean) is
    begin
      if to_active then
        s.active.valid := '1';
        s.active.id    := std_logic_vector(to_unsigned(idx, GC_ID_WIDTH));
        s.active.addr  := s.client_buf(idx).addr;
        s.active.len   := s.client_buf(idx).len;
        s.active.size  := s.client_buf(idx).size;
        s.active.burst := s.client_buf(idx).burst;
      else
        s.pending.valid := '1';
        s.pending.id    := std_logic_vector(to_unsigned(idx, GC_ID_WIDTH));
        s.pending.addr  := s.client_buf(idx).addr;
        s.pending.len   := s.client_buf(idx).len;
        s.pending.size  := s.client_buf(idx).size;
        s.pending.burst := s.client_buf(idx).burst;
      end if;
    end procedure;

    -- Exact eligibility for the next grant. The just-consumed client is
    -- eligible via its live refill; the others via their buffered request
    -- and the post-edge credits.
    function f_eligible(buf : client_buf_array_t;
                        credit_after : credit_array_t;
                        req_valid    : std_logic_vector;
                        req_len      : slv8_array_t;
                        grant_take   : boolean;
                        grant_idx    : integer range 0 to GC_NUM_CLIENTS-1)
                        return std_logic_vector is
      variable e : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    begin
      e := (others => '0');
      for i in 0 to GC_NUM_CLIENTS-1 loop
        if grant_take and (grant_idx = i) then
          if (req_valid(i) = '1') and
             f_fits_live(credit_after(i), req_len(i)) then
            e(i) := '1';
          end if;
        elsif (buf(i).valid = '1') and
              (to_integer(credit_after(i)) >= buf(i).beats) then
          e(i) := '1';
        end if;
      end loop;
      return e;
    end function;

  begin
    v := r;

    ar_valid  <= r.active.valid;
    ar_id     <= r.active.id;
    ar_addr   <= r.active.addr;
    ar_len    <= r.active.len;
    ar_size   <= r.active.size;
    ar_burst  <= r.active.burst;

    -- A grant is consumed whenever the pending AR slot is free. It then
    -- targets active AR if that slot is free at the edge, otherwise pending.
    -- The decision itself does not depend on ar_ready.
    handshake := (r.active.valid = '1') and (ar_ready = '1');
    grant_take := (r.grant_valid = '1') and (r.pending.valid = '0');
    place_active := (r.active.valid = '0') or handshake;

    -- Reserve the current grant and apply credit returns before evaluating a
    -- possible same-edge buffer refill. This keeps the client handshake
    -- from accepting a request that would exceed the post-edge budget.
    -- The per-client reservation subtracts stay parallel; grant_idx only
    -- selects the matching result. They must live in this process: a
    -- separate combinational process for the subtract races p_logic in the
    -- same delta (a simulator may read the stale result and lose the debit).
    --
    -- NOTE (possible optimization, not applied): applying the returns here
    -- keeps them on the critical reservation->ready path. Moving this loop
    -- after the eligibility computation (register-update only) removes the
    -- saturating add from that path and improves post-route WNS by +0.249 ns
    -- at 143 MHz, at the cost of returns becoming visible to req_ready one
    -- cycle later (conservative; line rate unaffected). See README
    -- "Possible timing improvement: delayed credit returns".
    for i in 0 to GC_NUM_CLIENTS-1 loop
      credit_resv(i) := r.credit_cnt(i) - r.client_buf(i).beats;
    end loop;
    credit_after := r.credit_cnt;
    if grant_take then
      credit_after(r.grant_idx) := credit_resv(r.grant_idx);
    end if;
    for i in 0 to GC_NUM_CLIENTS-1 loop
      if r_pop(i) = '1' then
        credit_after(i) := f_sat_return(credit_after(i));
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

    -- Compute the next exact grant from the post-accept buffers (buf_next)
    -- and post-edge credits.  Using buf_next - which already includes a
    -- request accepted into an empty buffer this cycle - makes the pipeline
    -- self-priming: the very first request after reset is granted on the
    -- same edge it is accepted, so req_ready never bubbles and the input
    -- holds line rate from the first cycle, not just steady state.  The
    -- just-consumed client is re-arbitrated from its live refill (its buffer
    -- refills on the same edge), so a single eligible client can sustain
    -- line rate; exact credit is still checked, and RR keeps other clients
    -- ahead of the re-granted one for fairness.
    scan_ptr := r.rr_pointer;
    if grant_take then
      scan_ptr := r.grant_idx;
    end if;
    eligible := f_eligible(buf_next, credit_after, req_valid, req_len,
                           grant_take, r.grant_idx);
    grant_next_valid := false;
    for i in 0 to GC_NUM_CLIENTS-1 loop
      grant_next_valid := grant_next_valid or (eligible(i) = '1');
    end loop;
    grant_next_idx := f_rr_grant_idx(eligible, scan_ptr);

    -- Retire/promote the active AR first, then move the registered grant
    -- into active or pending AR. p_place reads the client buffer of the
    -- consumed grant; the buffer itself is updated below.
    p_retire(v, handshake);
    if grant_take then
      v.rr_pointer := r.grant_idx;
      p_place(v, r.grant_idx, place_active);
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
