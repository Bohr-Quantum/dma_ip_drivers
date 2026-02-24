mod buffer;
mod input;
mod verify;
mod xdma;

pub use buffer::{AllocError, DmaBuffer};
pub use input::{read_first_len_bytes, InputError};
pub use verify::{verify, VerifyError};
pub use xdma::{
    c2h_node_path, h2c_node_path, open_c2h, open_h2c, read_c2h_into_buffer, write_then_read,
    XdmaError,
};

use std::num::ParseIntError;
use std::path::{Path, PathBuf};
use thiserror::Error;

// Parse address from hex (0x...) or decimal string.
pub fn parse_addr(s: &str) -> Result<u64, ParseIntError> {
    let s = s.trim();
    if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        u64::from_str_radix(hex, 16)
    } else {
        s.parse::<u64>()
    }
}

// Configuration for the loopback operation.
#[derive(Clone, Debug)]
pub struct LoopbackConfig {
    pub xid: String,
    pub chan: u32,
    pub len: usize,
    // Input file: first `len` bytes are used as write payload.
    pub input_path: PathBuf,
}

// Configuration for the capture (read-only dump) operation.
#[derive(Clone, Debug)]
pub struct CaptureConfig {
    pub xid: String,
    pub chan: u32,
    pub addr: u64,
    pub len: usize,
    pub out_path: PathBuf,
}

#[derive(Error, Debug)]
pub enum CaptureError {
    #[error("input: {0}")]
    Input(#[from] InputError),
    #[error("xdma: {0}")]
    Xdma(#[from] XdmaError),
    #[error("verify: {0}")]
    Verify(#[from] VerifyError),
    #[error("output file: {0}")]
    Output(#[from] std::io::Error),
}

// Step 5: Write the read-back bytes to a file
pub fn loopback(cfg: &LoopbackConfig) -> Result<(), CaptureError> {
    // Read payload from input file
    let payload = read_first_len_bytes(&cfg.input_path, cfg.len)?;

    // Write payload to H2C and read back from C2H.
    // To keep things simple, we always use AXI address 0.
    let read_back = xdma::write_then_read(&cfg.xid, cfg.chan, 0, &payload)?;
    // Verify the read-back bytes
    verify(&payload, read_back.as_slice())?;

    // Derive the output path from the input file:
    // data/<input_stem> -> data/output_<input_stem>.bin
    let input_dir = cfg
        .input_path
        .parent()
        .unwrap_or_else(|| Path::new("."));
    let stem = cfg
        .input_path
        .file_stem()
        .unwrap_or_else(|| cfg.input_path.as_os_str());
    let out_name = format!(
        "output_{}.bin",
        stem.to_string_lossy()
    );
    let out_path = input_dir.join(out_name);

    // If it already exists, remove it first.
    if out_path.exists() {
        std::fs::remove_file(&out_path)?;
    }
    let mut f = std::fs::File::options()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&out_path)?;
    std::io::Write::write_all(&mut f, read_back.as_slice())?;
    f.sync_all()?;
    drop(f);
    let meta = std::fs::metadata(&out_path)?;
    if meta.len() != cfg.len as u64 {
        return Err(CaptureError::Output(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!(
                "output file size {} != expected {}",
                meta.len(),
                cfg.len
            ),
        )));
    }
    Ok(())
}

// Run capture: read len bytes from C2H at addr, write to out_path.
pub fn capture_to_file(cfg: &CaptureConfig) -> Result<(), CaptureError> {
    // Read the data from C2H
    let buf = xdma::read_c2h_into_buffer(&cfg.xid, cfg.chan, cfg.addr, cfg.len)?;
    // Write the data to a file
    let mut f = std::fs::File::options()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&cfg.out_path)?;
    // Write the data to the file
    std::io::Write::write_all(&mut f, buf.as_slice())?;
    f.sync_all()?;
    drop(f);
    let meta = std::fs::metadata(&cfg.out_path)?;
    if meta.len() != cfg.len as u64 {
        return Err(CaptureError::Output(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!(
                "output file size {} != expected {}",
                meta.len(),
                cfg.len
            ),
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_addr_hex() {
        assert_eq!(parse_addr("0x1000"), Ok(4096));
        assert_eq!(parse_addr("0Xdead"), Ok(0xdead));
    }

    #[test]
    fn parse_addr_decimal() {
        assert_eq!(parse_addr("4096"), Ok(4096));
        assert_eq!(parse_addr("0"), Ok(0));
    }
}
