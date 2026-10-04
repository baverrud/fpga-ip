-----------------------------------------------------------------------
--Filename         : axi_ar_mux.vhd
--Description      : Credit-Based AXI Read-Address (AR) Multiplexer:
--                 :  - Merges GC_NUM_CLIENTS request interfaces into one
--                 :    AXI4 AR channel (ar_id = client index).
--                 :  - Per-client beat credits (depth = R-side FIFO):
--                 :    charged when a request is accepted, returned by r_pop.
--                 :  - Round-robin arbitration, one AR transaction per clock.
--                 :  - Registered AR outputs; req_ready is independent of
--                 :    ar_ready.
--                 :
--                 : Pipeline (minimum latency, ar_ready high):
--                 :   edge N   : req handshake, request enters held_request
--                 :   edge N+1 : held request is granted, ar_valid rises
--                 :   edge N+2 : AR handshake
--                 :
--                 : Contract:
--                 :  - aresetn is synchronous and active low.
--                 :  - r_pop(i) pulses once per R beat popped for client i
--                 :    and returns GC_R_BEATS_PER_POP credits. A request
--                 :    waiting on them is accepted two edges later.
--                 :  - If r_pop is never driven, the client's credits run
--                 :    out and it stalls silently with req_ready low.
--                 :  - A request with more beats than GC_FIFO_DEPTH can never
--                 :    be accepted (assertion failure).
--Author           : Rune Baeverrud
--Current Revision : 2.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;  -- slv_array_t, slv8_array_t, log2ceil, to_std_logic

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
    req_valid : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);
    req_ready : out std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- Credit returns (one pulse per R-side FIFO pop)
    r_pop : in std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- AXI Read-Address Channel (master -> downstream)
    ar_id    : out std_logic_vector(GC_ID_WIDTH-1 downto 0);
    ar_addr  : out std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    ar_len   : out std_logic_vector(7 downto 0);
    ar_valid : out std_logic;
    ar_ready : in  std_logic
  );
end entity axi_ar_mux;

