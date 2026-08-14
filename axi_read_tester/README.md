# axi_read_tester

Synthesizable multi-client AXI read-path **tester / diagnostic engine**: a
shared `axi_read_bridge` to a native AXI read master, with one client slice
per `GC_NUM_CLIENTS` consisting of a request generator (`axi_req_gen`), a
passive request/response monitor (`axi_monitor`), and an AXI4-Lite register
interface (`axilite_io`) that drives the generator/monitor control and
returns their statistics.

> This is a **synthesis target** (a silicon read-path test/diagnostic
> engine) - **not** a simulation testbench. `_tb` names in this repo are
> testbenches; this IP is the hardware under test.

## Block Diagram

```text
                      +---------------------------------------------+
  s_axi_* (client 0)  |  +-----------+  +---------+  +----------+  |
   AXI4-Lite (config  |  | axilite_io|  | req_gen |  | monitor  |  |
   + status registers)|  |  o_data   |->| cfg/ctl |  | (taps)   |  |
                      |  |  i_data   |<-| stats   |<-| req/rsp  |  |
                      |  +-----------+  +----+----+  +----+-----+  |
                      |        ... per client x GC_NUM_CLIENTS ... |
                      |                    req            rsp      |
                      |                    |              |        |
                      |                 +--+---- axi_read_bridge --+
                      |                 |    (mux/cdc/up/demux)    |
                      +-----------------|--------------------------+
                                        | ar                    | r
                                        v                        ^
                              native AXI read master  ->  downstream AXI read slave
```

The native master is exposed (`ar_id/addr/len/size/valid/ready`,
`r_id/data/resp/last/valid/ready`) so the tester drives any AXI read slave -
typically `axi_mem_model` in the testbench, or a real memory controller in
an integration. The read data is consumed only by the per-client monitor
tap (`rsp_ready` is held high), so the tester is purely a generate-and-
observe engine.

## Generics

| Generic              | Default | Description |
|----------------------|---------|-------------|
| `GC_NUM_CLIENTS`     | 4    | Number of client slices. |
| `GC_ADDR_WIDTH`      | 32   | Address width. |
| `GC_ID_WIDTH`        | 4    | Native AR/R ID width; must encode `GC_NUM_CLIENTS`. |
| `GC_CLIENT_DATA_BYTES` | 64 | Client beat width (bytes). |
| `GC_NATIVE_DATA_BYTES` | 16 | Native beat width (bytes). |
| `GC_NATIVE_ARLEN_WIDTH` | 8 | Native ARLEN width. |
| `GC_MAX_BURST`       | 32   | Max client beats per burst (generator length width). |
| `GC_CLIENT_FIFO_DEPTH` | 32 | Per-client bridge FIFO depth (credits). |
| `GC_CDC_DEPTH`       | 8    | Bridge clock-crossing FIFO depth. |
| `GC_SYNC_STAGES`     | 2    | Bridge CDC sync stages. |
| `GC_MON_SB_DEPTH`    | 256  | Per-client monitor scoreboard depth. |
| `GC_MON_TIME_WIDTH`  | 48   | `global_time` input width. |
| `GC_NUM_TESTERS`     | 4    | Number of tester cores in `axi_read_tester_top`. |
| `GC_PULSE_LEN`       | 1024 | Aperture window length (cycles) in `axi_read_tester_top`. |

## Ports

- **`aclk`, `mem_aclk`, `aresetn`** - the client and native clock
  domains (the bridge crosses between them; they may be the same clock).
- **Per-client AXI4-Lite slave** (`s_axi_*`) - register config/status, 16-bit
  address, 32-bit data, indexed by client.
- **`aperture`, `stat_rst`, `err_rst`** - per-client external control
  (measurement window, clear statistics, clear monitor error counters). Not
  register-backed, so an array of these testers can share common control.
- **`global_time`** - shared unsigned time reference feeding the monitor
  latency statistics.
- **`pipeline_busy`** - per-client monitor busy status (0 = drained).
- **Native AXI read master** (`ar_*`, `r_*`).

