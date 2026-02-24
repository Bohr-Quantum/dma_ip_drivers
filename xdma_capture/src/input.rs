use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum InputError {
    #[error("file too small: size {file_size} < required {len}")]
    FileTooSmall { file_size: u64, len: usize },

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

// Step 1: Build payload from input file
pub fn read_first_len_bytes(path: &Path, len: usize) -> Result<Vec<u8>, InputError> {
    let file = File::open(path)?;
    let meta = file.metadata()?;
    let file_size = meta.len();
    // check if file is large enough
    if file_size < len as u64 {
        return Err(InputError::FileTooSmall {
            file_size,
            len,
        });
    }
    // read exactly the first len bytes from the file
    let mut f = file;
    f.seek(SeekFrom::Start(0))?;
    let mut buf = vec![0u8; len];
    f.read_exact(&mut buf).map_err(InputError::Io)?;
    // return the payload exactly len bytes long
    Ok(buf)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn read_first_len_enforces_size() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("small.bin");
        let mut f = File::create(&p).unwrap();
        f.write_all(&[1, 2, 3]).unwrap();
        drop(f);

        let err = read_first_len_bytes(&p, 10).unwrap_err();
        match &err {
            InputError::FileTooSmall { file_size, len } => {
                assert_eq!(*file_size, 3);
                assert_eq!(*len, 10);
            }
            _ => panic!("expected FileTooSmall"),
        }
    }

    #[test]
    fn read_first_len_exact() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("exact.bin");
        let data: Vec<u8> = (0..100).collect();
        std::fs::write(&p, &data).unwrap();

        let out = read_first_len_bytes(&p, 50).unwrap();
        assert_eq!(out.len(), 50);
        assert_eq!(out, &data[..50]);
    }
}
