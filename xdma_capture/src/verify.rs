use std::fmt;
use thiserror::Error;

const HEXDUMP_WINDOW: usize = 32;

#[derive(Error, Debug)]
pub struct VerifyError {
    pub offset_i: usize,
    pub expected_byte: u8,
    pub actual_byte: u8,
    pub total_mismatches: usize,
    pub hexdump_str: String,
}

impl fmt::Display for VerifyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "verify failed at offset {}: expected 0x{:02x}, got 0x{:02x}; total mismatches (capped): {}",
            self.offset_i, self.expected_byte, self.actual_byte, self.total_mismatches
        )?;
        if !self.hexdump_str.is_empty() {
            write!(f, "\n{}", self.hexdump_str)?;
        }
        Ok(())
    }
}

/// Step 4: Compare `expected` and `actual` (same length) to detect that the bytes match
pub fn verify(expected: &[u8], actual: &[u8]) -> Result<(), VerifyError> {
    if expected.len() != actual.len() {
        // confirm lengths match
        return Err(VerifyError {
            offset_i: 0,
            expected_byte: 0,
            actual_byte: 0,
            total_mismatches: 1,
            hexdump_str: format!(
                "length mismatch: expected {} bytes, got {}",
                expected.len(),
                actual.len()
            ),
        });
    }
    let mut offset_i = None;
    let mut total = 0usize;
    // iterate over the butes and find the first mismatch
    for (i, (e, a)) in expected.iter().zip(actual.iter()).enumerate() {
        if *e != *a {
            if offset_i.is_none() {
                offset_i = Some(i); // record the offset of the first mismatch
            }
            total += 1;
            if total >= 1 {
                break;
            }
        }
    }
    let Some(off) = offset_i else {
        return Ok(());
    };
    let expected_byte = expected[off];
    let actual_byte = actual[off];
    let len = expected.len();
    let start = off.saturating_sub(HEXDUMP_WINDOW);
    let end = (off + HEXDUMP_WINDOW + 1).min(len);
    let hexdump_str = hexdump_window(expected, actual, start, end, off);
    Err(VerifyError {
        offset_i: off,
        expected_byte,
        actual_byte,
        total_mismatches: total,
        hexdump_str,
    })
}

// Helper function to create a hexdump string
fn hexdump_window(
    expected: &[u8],
    actual: &[u8],
    start: usize,
    end: usize,
    highlight_offset: usize,
) -> String {
    let mut out = String::from("expected:\n");
    out.push_str(&hexdump_line(expected, start, end, highlight_offset));
    out.push_str("actual:\n");
    out.push_str(&hexdump_line(actual, start, end, highlight_offset));
    out
}

// Helper function to create a hexdump line
fn hexdump_line(buf: &[u8], start: usize, end: usize, highlight: usize) -> String {
    let mut line = format!("  {:08x}  ", start);
    for i in start..end {
        if i == highlight {
            line.push_str(&format!(">>{:02x}<< ", buf[i]));
        } else {
            line.push_str(&format!("{:02x} ", buf[i]));
        }
    }
    line.push('\n');
    line
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verify_match() {
        let a = [1u8, 2, 3, 4];
        let b = [1u8, 2, 3, 4];
        assert!(verify(&a, &b).is_ok());
    }

    #[test]
    fn verify_mismatch_reports_offset_expected_actual() {
        let expected = vec![0u8, 1, 2, 3, 4];
        let actual = vec![0u8, 1, 9, 3, 4]; // mismatch at 2
        let err = verify(&expected, &actual).unwrap_err();
        assert_eq!(err.offset_i, 2);
        assert_eq!(err.expected_byte, 2);
        assert_eq!(err.actual_byte, 9);
        assert_eq!(err.total_mismatches, 1);
        assert!(err.hexdump_str.contains("expected:"));
        assert!(err.hexdump_str.contains("actual:"));
    }

    #[test]
    fn verify_length_mismatch() {
        let a = [1u8, 2];
        let b = [1u8, 2, 3];
        let err = verify(&a, &b).unwrap_err();
        assert_eq!(err.offset_i, 0);
        assert!(err.hexdump_str.contains("length mismatch"));
    }
}