## Top-level integration (`axi_read_tester_top`)

`axi_read_tester_top.vhd` packages `GC_NUM_TESTERS` copies of the core (default
4) plus one local global `axilite_io`, for `GC_NUM_TESTERS*GC_NUM_CLIENTS + 1`
total AXI4-Lite slave interfaces - every one independent, so each tester is
directly accessible with no internal address decode.

### AXI4-Lite slave index map

| Index | Target |
|-------|--------|
| `0 .. N_TESTERS*N_CLIENTS-1` | Client `axilite_io` (tester `t`, client `c` -> index `t*N_CLIENTS + c`) |
| `N_TESTERS*N_CLIENTS` (= 16) | Local global `axilite_io` |

Each slave uses the standard `axilite_io` register map (see below).

### Local global `axilite_io`

- `o_data[0]` bit 0 -> `led(N_TESTERS*N_CLIENTS)` (local LED bit).
- `i_data[0]` = lower 32 bits of the free-running `global_time` counter.
- Stream pushes (region `01`) generate one-cycle pulses: channel 0 ->
  `stat_rst`, channel 1 -> `err_rst`, channel 2 -> aperture trigger (fed
  through `pulse_extender`, held `GC_PULSE_LEN` cycles).

### Shared / arrayed signals

- `led` : `0 .. N_TESTERS*N_CLIENTS` bits - one per client, plus the local
  bit at the highest index.
- `global_time`, `aperture`, `stat_rst`, `err_rst` are generated/shared inside
  the top (all testers see the same values).
- Native read masters `ar_*` / `r_*` are arrayed, one per tester.

## Per-client Register Map (via `axilite_io`)

`o_data` registers (`0x0000`..`0x0010`, one per client):

| Addr | Name | Bits |
|------|------|------|
| `0x0000` | `o_data[0]` | `0`=enable, `1`=res, `2`=res, `3`=mon_enable, `4`=res, `5`=res, `6`=data_check_en, `7`=cfg_len_mode, `8`=cfg_addr_mode, `[9+LEN-1:9]`=cfg_req_len, `[9+2LEN-1:9+LEN]`=cfg_max_len (LEN = `log2(GC_MAX_BURST)`). Bits 1,2,4,5 were `aperture`/`stat_rst`/`mon_stat_rst`/`mon_err_rst` - now external ports. |
| `0x0004` | `o_data[1]` | `cfg_pace[31:0]` |
| `0x0008` | `o_data[2]` | `cfg_pace_init[31:0]` |
| `0x000C` | `o_data[3]` | `cfg_base_addr[31:0]` |
| `0x0010` | `o_data[4]` | `cfg_addr_range[31:0]` |
| `0x0014` | `o_data[5]` | `0`=LED (one bit per client, combined into the top `led` vector) |

`i_data` registers (read-only, `0x8000` base). All `axi_monitor` statistics
are mapped; the four 48-bit `*_sum` counters occupy two words each
(low = index k, high = index k+1):

| Index | Statistic | Index | Statistic |
|-------|-----------|-------|-----------|
| 0 | `req_gen` `stat_req_issued` | 16 | `stat_interbeat_gap_sum[31:0]` |
| 1 | `req_gen` `stat_req_stall` | 17 | `stat_interbeat_gap_sum[47:32]` |
| 2 | `req_gen` `stat_cfg_errors` | 18 | `stat_interbeat_gap_min` |
| 3 | `stat_req_seen` | 19 | `stat_interbeat_gap_max` |
| 4 | `stat_req_stall` | 20 | `stat_burst_len_sum[31:0]` |
| 5 | `stat_sb_backpressure` | 21 | `stat_burst_len_sum[47:32]` |
| 6 | `stat_xactions` | 22 | `stat_burst_len_min` |
| 7 | `stat_beats` | 23 | `stat_burst_len_max` |
| 8 | `stat_latency_sum[31:0]` | 24 | `stat_elapsed_cycles` |
| 9 | `stat_latency_sum[47:32]` | 25 | `stat_rsp_stall` |
| 10 | `stat_latency_min` | 26 | `stat_max_outstanding` |
| 11 | `stat_latency_max` | 27 | `stat_data_errors` |
| 12 | `stat_first_latency_sum[31:0]` | 28 | `stat_rlast_errors` |
| 13 | `stat_first_latency_sum[47:32]` | 29 | `stat_resp_errors` |
| 14 | `stat_first_latency_min` | 30 | `stat_sb_underflow_errors` |
| 15 | `stat_first_latency_max` | | |

