mod buffer;
mod input;
mod verify;
mod xdma;

pub use buffer::{AllocError, DmaBuffer};
pub use input::{read_first_len_bytes, InputError};
pub use verify::{verify, VerifyError};
pub use xdma::{
    c2h_node_path, h2c_node_path, open_c2h, open_h2c, write_then_read,
    XdmaError,
};

use std::path::{Path, PathBuf};
use thiserror::Error;

/// Configuration for the capture operation.
#[derive(Clone, Debug)]
pub struct CaptureConfig {
    pub xid: String,
    pub chan: u32,
    pub len: usize,
    // Input file: first `len` bytes are used as write payload.
    pub input_path: PathBuf,
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
pub fn capture(cfg: &CaptureConfig) -> Result<(), CaptureError> {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_config_has_required_fields() {
        let _ = CaptureConfig {
            xid: "xdma0".into(),
            chan: 0,
            len: 4096,
            input_path: PathBuf::from("data/foo.bin"),
        };
    }
}
