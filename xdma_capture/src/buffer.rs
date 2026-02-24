use std::alloc::{alloc, dealloc, Layout};
use std::ptr::NonNull;
use std::slice;
use thiserror::Error;

#[derive(Error, Debug)]
#[error("failed to allocate aligned buffer: size={size}, align=4096")]
pub struct AllocError {
    pub size: usize,
}

// Page-aligned (4096 bytes) buffer for DMA read operations.
pub struct DmaBuffer {
    ptr: NonNull<u8>,
    len: usize,
    layout: Layout,
}

impl DmaBuffer {
    // Allocate len bytes aligned to 4096 bytes
    const ALIGN: usize = 4096;

    // Allocate a page-aligned buffer of exactly len bytes.
    pub fn new(len: usize) -> Result<Self, AllocError> {
        // check if len is 0
        if len == 0 {
            return Err(AllocError { size: 0 });
        }
        // allocate the buffer
        let layout = Layout::from_size_align(len, Self::ALIGN).map_err(|_| AllocError { size: len })?;
        let ptr = unsafe { alloc(layout) };
        let ptr = NonNull::new(ptr).ok_or(AllocError { size: len })?;
        // return the buffer
        Ok(Self { ptr, len, layout })
    }

    // Length in bytes.
    #[inline]
    pub fn len(&self) -> usize {
        self.len
    }

    // Mutable slice of the buffer (for pread to fill).
    #[inline]
    pub fn as_mut_slice(&mut self) -> &mut [u8] {
        unsafe { slice::from_raw_parts_mut(self.ptr.as_ptr(), self.len) }
    }

    // Immutable slice (for verification / writing to file).
    #[inline]
    pub fn as_slice(&self) -> &[u8] {
        unsafe { slice::from_raw_parts(self.ptr.as_ptr(), self.len) }
    }
}

impl Drop for DmaBuffer {
    fn drop(&mut self) {
        unsafe {
            dealloc(self.ptr.as_ptr(), self.layout);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dma_buffer_alignment() {
        let mut b = DmaBuffer::new(4096).unwrap();
        let p = b.as_mut_slice().as_ptr() as usize;
        assert_eq!(p % 4096, 0, "buffer must be 4096-byte aligned");
    }

    #[test]
    fn dma_buffer_len() {
        let b = DmaBuffer::new(8192).unwrap();
        assert_eq!(b.len(), 8192);
    }

    #[test]
    fn dma_buffer_zero_len_rejected() {
        assert!(DmaBuffer::new(0).is_err());
    }
}
