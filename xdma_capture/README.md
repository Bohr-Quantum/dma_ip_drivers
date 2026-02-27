# xdma_capture

POC that proves XDMA can write into FPGA memory (H2C) and read it back (C2H).

## Operation

- **capture** — Write payload to FPGA at AXI address 0 (H2C), read back (C2H), verify byte-for-byte, and write read-back to `output_<input-stem>.bin` next to the input file.

## Requirements

- Load driver; device nodes `/dev/{xid}_h2c_{chan}` and `/dev/{xid}_c2h_{chan}`

## Build & run

```bash
cargo build --release
```

## Usage

Capture using the first 4096 bytes of a file as payload. The read-back bytes are written next to the input file as `output_<input-stem>.bin` (e.g. `data1.bin` -> `output_data1.bin`):

```bash
cargo run -- capture --xid xdma0 --chan 0 --len 4096 --in data1.bin
```

## Args

- **xid** — XDMA device id (e.g. `xdma0`).
- **chan** — Channel index (same for H2C and C2H).
- **len** — Transfer size in bytes.
- **--in** — Input file; first `len` bytes are used as payload. Read-back is written to `output_<input-stem>.bin` in the same directory.

## Tests

```bash
cargo test
```
