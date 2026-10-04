# axi_read_bridge

Composite client/native read path for a multi-client AXI system.

The bridge provides a client-domain request/response interface and connects
it to a native AXI read channel in another clock domain:

```text
aclk 100 MHz
  req_* -> axi_ar_mux -> AR axis_cdc -> native AXI AR
  rsp_* <- axi_r_demux <- R axis_cdc <- axis_upsizer <- native AXI R
mem_aclk 250 MHz
```

The default configuration is a 512-bit client interface and a 128-bit native
interface. Four native beats form one client beat. Client `req_len` counts
client beats minus one; the bridge expands the native `ARLEN` after the AR
CDC. For example, client `req_len=0` becomes native `ARLEN=3`, and client
`req_len=1` becomes native `ARLEN=7`.

## Generics

| Generic | Default | Description |
|---|---:|---|
| `GC_NUM_CLIENTS` | 4 | Number of client request/response ports. |
| `GC_ADDR_WIDTH` | 32 | Address width in bits. |
| `GC_ID_WIDTH` | 4 | Native AR/R ID width. IDs are generated from client index. |
| `GC_CLIENT_DATA_BYTES` | 64 | Client response width in bytes. |
| `GC_NATIVE_DATA_BYTES` | 16 | Native R data width in bytes. |
| `GC_NATIVE_ARLEN_WIDTH` | 8 | Native ARLEN width; use 4 for AXI3. |
| `GC_CLIENT_FIFO_DEPTH` | 32 | Per-client response FIFO and client-beat credit depth. 32 fits SRL32. |
| `GC_CDC_DEPTH` | 8 | Depth of each AR/R CDC FIFO; must be a power of two. |
| `GC_SYNC_STAGES` | 2 | CDC pointer synchronizer stages. |

The client ARLEN width is derived as
`GC_NATIVE_ARLEN_WIDTH - log2(GC_CLIENT_DATA_BYTES / GC_NATIVE_DATA_BYTES)`.
The data-byte ratio must be an integral power of two. The core native AR port
exposes the dynamic signals (`ar_id`, `ar_addr`, `ar_len`, `ar_valid`,
`ar_ready`). ARSIZE, ARBURST, and the other AXI sidebands are constants tied
by the AXI-facing wrapper or consumer, matching a real AXI_HP port. The
`axi_read_bridge_top` wrapper exposes the derived `ar_size` at that AXI
boundary; the core `axi_read_bridge` entity does not.

## Client interface

`req_addr`, `req_len`, `req_valid`, and `req_ready` form the request input.
`req_len` is the number of client-domain beats minus one. The client beat
width is `8 * GC_CLIENT_DATA_BYTES` bits. The client must hold the request
payload stable while `req_valid='1'` and `req_ready='0'`.

### Request size limit

`req_len` is `GC_NATIVE_ARLEN_WIDTH - log2(ratio)` bits wide (6 bits in
the default configuration), so the port can encode values up to 63. A
single request is, however, limited to `GC_CLIENT_FIFO_DEPTH` client
beats, i.e. `req_len <= GC_CLIENT_FIFO_DEPTH - 1` (31 in the default
configuration). The per-client credit budget (the R-side response FIFO
depth) is the maximum number of beats a client may have in flight, and
credits only return as responses are popped, so a larger request can
never be granted and would deadlock. The AR mux flags such a request at
presentation time with an assertion failure:

```text
axi_ar_mux: request beats N exceeds GC_CLIENT_FIFO_DEPTH M; request can never be granted
```

Clients must split transfers larger than `GC_CLIENT_FIFO_DEPTH` beats
into multiple requests (e.g. one per `GC_CLIENT_FIFO_DEPTH`-beat window),
or increase `GC_CLIENT_FIFO_DEPTH` to cover the largest single request.