architecture arch of axi_ar_mux is

  -- Structure: one state record (rec_t), one combinational process (p_comb)
  -- and one register process (p_reg), per fpga-rules/hdl_coding_rules.md.
  -- p_comb is divided into three ordered sections, each owning part of the
  -- state:
  --   1. AR side      : ar_active, ar_pending
  --   2. Arbitration  : last_granted (and moves a held request to AR)
  --   3. Admission    : held_request, credits, r_pop_delayed (per client)
  -- Credit is charged when a request is ACCEPTED, so every held request is
  -- already paid for and arbitration never needs to look at credits. That
  -- separation keeps the credit arithmetic out of the arbitration loop.

  subtype client_t  is natural range 0 to GC_NUM_CLIENTS-1;
  subtype credits_t is natural range 0 to GC_FIFO_DEPTH;  -- beats a client may still request
  subtype beats_t   is positive range 1 to 256;           -- ARLEN + 1

  type credits_array_t is array (client_t) of credits_t;

  -- Accepted request waiting for its grant; its credits are already charged.
  -- One per client: a client can have at most one request waiting here.
  type held_request_t is record
    addr  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    len   : std_logic_vector(7 downto 0);
    valid : std_logic;
  end record;

  type held_request_array_t is array (client_t) of held_request_t;

  -- One AR transaction, exactly as it appears on the AR port.
  type ar_slot_t is record
    id    : std_logic_vector(GC_ID_WIDTH-1 downto 0);
    addr  : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
    len   : std_logic_vector(7 downto 0);
    valid : std_logic;
  end record;

  type rec_t is record
    credits       : credits_array_t;
    r_pop_delayed : std_logic_vector(0 to GC_NUM_CLIENTS-1);  -- r_pop registered on input
    held_request  : held_request_array_t;
    last_granted  : client_t;   -- round-robin position
    ar_active     : ar_slot_t;  -- drives the AR port
    ar_pending    : ar_slot_t;  -- only valid while ar_active is valid
  end record;

  constant C_HELD_EMPTY : held_request_t := (
    addr  => (others => '0'),
    len   => (others => '0'),
    valid => '0'
  );

  constant C_AR_EMPTY : ar_slot_t := (
    id    => (others => '0'),
    addr  => (others => '0'),
    len   => (others => '0'),
    valid => '0'
  );

  constant C_REC_DEFAULT : rec_t := (
    credits       => (others => GC_FIFO_DEPTH),
    r_pop_delayed => (others => '0'),
    held_request  => (others => C_HELD_EMPTY),
    last_granted  => GC_NUM_CLIENTS - 1,  -- client 0 is served first
    ar_active     => C_AR_EMPTY,
    ar_pending    => C_AR_EMPTY
  );

  -- Number of beats a request asks for: AXI ARLEN counts beats minus one.
  function f_beats(len : std_logic_vector(7 downto 0)) return beats_t is
  begin
    return to_integer(unsigned(len)) + 1;
  end function;

  -- Round robin: the first requesting client after last_granted, wrapping.
  -- The loop walks from the farthest candidate to the nearest, so the
  -- nearest requesting client is the last one assigned and therefore wins.
  -- If nobody is requesting, the result is unused (grant_valid is false).
  function f_next_in_turn(requesting   : std_logic_vector;
                          last_granted : client_t) return client_t is
    variable candidate : client_t;
    variable winner    : client_t := last_granted;
  begin
    for distance in GC_NUM_CLIENTS downto 1 loop
      candidate := (last_granted + distance) mod GC_NUM_CLIENTS;
      if requesting(candidate) = '1' then
        winner := candidate;
      end if;
    end loop;
    return winner;
  end function;

  -- The AR ID is the client index, so axi_r_demux can route the R response
  -- back to the same client.
  function f_to_ar_slot(client  : client_t;
                        request : held_request_t) return ar_slot_t is
  begin
    return (id    => std_logic_vector(to_unsigned(client, GC_ID_WIDTH)),
            addr  => request.addr,
            len   => request.len,
            valid => '1');
  end function;

  signal r    : rec_t := C_REC_DEFAULT;
  signal r_in : rec_t;

