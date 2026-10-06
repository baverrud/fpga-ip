# axi_read_bridge_no_cdc

Single-clock, multi-client AXI read bridge with a direct 512-bit native R
input. Unlike `axi_read_bridge`, this IP contains no clock-domain converters
and no width upsizer. The client side and native AXI side share `aclk`; every
native R beat is one 512-bit client response beat.

## Interface

`req_len` and `ar_len` both count 512-bit beats minus one. The bridge assigns
the client index to `ar_id` and uses the returned `r_id` to route each 512-bit
R beat to its client. `r_resp` and `r_last` are passed through unchanged.
Each client has an elastic response FIFO and a credit limit, so the AR mux
does not accept more outstanding beats than the configured response depth.

Addresses must be aligned to 64 bytes, and each AXI burst must stay within a
4 KiB page. Simulation assertions check both conditions when a request is
accepted. Reset is synchronous and active low, matching `axi_ar_mux` and
`axi_r_demux`.

## Generics

| Generic | Default | Description |
|---|---:|---|
| `GC_NUM_CLIENTS` | 4 | Client request/response ports. |
| `GC_ADDR_WIDTH` | 32 | Byte address width. |
| `GC_ID_WIDTH` | 4 | Native AXI ID width; IDs encode the client index. |
| `GC_CLIENT_FIFO_DEPTH` | 32 | Per-client response FIFO and beat-credit depth. |

## Composition

The RTL contains `axi_ar_mux` and `axi_r_demux` only. The native AR channel
is driven directly from the mux. The native R channel, including its full
512-bit `r_data`, is connected directly to the demultiplexer.

The wrapper exposes `ar_size = 6`, the AXI size for 64-byte beats. Tie the
remaining AXI sidebands at the integration boundary as required by the
downstream interface.

## Testbenches

| Bench | Command | Purpose |
|---|---|---|
| `default` | `run axi_read_bridge_no_cdc vhdl modelsim` | `axi_mem_model` in 64-byte mode; concurrent multi-client requests, AR routing, 512-bit data, and response FIFO back-pressure. |
| `simple` | `run axi_read_bridge_no_cdc vhdl modelsim --tb simple` | `axi_mem_model` in 64-byte mode; four one-beat clients. |

## Instantiation

Use `top/axi_read_bridge_no_cdc_top.vhd` or
`top/axi_read_bridge_no_cdc_top.sv`. Compilable templates are in the same
directory.