`rsp_data`, `rsp_resp`, `rsp_last`, `rsp_valid`, and `rsp_ready` form the
per-client response output. One `rsp_data` beat is one client-domain beat.
A response pop returns one client-beat credit to the AR mux. `rsp_resp` is
the worst (numerically largest) `RRESP` of the native beats packed into that
client beat, so a single failing native beat is never lost.

### Request rules

- `req_addr` must be aligned to `GC_CLIENT_DATA_BYTES`. The upsizer packs
  native beats in fixed groups, so an unaligned start would shift every
  client beat.
- A request must not cross a 4 KiB boundary (AXI burst rule). The bridge
  forwards `req_addr` unchanged and does not split bursts.

Both rules are checked in simulation (`p_req_check`, severity failure) and
are not checked in hardware.

## Clocks and reset

`aclk` and `mem_aclk` are independent; any ratio, including non-integer
ratios, is supported. `aresetn` is active low and may be asynchronous: the
bridge synchronizes it into each domain (assert asynchronously, release
synchronously) before driving the mux, demux and upsizer. Hold it low for
at least a few cycles of the slower clock.

The bridge does not drain bursts that are in flight at reset. Reset the
native slave (or let it finish its outstanding bursts) together with the
bridge, otherwise stale R beats arrive after reset with no matching credit.

## Composition

The RTL instantiates `axi_ar_mux`, two `axis_cdc` instances, `axis_upsizer`,
and `axi_r_demux`.

## Testbenches

| Bench | Command | Native slave |
|---|---|---|
| `default` | `run axi_read_bridge vhdl modelsim` | `axi_mem_store`, filled with a known pattern |
| `model` | `run axi_read_bridge vhdl modelsim --tb model` | `axi_mem_model` (data derived from the address) |
| `simple` | `run axi_read_bridge vhdl modelsim --tb simple` | `axi_mem_store`, one client, four requests |

The comprehensive bench (`default` / `model`) runs a 4.3 ns native clock
against a 10 ns client clock (non-integer ratio, `-t ps`). Its phases cover
single and multi-beat requests on all clients, simultaneous requests, a
maximum-length request, back-pressure on the client and native sides,
reset with a response in flight, `RRESP` forwarding (every beat, and a
single SLVERR beat
inside a packed group), out-of-order bursts across IDs, a read past the end
of the store (SLVERR with zero data, store variant only), and an exact
native AR/ARLEN sequence check. The simple bench is a short starting point
for experiments.

All three are simulation-only; the memory models are listed in the tb
sections of `scripts/vhdl.f` so they never reach synthesis.

## CDC constraints

This IP contains two `axis_cdc` instances. For Vivado implementation, apply
and adapt the constraints in `axis_cdc/constr/` for the actual clocks and
synthesized hierarchy. The templates are not valid unchanged for every
integration.

## Monitoring note

The native side of this bridge supports **ID reordering**: requests from
multiple clients are outstanding simultaneously (up to the per-client
credit limit), and the native downstream may return R bursts in any order
across IDs; `axi_r_demux` routes them back per client.  A per-client
in-order scoreboard on the native AR/R bus would mis-attribute reordered
bursts, so verify the native side with an in-order slave (`axi_mem_store`
or `axi_mem_model`, as in the integration testbench) or a per-ID
scoreboard.  The client side is
verified with the `axi_monitor` IP, which taps each client's `req_*` /
`rsp_*` interface (no ID, in-order per client).

Related requirement: the R path packs contiguous native beats into one
client beat (`axis_upsizer`), so the native slave must not interleave R
beats from different IDs. AXI itself allows read-data interleaving across
IDs, so this is a real restriction on the slave. Zynq HP ports and typical
DDR controllers return each burst contiguously and satisfy it. An
interleave within a pack window trips the upsizer's "rid changed within
packed group" assertion in simulation.

## Instantiation

