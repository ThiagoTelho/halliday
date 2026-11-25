//! Additive, stateless Sense output C ABI; existing controller/pose ABI is unchanged.
use crate::sense_output::{self, OutputFeedback};

/// # Safety
/// Null or `len` readable input bytes and one writable feedback struct. Output is untouched on failure.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_sense_output_feedback(
    product_id: u16,
    bytes: *const u8,
    len: usize,
    out: *mut OutputFeedback,
) -> bool {
    if bytes.is_null() || out.is_null() || ![64, 78].contains(&len) {
        return false;
    }
    let Some(value) = sense_output::feedback(product_id, unsafe {
        std::slice::from_raw_parts(bytes, len)
    }) else {
        return false;
    };
    unsafe {
        out.write(value);
    }
    true
}