Indexes 3-30 are `axi_monitor` outputs.

## Instantiation

The examples below use the default **4-client** configuration. The arrayed
AXI4-Lite slave and per-client control/status ports use the shared package
types from `work.util_pkg`, so the instantiating design must include
`use work.util_pkg.all;` in VHDL. `global_time` is a shared time reference
(48 bits by default); the native `ar_*` / `r_*` master connects to the
downstream AXI read slave.

### VHDL

```vhdl
use work.util_pkg.all;  -- slv_array_t, slv32_array_t, slv2_array_t

-- ---------------------------------------------------------------------
-- Signals (grouped by interface)
-- ---------------------------------------------------------------------
constant C_NUM_CLIENTS : positive := 4;  -- must match GC_NUM_CLIENTS

-- Clock / reset
signal aclk     : std_logic;
signal mem_aclk : std_logic;
signal aresetn  : std_logic;  -- synchronous, active low

-- AXI4-Lite slave per client (config/status registers)
signal s_axi_awaddr  : slv_array_t(0 to C_NUM_CLIENTS-1)(15 downto 0);
signal s_axi_awprot  : slv_array_t(0 to C_NUM_CLIENTS-1)(2 downto 0);
signal s_axi_awvalid : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal s_axi_awready : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal s_axi_wdata   : slv32_array_t(0 to C_NUM_CLIENTS-1);
signal s_axi_wstrb   : slv_array_t(0 to C_NUM_CLIENTS-1)(3 downto 0);
signal s_axi_wvalid  : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal s_axi_wready  : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal s_axi_bresp   : slv2_array_t(0 to C_NUM_CLIENTS-1);
signal s_axi_bvalid  : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal s_axi_bready  : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal s_axi_araddr  : slv_array_t(0 to C_NUM_CLIENTS-1)(15 downto 0);
signal s_axi_arprot  : slv_array_t(0 to C_NUM_CLIENTS-1)(2 downto 0);
signal s_axi_arvalid : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal s_axi_arready : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal s_axi_rdata   : slv32_array_t(0 to C_NUM_CLIENTS-1);
signal s_axi_rresp   : slv2_array_t(0 to C_NUM_CLIENTS-1);
signal s_axi_rvalid  : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal s_axi_rready  : std_logic_vector(0 to C_NUM_CLIENTS-1);

-- Per-client status / external control
signal pipeline_busy : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal led           : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal aperture      : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal stat_rst      : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal err_rst       : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal global_time   : unsigned(47 downto 0);  -- GC_MON_TIME_WIDTH

-- Native AXI read master
signal ar_id    : std_logic_vector(3 downto 0);
signal ar_addr  : std_logic_vector(31 downto 0);
signal ar_len   : std_logic_vector(7 downto 0);
signal ar_size  : std_logic_vector(2 downto 0);
signal ar_valid : std_logic;
signal ar_ready : std_logic;
signal r_id     : std_logic_vector(3 downto 0);
signal r_data   : std_logic_vector(127 downto 0);  -- 8*GC_NATIVE_DATA_BYTES
signal r_resp   : std_logic_vector(1 downto 0);
signal r_last   : std_logic;
signal r_valid  : std_logic;
signal r_ready  : std_logic;

-- ---------------------------------------------------------------------
-- Instantiation (grouped port map)
-- ---------------------------------------------------------------------
u_tester : entity work.axi_read_tester
  generic map (
    GC_NUM_CLIENTS        => 4,
    GC_ADDR_WIDTH         => 32,
    GC_ID_WIDTH           => 4,
    GC_CLIENT_DATA_BYTES  => 64,
    GC_NATIVE_DATA_BYTES  => 16,
    GC_NATIVE_ARLEN_WIDTH => 8,
    GC_MAX_BURST          => 32,
    GC_CLIENT_FIFO_DEPTH  => 32,
    GC_CDC_DEPTH          => 8,
    GC_SYNC_STAGES        => 2,
    GC_MON_SB_DEPTH       => 256,
    GC_MON_TIME_WIDTH     => 48
  )
  port map (
    -- Clock / reset
    aclk     => aclk,
    mem_aclk => mem_aclk,
    aresetn  => aresetn,

    -- AXI4-Lite slave per client
    s_axi_awaddr  => s_axi_awaddr,
    s_axi_awprot  => s_axi_awprot,
    s_axi_awvalid => s_axi_awvalid,
    s_axi_awready => s_axi_awready,
    s_axi_wdata   => s_axi_wdata,
    s_axi_wstrb   => s_axi_wstrb,
    s_axi_wvalid  => s_axi_wvalid,
    s_axi_wready  => s_axi_wready,
    s_axi_bresp   => s_axi_bresp,
    s_axi_bvalid  => s_axi_bvalid,
    s_axi_bready  => s_axi_bready,
    s_axi_araddr  => s_axi_araddr,
    s_axi_arprot  => s_axi_arprot,
    s_axi_arvalid => s_axi_arvalid,
    s_axi_arready => s_axi_arready,
    s_axi_rdata   => s_axi_rdata,
    s_axi_rresp   => s_axi_rresp,
    s_axi_rvalid  => s_axi_rvalid,
    s_axi_rready  => s_axi_rready,

    -- Per-client status / external control
    pipeline_busy => pipeline_busy,
    led           => led,
    aperture      => aperture,
    stat_rst      => stat_rst,
    err_rst       => err_rst,
    global_time   => global_time,

    -- Native AXI read master
    ar_id    => ar_id,
    ar_addr  => ar_addr,
    ar_len   => ar_len,
    ar_size  => ar_size,
    ar_valid => ar_valid,
    ar_ready => ar_ready,
    r_id     => r_id,
    r_data   => r_data,
    r_resp   => r_resp,
    r_last   => r_last,
    r_valid  => r_valid,
    r_ready  => r_ready
  );
```