The examples below use the default **4-client, 64-byte client / 16-byte
native (4:1), 32-bit-address, 4-bit-ID** configuration. The array ports use
the shared package types `slv_array_t` / `slv2_array_t` from `work.util_pkg`,
so the instantiating design must include `use work.util_pkg.all;` in VHDL.
`req_len` is client beats minus one; the bridge expands it to the native
`ARLEN` after the AR CDC. The native AR sidebands (`ar_burst` = `INCR`,
lock/cache/prot/qos/region/user) are constants tied by the consumer,
matching a real AXI_HP port.

### VHDL

```vhdl
use work.util_pkg.all;  -- slv_array_t, slv2_array_t

-- ---------------------------------------------------------------------
-- Signals (grouped by interface)
-- ---------------------------------------------------------------------
constant C_NUM_CLIENTS : positive := 4;   -- must match GC_NUM_CLIENTS
constant C_CLIENT_BYTES : positive := 64; -- must match GC_CLIENT_DATA_BYTES
constant C_LEN_WIDTH    : positive := 6;  -- GC_NATIVE_ARLEN_WIDTH - log2(ratio)

-- Clock / reset
signal aclk     : std_logic;
signal mem_aclk : std_logic;
signal aresetn  : std_logic;  -- active low, may be asynchronous

-- Client request interfaces (array indexed 0..C_NUM_CLIENTS-1)
signal req_addr  : slv_array_t(0 to C_NUM_CLIENTS-1)(31 downto 0);  -- araddr
signal req_len   : slv_array_t(0 to C_NUM_CLIENTS-1)(C_LEN_WIDTH-1 downto 0);  -- beats-1
signal req_valid : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal req_ready : std_logic_vector(0 to C_NUM_CLIENTS-1);

-- Client response interfaces
signal rsp_data  : slv_array_t(0 to C_NUM_CLIENTS-1)(8*C_CLIENT_BYTES-1 downto 0);
signal rsp_resp  : slv2_array_t(0 to C_NUM_CLIENTS-1);
signal rsp_last  : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal rsp_valid : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal rsp_ready : std_logic_vector(0 to C_NUM_CLIENTS-1);

-- Native AXI read-address channel
signal ar_id    : std_logic_vector(3 downto 0);   -- client index
signal ar_addr  : std_logic_vector(31 downto 0);  -- araddr
signal ar_len   : std_logic_vector(7 downto 0);   -- native arlen (beats-1)
signal ar_valid : std_logic;
signal ar_ready : std_logic;

-- Native AXI read-data channel
signal r_id    : std_logic_vector(3 downto 0);
signal r_data  : std_logic_vector(127 downto 0);  -- 8*GC_NATIVE_DATA_BYTES
signal r_resp  : std_logic_vector(1 downto 0);
signal r_last  : std_logic;
signal r_valid : std_logic;
signal r_ready : std_logic;

-- ---------------------------------------------------------------------
-- Instantiation (grouped port map)
-- ---------------------------------------------------------------------
u_bridge : entity work.axi_read_bridge
  generic map (
    GC_NUM_CLIENTS        => 4,   -- number of clients
    GC_ADDR_WIDTH         => 32,  -- address width (bits)
    GC_ID_WIDTH           => 4,   -- native AR/R ID width (bits)
    GC_CLIENT_DATA_BYTES  => 64,  -- client beat width (bytes)
    GC_NATIVE_DATA_BYTES  => 16,  -- native beat width (bytes)
    GC_NATIVE_ARLEN_WIDTH => 8,   -- native ARLEN width (bits)
    GC_CLIENT_FIFO_DEPTH  => 32,  -- per-client credits / response depth
    GC_CDC_DEPTH          => 8,   -- AR/R CDC FIFO depth (power of two)
    GC_SYNC_STAGES        => 2    -- CDC pointer synchronizer stages
  )
  port map (
    -- Clock / reset
    aclk     => aclk,
    mem_aclk => mem_aclk,
    aresetn  => aresetn,

    -- Client request interfaces
    req_addr  => req_addr,
    req_len   => req_len,
    req_valid => req_valid,
    req_ready => req_ready,

    -- Client response interfaces
    rsp_data  => rsp_data,
    rsp_resp  => rsp_resp,
    rsp_last  => rsp_last,
    rsp_valid => rsp_valid,
    rsp_ready => rsp_ready,

    -- Native AXI read-address channel
    ar_id    => ar_id,
    ar_addr  => ar_addr,
    ar_len   => ar_len,
    ar_valid => ar_valid,
    ar_ready => ar_ready,

    -- Native AXI read-data channel
    r_id    => r_id,
    r_data  => r_data,
    r_resp  => r_resp,
    r_last  => r_last,
    r_valid => r_valid,
    r_ready => r_ready
  );
```

