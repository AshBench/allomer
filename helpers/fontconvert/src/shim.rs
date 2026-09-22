//! The pinned HarfBuzz subsetter and Google WOFF2 codec, reached through shim/fontshim.cc.


unsafe extern "C" {
    fn fontshim_free(pointer: *mut u8);
    fn fontshim_normalize(data: *const u8, length: usize, out_length: *mut usize) -> *mut u8;
    fn fontshim_woff2_decode(data: *const u8, length: usize, limit: usize, out_length: *mut usize) -> *mut u8;
    fn fontshim_woff2_encode(data: *const u8, length: usize, out_length: *mut usize) -> *mut u8;
}

/// Copies a buffer the shim allocated and releases it, so no foreign memory outlives this call.
unsafe fn take(pointer: *mut u8, length: usize) -> Option<Vec<u8>> {
    if pointer.is_null() {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(pointer, length) }.to_vec();
    unsafe { fontshim_free(pointer) };
    Some(bytes)
}

/// The font rewritten at its default design location, without variation or signature tables.
pub fn normalize(font: &[u8]) -> Option<Vec<u8>> {
    let mut length = 0;
    unsafe { take(fontshim_normalize(font.as_ptr(), font.len(), &mut length), length) }
}

pub fn woff2_decode(font: &[u8], limit: usize) -> Option<Vec<u8>> {
    let mut length = 0;
    unsafe { take(fontshim_woff2_decode(font.as_ptr(), font.len(), limit, &mut length), length) }
}

pub fn woff2_encode(font: &[u8]) -> Option<Vec<u8>> {
    let mut length = 0;
    unsafe { take(fontshim_woff2_encode(font.as_ptr(), font.len(), &mut length), length) }
}
