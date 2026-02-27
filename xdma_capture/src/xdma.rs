use nix::errno::Errno;
use nix::fcntl::OFlag;
use nix::sys::stat::Mode;
use nix::sys::uio::{pread, pwrite};
use std::os::fd::{AsFd, FromRawFd, OwnedFd};
use std::os::unix::io::BorrowedFd;
use std::path::PathBuf;
use thiserror::Error;

use crate::buffer::DmaBuffer;

// Build device paths
// ------------------------------------------------------------
// H2C device node path: /dev/{xid}_h2c_{chan}
pub fn h2c_node_path(xid: &str, chan: u32) -> PathBuf {
    PathBuf::from(format!("/dev/{}_h2c_{}", xid, chan))
}

// C2H device node path: /dev/{xid}_c2h_{chan}
pub fn c2h_node_path(xid: &str, chan: u32) -> PathBuf {
    PathBuf::from(format!("/dev/{}_c2h_{}", xid, chan))
}

#[derive(Error, Debug)]
pub enum XdmaError {
    #[error("open failed: {path}: {source}")]
    Open { path: PathBuf, source: nix::Error },

    #[error("pwrite short or failed: wrote {wrote} of {len} at offset {offset}: {source}")]
    PwriteShort {
        path: PathBuf,
        offset: u64,
        len: usize,
        wrote: usize,
        source: nix::Error,
    },

    #[error("pread short or failed: read {read} of {len} at offset {offset}: {source}")]
    PreadShort {
        path: PathBuf,
        offset: u64,
        len: usize,
        read: usize,
        source: nix::Error,
    },
}

// Open device nodes
// ------------------------------------------------------------
// Open H2C node write-only
pub fn open_h2c(xid: &str, chan: u32) -> Result<OwnedFd, XdmaError> {
    let path = h2c_node_path(xid, chan);
    let fd = nix::fcntl::open(path.as_path(), OFlag::O_WRONLY, Mode::empty())
        .map_err(|e| XdmaError::Open {
            path: path.clone(),
            source: e,
        })?;
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// Open C2H node read-only.
pub fn open_c2h(xid: &str, chan: u32) -> Result<OwnedFd, XdmaError> {
    let path = c2h_node_path(xid, chan);
    let fd = nix::fcntl::open(path.as_path(), OFlag::O_RDONLY, Mode::empty())
        .map_err(|e| XdmaError::Open {
            path: path.clone(),
            source: e,
        })?;
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

// Call read or write operations in a loop
// ------------------------------------------------------------
// Write exactly len bytes from buf to fd at offset addr
pub fn pwrite_loop(
    fd: BorrowedFd<'_>,
    buf: &[u8],
    addr: u64,
    path: &PathBuf,
) -> Result<(), XdmaError> {
    let len = buf.len();
    let mut off = addr;
    let mut written_total = 0usize;
    while written_total < len {
        let slice = &buf[written_total..];
        loop {
            match pwrite(fd.as_fd(), slice, off as i64) {
                Ok(0) => {
                    return Err(XdmaError::PwriteShort {
                        path: path.clone(),
                        offset: off,
                        len,
                        wrote: written_total,
                        source: Errno::EIO,
                    });
                }
                Ok(n) => {
                    written_total += n;
                    off += n as u64;
                    break;
                }
                Err(Errno::EINTR) => continue,
                Err(e) => {
                    return Err(XdmaError::PwriteShort {
                        path: path.clone(),
                        offset: off,
                        len,
                        wrote: written_total,
                        source: e,
                    });
                }
            }
        }
    }
    Ok(())
}

// Read exactly len bytes into the buffer at offset addr
pub fn pread_loop(
    fd: BorrowedFd<'_>,
    buf: &mut [u8],
    addr: u64,
    path: &PathBuf,
) -> Result<(), XdmaError> {
    let len = buf.len();
    let mut off = addr;
    let mut read_total = 0usize;
    while read_total < len {
        let slice = &mut buf[read_total..];
        loop {
            match pread(fd.as_fd(), slice, off as i64) {
                Ok(0) => { // failed to read any bytes
                    return Err(XdmaError::PreadShort {
                        path: path.clone(),
                        offset: off,
                        len,
                        read: read_total,
                        source: Errno::EIO,
                    });
                }
                Ok(n) => { // read some bytes
                    read_total += n;
                    off += n as u64;
                    break;
                }
                Err(Errno::EINTR) => continue, // retry on EINTR
                Err(e) => {
                    return Err(XdmaError::PreadShort {
                        path: path.clone(),
                        offset: off,
                        len,
                        read: read_total,
                        source: e,
                    });
                }
            }
        }
    }
    Ok(())
}

// Takes bytes from host memory and DMA them across the PCIe bus to the FPGA address space starting at addr
// and then issue PCIE reads to FPGA address space starting at addr for len bytes,
// and DMA the result back into host buffer
// Returns the filled buffer
pub fn write_then_read(
    xid: &str,
    chan: u32,
    addr: u64,
    payload: &[u8],
) -> Result<DmaBuffer, XdmaError> {
    // Step 2: Write payload into H2C
    let h2c_path = h2c_node_path(xid, chan);

    let h2c_fd = open_h2c(xid, chan)?;
    pwrite_loop(h2c_fd.as_fd(), payload, addr, &h2c_path)?;
    drop(h2c_fd);

    let c2h_path = c2h_node_path(xid, chan);
    // allocate a buffer to read back the data
    let mut dma_buf = DmaBuffer::new(payload.len()).map_err(|_| {
        XdmaError::PreadShort {
            path: c2h_path.clone(),
            offset: addr,
            len: payload.len(),
            read: 0,
            source: Errno::ENOMEM,
        }
    })?;

    // Step 3: Read back the data from C2H
    let c2h_fd = open_c2h(xid, chan)?;
    pread_loop(
        c2h_fd.as_fd(),
        dma_buf.as_mut_slice(),
        addr,
        &c2h_path,
    )?;
    Ok(dma_buf)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::os::fd::FromRawFd;

    #[test]
    fn path_formatting() {
        assert_eq!(
            h2c_node_path("xdma0", 0),
            PathBuf::from("/dev/xdma0_h2c_0")
        );
        assert_eq!(
            c2h_node_path("xdma0", 0),
            PathBuf::from("/dev/xdma0_c2h_0")
        );
        assert_eq!(
            h2c_node_path("xdma1", 3),
            PathBuf::from("/dev/xdma1_h2c_3")
        );
    }

    #[test]
    fn pwrite_pread_loop_tempfile() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        let data: Vec<u8> = (0..256).map(|i| i as u8).collect();
        tmp.write_all(&data).unwrap();
        tmp.as_file_mut().sync_all().unwrap();
        let path = tmp.path().to_path_buf();

        let fd = nix::fcntl::open(path.as_path(), OFlag::O_RDWR, Mode::empty()).unwrap();
        let owned = unsafe { OwnedFd::from_raw_fd(fd) };

        // pwrite at offset 0
        pwrite_loop(owned.as_fd(), &data[..100], 0, &path).unwrap();
        let mut read_buf = vec![0u8; 100];
        pread_loop(owned.as_fd(), &mut read_buf, 0, &path).unwrap();
        assert_eq!(&read_buf[..], &data[..100]);

        // pread at offset 50
        read_buf.resize(50, 0);
        pread_loop(owned.as_fd(), &mut read_buf, 50, &path).unwrap();
        assert_eq!(&read_buf[..], &data[50..100]);
    }
}