### SystemVerilog

```systemverilog
// ---------------------------------------------------------------------
// Signals (grouped by interface)
// ---------------------------------------------------------------------
localparam int unsigned C_NUM_CLIENTS = 4;  // must match GC_NUM_CLIENTS

// Clock / reset
logic aclk;
logic mem_aclk;
logic aresetn;  // synchronous, active low

// AXI4-Lite slave per client (packed arrays, client index outer)
logic [C_NUM_CLIENTS-1:0][15:0] s_axi_awaddr;
logic [C_NUM_CLIENTS-1:0][2:0]  s_axi_awprot;
logic [C_NUM_CLIENTS-1:0]       s_axi_awvalid;
logic [C_NUM_CLIENTS-1:0]       s_axi_awready;
logic [C_NUM_CLIENTS-1:0][31:0] s_axi_wdata;
logic [C_NUM_CLIENTS-1:0][3:0]  s_axi_wstrb;
logic [C_NUM_CLIENTS-1:0]       s_axi_wvalid;
logic [C_NUM_CLIENTS-1:0]       s_axi_wready;
logic [C_NUM_CLIENTS-1:0][1:0]  s_axi_bresp;
logic [C_NUM_CLIENTS-1:0]       s_axi_bvalid;
logic [C_NUM_CLIENTS-1:0]       s_axi_bready;
logic [C_NUM_CLIENTS-1:0][15:0] s_axi_araddr;
logic [C_NUM_CLIENTS-1:0][2:0]  s_axi_arprot;
logic [C_NUM_CLIENTS-1:0]       s_axi_arvalid;
logic [C_NUM_CLIENTS-1:0]       s_axi_arready;
logic [C_NUM_CLIENTS-1:0][31:0] s_axi_rdata;
logic [C_NUM_CLIENTS-1:0][1:0]  s_axi_rresp;
logic [C_NUM_CLIENTS-1:0]       s_axi_rvalid;
logic [C_NUM_CLIENTS-1:0]       s_axi_rready;

// Per-client status / external control
logic [C_NUM_CLIENTS-1:0] pipeline_busy;
logic [C_NUM_CLIENTS-1:0] led;
logic [C_NUM_CLIENTS-1:0] aperture;
logic [C_NUM_CLIENTS-1:0] stat_rst;
logic [C_NUM_CLIENTS-1:0] err_rst;
logic [47:0]              global_time;  // GC_MON_TIME_WIDTH

// Native AXI read master
logic [3:0]   ar_id;
logic [31:0]  ar_addr;
logic [7:0]   ar_len;
logic [2:0]   ar_size;
logic         ar_valid;
logic         ar_ready;
logic [3:0]   r_id;
logic [127:0] r_data;
logic [1:0]   r_resp;
logic         r_last;
logic         r_valid;
logic         r_ready;

// ---------------------------------------------------------------------
// Instantiation (grouped port map)
// ---------------------------------------------------------------------
axi_read_tester #(
    .GC_NUM_CLIENTS        (4),
    .GC_ADDR_WIDTH         (32),
    .GC_ID_WIDTH           (4),
    .GC_CLIENT_DATA_BYTES  (64),
    .GC_NATIVE_DATA_BYTES  (16),
    .GC_NATIVE_ARLEN_WIDTH (8),
    .GC_MAX_BURST          (32),
    .GC_CLIENT_FIFO_DEPTH  (32),
    .GC_CDC_DEPTH          (8),
    .GC_SYNC_STAGES        (2),
    .GC_MON_SB_DEPTH       (256),
    .GC_MON_TIME_WIDTH     (48)
) u_tester (
    // Clock / reset
    .aclk     (aclk),
    .mem_aclk (mem_aclk),
    .aresetn  (aresetn),

    // AXI4-Lite slave per client
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awprot  (s_axi_awprot),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arprot  (s_axi_arprot),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),

    // Per-client status / external control
    .pipeline_busy (pipeline_busy),
    .led           (led),
    .aperture      (aperture),
    .stat_rst      (stat_rst),
    .err_rst       (err_rst),
    .global_time   (global_time),

    // Native AXI read master
    .ar_id    (ar_id),
    .ar_addr  (ar_addr),
    .ar_len   (ar_len),
    .ar_size  (ar_size),
    .ar_valid (ar_valid),
    .ar_ready (ar_ready),
    .r_id     (r_id),
    .r_data   (r_data),
    .r_resp   (r_resp),
    .r_last   (r_last),
    .r_valid  (r_valid),
    .r_ready  (r_ready)
);
```

## Dependencies

Resolved by `scripts/vhdl.f` (inline closure, per repo convention):
`axi_read_bridge` (+ `axi_ar_mux`, `axi_r_demux`, `axis_cdc`,
`axis_upsizer`, `axis_fifo`, `jitter_gen`, `axis_latency_gen`),
`axi_monitor` (`req`/`rsp`/core), `axi_req_gen` (+ `xorshift32/128`),
`axilite_io`, `common/util_pkg`. `axi_mem_model` is only needed by the
testbench.

## Running

```text
run axi_read_tester vhdl modelsim   # ModelSim simulation
run axi_read_tester vhdl xsim       # XSim simulation
run axi_read_tester vhdl vivado     # Vivado synthesis + timing check
```

`constraints/axi_read_tester.xdc` applies a 100 MHz clock to the client
domain (`aclk`) and a 250 MHz clock to the memory domain (`mem_aclk`) for
the standalone flow (integration designs supply their own clocks).

## Status

- RTL core and wrappers: **new** (interfaces wired; all monitor statistics
  mapped to `i_data`).
- Testbench: skeleton smoke test (client 0 config -> native AR -> R
  response). Expand with per-client scenarios, error injection, stat
  checks, and `data_check_en` verification.