begin

  assert GC_ID_WIDTH >= log2ceil(GC_NUM_CLIENTS)
    report "axi_ar_mux: GC_ID_WIDTH cannot encode GC_NUM_CLIENTS clients"
    severity failure;

  p_comb : process(all)
    variable v                : rec_t;       -- next state
    variable ar_accepted      : boolean;     -- downstream takes ar_active this clock
    variable ar_has_room      : boolean;     -- AR side can take a grant this clock
    variable held_valid       : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    variable grant_valid      : boolean;     -- a held request moves to the AR side
    variable grant_client     : client_t;    -- whose request moves
    variable holding_free     : boolean;
    variable lacks_credit     : boolean;
    variable client_ready     : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    variable request_accepted : boolean;
    variable credits_left     : integer range -256 to GC_FIFO_DEPTH - 1;
    variable returned_beats   : natural range 0 to GC_R_BEATS_PER_POP;
  begin
    v := r;

    ---------------------------------------------------------------------
    -- 1. AR side
    ---------------------------------------------------------------------
    -- When the downstream accepts ar_active, the pending transaction moves
    -- up. If nothing is pending, the copied slot has valid = '0', which
    -- empties ar_active.
    ar_accepted := (r.ar_active.valid = '1') and (ar_ready = '1');
    if ar_accepted then
      v.ar_active        := r.ar_pending;
      v.ar_pending.valid := '0';
    end if;

    ---------------------------------------------------------------------
    -- 2. Arbitration
    ---------------------------------------------------------------------
    -- Grant one held request per clock, round robin, while the AR side has
    -- somewhere to put it. The AR side has room whenever ar_pending is
    -- empty. This deliberately ignores ar_ready: the pending slot absorbs
    -- one grant during a stall, which keeps req_ready independent of
    -- ar_ready.
    ar_has_room := r.ar_pending.valid = '0';
    for i in client_t loop
      held_valid(i) := r.held_request(i).valid;
    end loop;
    grant_valid  := ar_has_room and ((or held_valid) = '1');
    grant_client := f_next_in_turn(held_valid, r.last_granted);

    -- The granted request goes straight to ar_active if that slot is free
    -- after step 1, otherwise it waits in ar_pending behind it.
    if grant_valid then
      v.last_granted                     := grant_client;
      v.held_request(grant_client).valid := '0';
      if v.ar_active.valid = '0' then
        v.ar_active  := f_to_ar_slot(grant_client, r.held_request(grant_client));
      else
        v.ar_pending := f_to_ar_slot(grant_client, r.held_request(grant_client));
      end if;
    end if;

    ---------------------------------------------------------------------
    -- 3. Admission and credits (each client independent of the others)
    ---------------------------------------------------------------------
    for i in client_t loop
      -- Credits left if this client's presented request were accepted.
      -- Negative means the request does not fit, so this one subtraction is
      -- both the credit check and the next credit value.
      credits_left   := r.credits(i) - f_beats(req_len(i));
      returned_beats := 0;
      if r.r_pop_delayed(i) = '1' then
        returned_beats := GC_R_BEATS_PER_POP;
      end if;

      -- The holding register is free if it is empty, or if its request is
      -- granted this clock. The second case lets a client hand over its next
      -- request on the same edge, which sustains one request per clock.
      holding_free := (r.held_request(i).valid = '0') or
                      (grant_valid and (grant_client = i));

      -- Only a presented request can lack credit, so an idle client with a
      -- free holding register sees req_ready high.
      lacks_credit := (req_valid(i) = '1') and (credits_left < 0);
      client_ready(i)  := to_std_logic(holding_free and not lacks_credit);
      request_accepted := (req_valid(i) and client_ready(i)) = '1';

      -- Both possible next credit values come from registers; the handshake
      -- only selects one. Keeping the handshake out of the arithmetic is
      -- what lets this loop close at 200 MHz. Returns saturate at
      -- GC_FIFO_DEPTH so an extra r_pop pulse cannot inflate the budget.
      if request_accepted then
        v.held_request(i) := (addr => req_addr(i), len => req_len(i), valid => '1');
        v.credits(i)      := minimum(credits_left + returned_beats, GC_FIFO_DEPTH);
      else
        v.credits(i)      := minimum(r.credits(i) + returned_beats, GC_FIFO_DEPTH);
      end if;

      -- Credits never exceed GC_FIFO_DEPTH, so a larger request would wait
      -- forever. Treat it as a contract violation instead of a silent stall.
      assert not ((req_valid(i) = '1') and (f_beats(req_len(i)) > GC_FIFO_DEPTH))
        report "axi_ar_mux: request beats exceed GC_FIFO_DEPTH; it can never be accepted"
        severity failure;
    end loop;

    -- r_pop is registered here and applied on the next edge, so a returned
    -- credit reaches req_ready two edges after the r_pop pulse. This keeps
    -- the R-side pop path out of the credit loop.
    v.r_pop_delayed := r_pop;

    ---------------------------------------------------------------------
    -- Outputs
    ---------------------------------------------------------------------
    -- The AR port comes straight from a register, so it stays stable while
    -- waiting for ar_ready. req_ready is the one combinational output.
    ar_id     <= r.ar_active.id;
    ar_addr   <= r.ar_active.addr;
    ar_len    <= r.ar_active.len;
    ar_valid  <= r.ar_active.valid;
    req_ready <= client_ready when aresetn = '1' else (others => '0');

    r_in <= v;
  end process;

  -- Only the global reset lives here; everything else is decided in p_comb.
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
