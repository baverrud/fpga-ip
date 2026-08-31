# AES AXI4-Stream Encryption Core

Configurable AES encryption IP supporting 128-bit, 192-bit, and 256-bit keys.
The external data path is always 128 bits, as required by AES. Separate
AXI4-Stream interfaces load the key and carry plaintext/ciphertext blocks.

The implementation follows NIST FIPS 197-upd1:

- [NIST FIPS 197: Advanced Encryption Standard](https://csrc.nist.gov/pubs/fips/197/final)
- AES-128: 128-bit key, 10 rounds
- AES-192: 192-bit key, 12 rounds
- AES-256: 256-bit key, 14 rounds

The core provides two implementation families:

- An iterative round engine for minimum round-logic area.
- A spatially unrolled elastic pipeline with configurable register placement.

Only encryption is exposed by the streaming RTL entity. The package also
contains inverse transformations and a combinational inverse cipher for unit
testing and future decryption-core development.

## Status

The package transformations and streaming core are self-tested against NIST
known-answer vectors for AES-128, AES-192, and AES-256. The testbench includes
iterative, partially pipelined, fully pipelined, output-backpressure, multiple
block, and `tlast` propagation checks.

Synthesis resource and timing results are not yet published. Claims about a
specific balanced implementation point must therefore be confirmed on the
target FPGA, speed grade, tool version, and clock constraint.

## Top-Level Entity

The synthesizable entity is `aes` in `rtl/aes.vhd`.

### Generics

| Generic | Type | Default | Meaning |
| --- | --- | ---: | --- |
| `GC_KEY_BITS` | `positive range 128 to 256` | 128 | Fixed key width. Legal values are 128, 192, and 256. |
| `GC_PIPELINE_STAGES` | `natural range 0 to 14` | 0 | Selects the iterative engine (`0`) or the number of elastic pipeline registers (`1..Nr`). |

`Nr` is selected from the key width:

| `GC_KEY_BITS` | Key words (`Nk`) | AES rounds (`Nr`) | Legal pipeline values |
| ---: | ---: | ---: | --- |
| 128 | 4 | 10 | 0 through 10 |
| 192 | 6 | 12 | 0 through 12 |
| 256 | 8 | 14 | 0 through 14 |

Elaboration assertions reject unsupported key widths and positive pipeline
stage counts greater than `Nr`.

### Ports

| Port | Direction | Width | Description |
| --- | --- | ---: | --- |
| `aclk` | in | 1 | Clock for all interfaces and state. |
| `aresetn` | in | 1 | Synchronous active-low reset. |
| `s_axis_key_tdata` | in | `GC_KEY_BITS` | Complete AES key in one transfer. |
| `s_axis_key_tlast` | in | 1 | Present for AXI4-Stream compatibility; ignored because a key is one beat. |
| `s_axis_key_tvalid` | in | 1 | Key transfer valid. |
| `s_axis_key_tready` | out | 1 | Key transfer ready. |
| `s_axis_tdata` | in | 128 | Plaintext block. |
| `s_axis_tlast` | in | 1 | Packet marker propagated with the block. |
| `s_axis_tvalid` | in | 1 | Plaintext transfer valid. |
| `s_axis_tready` | out | 1 | Plaintext transfer ready. |
| `m_axis_tdata` | out | 128 | Ciphertext block. |
| `m_axis_tlast` | out | 1 | `tlast` associated with the ciphertext block. |
| `m_axis_tvalid` | out | 1 | Ciphertext transfer valid. |
| `m_axis_tready` | in | 1 | Ciphertext consumer ready. |

All transfers use the standard AXI4-Stream handshake: a transfer occurs only
on a rising edge where both `tvalid` and `tready` are high. Producers must hold
payload and `tlast` stable while valid is high and ready is low.

## Key Loading and Re-Keying

The key interface accepts the complete key in one beat. On acceptance, the RTL
expands and stores the full key schedule:

- AES-128 uses 44 schedule words.
- AES-192 uses 52 schedule words.
- AES-256 uses 60 schedule words.

The schedule remains valid until reset or a replacement key is accepted.
Multiple data blocks may therefore reuse one loaded key without reloading it.

Re-keying is deliberately conservative:

- The iterative engine accepts a key only when it is not processing a block
	and no output block is being held.
- The pipelined engine accepts a key only when every pipeline stage is empty.
- If key valid and data valid are asserted together while idle, the key
	transfer has priority; data ready is held low so the block cannot use the
	previous schedule accidentally.

The full key expansion is combinational on the key input-to-schedule-register
path. This is simple and allows immediate reuse of the cached schedule, but it
may become a timing-limiting path at aggressive clock targets. A multi-cycle or
iterative key expander is a possible future area/timing optimization.

## Architecture

### Common Data Representation

AES state is represented as `state(row, column)` with four rows and four
columns of bytes. External blocks are serialized in FIPS 197 column-major
order:

```text
block[127:120] -> state(0,0)
block[119:112] -> state(1,0)
block[111:104] -> state(2,0)
block[103:96]  -> state(3,0)
...
block[7:0]     -> state(3,3)
```

Both architectures perform the same sequence:

```text
input block
	-> AddRoundKey(0)
	-> rounds 1 .. Nr-1:
			 SubBytes -> ShiftRows -> MixColumns -> AddRoundKey(round)
	-> final round Nr:
			 SubBytes -> ShiftRows -> AddRoundKey(Nr)
	-> output block
```

The final round omits `MixColumns`, as required by FIPS 197.

### Iterative Engine (`GC_PIPELINE_STAGES = 0`)

The iterative implementation contains one AES round datapath and reuses it for
all rounds. Its state consists primarily of one 128-bit AES state register, a
round counter, the cached expanded key schedule, and one registered output
block with valid and `tlast`.

The initial `AddRoundKey` occurs when the plaintext transfer is accepted. One
round is then executed per clock. The ciphertext becomes valid after `Nr`
additional active clock edges. With the output consumer ready, the initiation
interval is `Nr + 1` clocks:

| Key | Rounds | Approximate input initiation interval |
| --- | ---: | ---: |
| AES-128 | 10 | 11 clocks per block |
| AES-192 | 12 | 13 clocks per block |
| AES-256 | 14 | 15 clocks per block |

If the output is stalled, ciphertext, valid, and `tlast` remain registered
until accepted. No new key or data block is accepted while the output is held.

This mode is the appropriate choice when minimizing duplicated AES round logic
is more important than block throughput.

### Unrolled Elastic Pipeline (`GC_PIPELINE_STAGES > 0`)

Every AES round is spatially instantiated in the positive-stage architecture.
`GC_PIPELINE_STAGES` controls where elastic registers divide that unrolled
round chain. The rounds assigned to stage `s` are:

```text
first_round(s) = floor(s * Nr / stages) + 1
last_round(s)  = floor((s + 1) * Nr / stages)
```

This partitions the rounds as evenly as integer division permits. AES-128
examples:

| Stages | Rounds per stage | Pipeline latency | Steady-state throughput |
| ---: | --- | ---: | --- |
| 1 | 10 | 1 clock | 1 block/clock |
| 2 | 5, 5 | 2 clocks | 1 block/clock |
| 3 | 3, 3, 4 | 3 clocks | 1 block/clock |
| 4 | 2, 3, 2, 3 | 4 clocks | 1 block/clock |
| 5 | 2, 2, 2, 2, 2 | 5 clocks | 1 block/clock |
| 10 | 1 round per stage | 10 clocks | 1 block/clock |

Each stage stores state, valid, and `tlast`. Ready propagates backward through
the elastic chain. A stage advances when it is empty or when every downstream
stage through the output can advance. Consequently:

- The pipeline accepts one block per clock when not backpressured.
- A downstream stall propagates to `s_axis_tready` without losing data.
- All stage payloads and packet markers remain stable while stalled.
- Pipeline latency is the configured number of stages when no stall occurs.

## Performance and Resource Tradeoffs

The generic supports useful tradeoffs, but it is important to distinguish two
different meanings of "balanced."

### Logic area versus block throughput

There are two main points:

- `GC_PIPELINE_STAGES=0`: one reused round datapath, lowest expected round-logic
	area, and one block every `Nr+1` clocks.
- `GC_PIPELINE_STAGES>0`: all `Nr` round datapaths are unrolled, and the core
	can sustain one block per clock.

Changing a positive stage count does not fold away AES rounds. Therefore a
configuration such as 2 stages should not be expected to use one fifth of the
round logic of a 10-stage AES-128 core. The positive-stage choices primarily
change register count, combinational depth per stage, routability, latency, and
achievable clock frequency.

### Timing versus pipeline-register overhead

Within the unrolled family, intermediate values provide a genuine balance:

- Fewer stages use fewer state/valid/last registers and have lower latency,
	but place more AES rounds in each combinational stage.
- More stages shorten the round logic between registers and generally improve
	achievable frequency, at the cost of more registers, clock-tree load, and
	latency.
- Stage counts that divide `Nr` evenly give uniform combinational depth. For
	example, 2 or 5 stages are natural AES-128 candidates; 2, 3, 4, or 6 stages
	are natural AES-192 candidates; and 2 or 7 stages are natural AES-256
	candidates.

Thus the current IP can target a balanced timing/register requirement, but it
does not yet provide a partially folded multi-round engine for fine-grained
LUT-versus-throughput balancing. Such an engine would execute `K` rounds per
cycle and accept a new block every `ceil(Nr/K)` clocks.

### Recommended selection process

1. Choose iterative mode if one block every 11/13/15 clocks is sufficient and
	 area is the primary constraint.
2. Choose a positive stage count if one-block-per-clock throughput is required.
3. Start with a divisor of `Nr` that gives the desired rounds per stage.
4. Synthesize each candidate with the target clock and device.
5. Compare LUTs, flip-flops, Fmax/slack, dynamic power, and latency before
	 selecting the production value.

Do not choose an intermediate stage count from simulation alone. Simulation
proves functional behavior and backpressure handling, not implementation
frequency or resource use.

## Package Contents

`rtl/aes_pkg.vhd` contains reusable AES types and pure functions:

| Category | Functions |
| --- | --- |
| Parameter helpers | `aes_key_words`, `aes_rounds` |
| State conversion | `aes_block_to_state`, `aes_state_to_block` |
| Substitution | `aes_sbox`, `aes_inv_sbox`, `aes_sub_bytes`, `aes_inv_sub_bytes` |
| Row transform | `aes_shift_rows`, `aes_inv_shift_rows` |
| Column transform | `aes_mix_columns`, `aes_inv_mix_columns` |
| Field arithmetic | `aes_xtime`, `aes_gf_mul` |
| Round key | `aes_add_round_key` |
| Key expansion | `aes_rot_word`, `aes_sub_word`, `aes_rcon`, `aes_expand_key` |
| Reference cipher | `aes_cipher`, `aes_inv_cipher` |

The S-boxes are encoded as hexadecimal strings and converted to bytes by a
small helper. This keeps the tables compact and easy to compare against the
standard. Synthesis mapping of these lookups is tool- and target-dependent;
inspect the implementation report to determine whether they map to LUT logic,
distributed ROM, or another structure.

## AXI4-Stream Integration

### Basic transaction sequence

1. Assert `s_axis_key_tvalid` with the complete key.
2. Hold the key stable until `s_axis_key_tready` is high on a rising edge.
3. Assert `s_axis_tvalid` with a 128-bit plaintext block.
4. Hold plaintext and `s_axis_tlast` stable until accepted.
5. Accept ciphertext when `m_axis_tvalid` and `m_axis_tready` are both high.

Example connection pattern:

```vhdl
u_aes : entity work.aes
	generic map (
		GC_KEY_BITS        => 128,
		GC_PIPELINE_STAGES => 5
	)
	port map (
		aclk              => aclk,
		aresetn           => aresetn,
		s_axis_key_tdata  => key_tdata,
		s_axis_key_tlast  => key_tlast,
		s_axis_key_tvalid => key_tvalid,
		s_axis_key_tready => key_tready,
		s_axis_tdata      => plaintext_tdata,
		s_axis_tlast      => plaintext_tlast,
		s_axis_tvalid     => plaintext_tvalid,
		s_axis_tready     => plaintext_tready,
		m_axis_tdata      => ciphertext_tdata,
		m_axis_tlast      => ciphertext_tlast,
		m_axis_tvalid     => ciphertext_tvalid,
		m_axis_tready     => ciphertext_tready
	);
```

### Packet boundaries

AES operates independently on each 128-bit block. `tlast` does not alter the
cipher operation; it is metadata transported through the same elastic path as
the corresponding block. The integrator defines packet meaning and padding.
No padding mode, chaining mode, nonce handling, or authentication is included.

### Reset behavior

`aresetn` is synchronous and active low. Reset clears the cached key and
key-valid flag, iterative busy/round/output state, and pipeline valid/`tlast`
state. After reset, data ready remains low until a key has been accepted.

## Verification

### Package testbench

`tb/aes_pkg_tb.vhd` checks:

- `Nk` and `Nr` selection for all key widths.
- Block-to-state serialization round trip.
- All 256 forward/inverse S-box pairs.
- Published S-box, `xtime`, and GF multiplication examples.
- SubBytes, ShiftRows, MixColumns, and inverse transformations.
- RotWord, SubWord, and Rcon.
- AES-128 key schedule words and round-one intermediate state.
- AES-128, AES-192, and AES-256 encryption/decryption vectors.
- Ascending-range key input normalization.

### Streaming core testbench

`tb/aes_tb.vhd` currently instantiates:

| Instance | Key width | Pipeline stages | Purpose |
| --- | ---: | ---: | --- |
| AES-128 iterative | 128 | 0 | Iterative latency, output hold, known-answer vector, `tlast` |
| AES-192 partial pipeline | 192 | 2 | Multi-round stages and output backpressure |
| AES-256 full pipeline | 256 | 14 | Full-rate consecutive blocks and `tlast` ordering |

The expected ciphertexts are the FIPS 197 known-answer values for plaintext
`00112233445566778899aabbccddeeff` and incrementing-byte keys.

### Suggested additional verification

Before production use, add or automate:

- A sweep of every legal `GC_PIPELINE_STAGES` value for every key width.
- Long randomized ready/valid backpressure sequences.
- Re-key attempts while iterative and pipeline datapaths are occupied.
- Simultaneous key-valid and data-valid arbitration checks.
- Reset during iterative processing, pipeline fill, and output stall.
- Random vectors compared with an independent validated software model.
- Formal AXI4-Stream payload-stability and no-loss/no-duplication properties.

## Running the Tests

From the `sub/fpga-ip` repository root:

```batch
run aes vhdl modelsim
run aes vhdl modelsim --tb pkg
run aes vhdl modelsim --tb simple
```

The manifest is `scripts/vhdl.f` and defaults to VHDL-2008. Generated files and
simulator artifacts are placed under `aes/.runs/`.

## Files

| File | Purpose |
| --- | --- |
| `rtl/aes_pkg.vhd` | AES state types, transformations, key expansion, and reference cipher functions. |
| `rtl/aes.vhd` | Configurable AXI4-Stream encryption core. |
| `tb/aes_pkg_tb.vhd` | Package-level NIST and transformation tests. |
| `tb/aes_tb.vhd` | Streaming iterative/pipeline/backpressure testbench. |
| `tb/aes_simple_tb.vhd` | Small hand-editable smoke testbench. |
| `scripts/vhdl.f` | VHDL-2008 manifest for simulation and synthesis flows. |

## Synthesis Notes

- AES S-box implementation style strongly affects LUT count and Fmax.
- Positive pipeline configurations broadcast the cached round-key schedule to
	every assigned round. Placement and fanout may affect timing.
- More stages add 128-bit state registers plus valid/last control registers.
- The ready chain is combinational from the output toward the input; a long
	pipeline can make ready propagation a timing path even when round logic is
	well partitioned.
- Key expansion is a separate combinational path into the schedule registers.
- Run synthesis and implementation, not only behavioral estimates, before
	accepting a performance/resource point.

Potential future optimizations include a folded `K`-round engine, registered
or hierarchical ready propagation, iterative key expansion, device-specific
S-box implementations, and separate decryption RTL.

## Limitations and Security Notes

- Electronic codebook behavior is provided at the block level only. Modes such
	as CBC, CTR, GCM, XTS, and key/nonce management are outside this IP.
- The design does not provide authentication, padding, replay protection, or
	protocol framing beyond `tlast` propagation.
- The implementation is not documented as resistant to timing, power,
	electromagnetic, fault-injection, or other side-channel attacks.
- Reset clears logical key state, but physical data-remanence requirements
	depend on the target technology and implementation flow.
- Cryptographic deployment requires system-level review beyond known-answer
	simulation tests.

## License

Zero-Clause BSD (0BSD). See the source-file headers for the applicable notice.
