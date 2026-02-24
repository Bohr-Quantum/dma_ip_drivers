# xdma_capture

POC that proves XDMA can write into FPGA memory (H2C) and read it back (C2H).

## Operations

- **loopback** — Write payload to FPGA at an AXI address (H2C), read back (C2H), verify byte-for-byte.
- **capture** — Read-only: read `len` bytes from C2H at `addr` and write to a file.

## Requirements

- Load driver; device nodes `/dev/{xid}_h2c_{chan}` and `/dev/{xid}_c2h_{chan}`

## Build & run

```bash
cargo build --release
```

## Usage

Loopback using the first 4096 bytes of a file as payload (always using AXI-MM address 0). The read-back bytes are written next to the input file, as `output_<input-stem>.bin` (e.g. `data1.bin` -> `output_data1.bin`):

```bash
cargo run -- loopback --xid xdma0 --chan 0 --len 4096 --in data1.bin
```

Capture 32 bytes from C2H at address 0 into `out.bin`:

```bash
cargo run -- capture --xid xdma0 --chan 0 --addr 0x0 --len 32 --out out.bin
```

## Args

- **xid** — XDMA device id (e.g. `xdma0`).
- **chan** — Channel index (same for H2C and C2H).
- **addr** — AXI endpoint address offset in bytes (used by `capture`), hex (`0x...`) or decimal.
- **len** — Transfer size in bytes.
- **loopback**: **--in** (input file, first `len` bytes used as payload). Loopback always uses AXI address 0 internally. The read-back data is written next to the input file as `output_<input-stem>.bin`.
- **capture**: **--out** required (output file path).

## Tests

```bash
cargo test
```