### SystemVerilog

```systemverilog
// ---------------------------------------------------------------------
// Signals (grouped by interface)
// ---------------------------------------------------------------------
localparam int unsigned C_NUM_CLIENTS = 4;  // must match GC_NUM_CLIENTS
localparam int unsigned C_LEN_WIDTH   = 6;  // GC_NATIVE_ARLEN_WIDTH - $clog2(ratio)

// Clock / reset
logic aclk;
logic mem_aclk;
logic aresetn;  // active low, may be asynchronous

// Client request interfaces (packed arrays, client index outer)
logic [C_NUM_CLIENTS-1:0][31:0]           req_addr;
logic [C_NUM_CLIENTS-1:0][C_LEN_WIDTH-1:0] req_len;
logic [C_NUM_CLIENTS-1:0]                 req_valid;
logic [C_NUM_CLIENTS-1:0]                 req_ready;

// Client response interfaces
logic [C_NUM_CLIENTS-1:0][511:0] rsp_data;
logic [C_NUM_CLIENTS-1:0][1:0]   rsp_resp;
logic [C_NUM_CLIENTS-1:0]        rsp_last;
logic [C_NUM_CLIENTS-1:0]        rsp_valid;
logic [C_NUM_CLIENTS-1:0]        rsp_ready;

// Native AXI read-address channel
logic [3:0]  ar_id;     // client index
logic [31:0] ar_addr;   // araddr
logic [7:0]  ar_len;    // native arlen (beats-1)
logic        ar_valid;
logic        ar_ready;

// Native AXI read-data channel
logic [3:0]   r_id;
logic [127:0] r_data;
logic [1:0]   r_resp;
logic         r_last;
logic         r_valid;
logic         r_ready;

// ---------------------------------------------------------------------
// Instantiation (grouped port map)
// ---------------------------------------------------------------------
axi_read_bridge #(
    .GC_NUM_CLIENTS        (4),
    .GC_ADDR_WIDTH         (32),
    .GC_ID_WIDTH           (4),
    .GC_CLIENT_DATA_BYTES  (64),
    .GC_NATIVE_DATA_BYTES  (16),
    .GC_NATIVE_ARLEN_WIDTH (8),
    .GC_CLIENT_FIFO_DEPTH  (32),
    .GC_CDC_DEPTH          (8),
    .GC_SYNC_STAGES        (2)
) u_bridge (
    // Clock / reset
    .aclk     (aclk),
    .mem_aclk (mem_aclk),
    .aresetn  (aresetn),

    // Client request interfaces
    .req_addr  (req_addr),
    .req_len   (req_len),
    .req_valid (req_valid),
    .req_ready (req_ready),

    // Client response interfaces
    .rsp_data  (rsp_data),
    .rsp_resp  (rsp_resp),
    .rsp_last  (rsp_last),
    .rsp_valid (rsp_valid),
    .rsp_ready (rsp_ready),

    // Native AXI read-address channel
    .ar_id    (ar_id),
    .ar_addr  (ar_addr),
    .ar_len   (ar_len),
    .ar_valid (ar_valid),
    .ar_ready (ar_ready),

    // Native AXI read-data channel
    .r_id    (r_id),
    .r_data  (r_data),
    .r_resp  (r_resp),
    .r_last  (r_last),
    .r_valid (r_valid),
    .r_ready (r_ready)
);
```
