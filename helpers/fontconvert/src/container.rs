//! WOFF, WOFF2, and plain sfnt packaging. WOFF is decoded here; WOFF2 uses the pinned codec.

use crate::shim;
use crate::{Result, EXPANDED_LIMIT};
use miniz_oxide::deflate::compress_to_vec_zlib;
use miniz_oxide::inflate::decompress_to_vec_zlib_with_limit;
use write_fonts::types::Tag;
use write_fonts::FontBuilder;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Container {
    Sfnt,
    Woff,
    Woff2,
}

const WOFF_HEADER: usize = 44;
const WOFF_ENTRY: usize = 20;

fn be32(bytes: &[u8], at: usize) -> u32 {
    u32::from_be_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

fn be16(bytes: &[u8], at: usize) -> u16 {
    u16::from_be_bytes([bytes[at], bytes[at + 1]])
}

pub fn detect(font: &[u8]) -> Result<Container> {
    if font.len() < 12 {
        return Err("The font file is too short to identify.".into());
    }
    match be32(font, 0) {
        0x0001_0000 | 0x7472_7565 | 0x4f54_544f => Ok(Container::Sfnt),
        0x774f_4646 => Ok(Container::Woff),
        0x774f_4632 => Ok(Container::Woff2),
        _ => Err("The file is not a supported font.".into()),
    }
}

/// The sfnt bytes carried by the file, expanding web fonts within the declared limit.
pub fn decode(font: &[u8]) -> Result<Vec<u8>> {
    match detect(font)? {
        Container::Sfnt => Ok(font.to_vec()),
        Container::Woff2 => shim::woff2_decode(font, EXPANDED_LIMIT)
            .ok_or_else(|| "The WOFF2 font could not be expanded within its size limit.".into()),
        Container::Woff => decode_woff(font),
    }
}

fn decode_woff(font: &[u8]) -> Result<Vec<u8>> {
    let invalid = || -> Box<dyn std::error::Error> { "The WOFF font header is invalid.".into() };
    if font.len() < WOFF_HEADER || be32(font, 8) as usize != font.len() {
        return Err(invalid());
    }
    let count = be16(font, 12) as usize;
    let expanded = be32(font, 16) as usize;
    if count == 0 || count > 4096 || expanded > EXPANDED_LIMIT {
        return Err("The WOFF font declares an unusable table count or expanded size.".into());
    }
    let directory = WOFF_HEADER + count * WOFF_ENTRY;
    if directory > font.len() {
        return Err(invalid());
    }
    let mut builder = FontBuilder::new();
    let mut total = 0usize;
    for index in 0..count {
        let entry = WOFF_HEADER + index * WOFF_ENTRY;
        let tag = Tag::new(&[font[entry], font[entry + 1], font[entry + 2], font[entry + 3]]);
        let offset = be32(font, entry + 4) as usize;
        let stored = be32(font, entry + 8) as usize;
        let original = be32(font, entry + 12) as usize;
        let end = offset.checked_add(stored).ok_or_else(invalid)?;
        if offset < directory || end > font.len() || stored > original || original > EXPANDED_LIMIT {
            return Err(invalid());
        }
        total = total
            .checked_add(original)
            .filter(|sum| *sum <= EXPANDED_LIMIT)
            .ok_or("The WOFF font expands beyond its size limit.")?;
        let data = if stored == original {
            font[offset..end].to_vec()
        } else {
            let expanded = decompress_to_vec_zlib_with_limit(&font[offset..end], original)
                .map_err(|_| "A WOFF table could not be expanded.")?;
            if expanded.len() != original {
                return Err("A WOFF table expanded to the wrong size.".into());
            }
            expanded
        };
        builder.add_raw(tag, data);
    }
    Ok(builder.build())
}

/// Packages finished sfnt bytes in the requested container.
pub fn encode(sfnt: Vec<u8>, container: Container) -> Result<Vec<u8>> {
    match container {
        Container::Sfnt => Ok(sfnt),
        Container::Woff2 => {
            shim::woff2_encode(&sfnt).ok_or_else(|| "The WOFF2 font could not be written.".into())
        }
        Container::Woff => encode_woff(&sfnt),
    }
}

fn encode_woff(sfnt: &[u8]) -> Result<Vec<u8>> {
    if sfnt.len() < 12 {
        return Err("The converted font is too short to package.".into());
    }
    let count = be16(sfnt, 4) as usize;
    if count == 0 || 12 + count * 16 > sfnt.len() {
        return Err("The converted font has an unusable table directory.".into());
    }
    let mut entries = Vec::with_capacity(count);
    let mut expanded = 12 + count * 16;
    for index in 0..count {
        let record = 12 + index * 16;
        let tag = &sfnt[record..record + 4];
        let offset = be32(sfnt, record + 8) as usize;
        let length = be32(sfnt, record + 12) as usize;
        let end = offset
            .checked_add(length)
            .filter(|end| *end <= sfnt.len())
            .ok_or("The converted font has an out-of-range table.")?;
        let checksum = be32(sfnt, record + 4);
        let original = &sfnt[offset..end];
        let compressed = compress_to_vec_zlib(original, 8);
        let stored = if compressed.len() < original.len() { compressed } else { original.to_vec() };
        expanded += (length + 3) & !3;
        entries.push((tag.to_vec(), stored, length, checksum));
    }
    let mut output = vec![0u8; WOFF_HEADER + count * WOFF_ENTRY];
    output[0..4].copy_from_slice(b"wOFF");
    output[4..8].copy_from_slice(&sfnt[0..4]);
    output[12..14].copy_from_slice(&(count as u16).to_be_bytes());
    output[16..20].copy_from_slice(&(expanded as u32).to_be_bytes());
    for (index, (tag, stored, original, checksum)) in entries.iter().enumerate() {
        let entry = WOFF_HEADER + index * WOFF_ENTRY;
        let at = output.len() as u32;
        output[entry..entry + 4].copy_from_slice(tag);
        output[entry + 4..entry + 8].copy_from_slice(&at.to_be_bytes());
        output[entry + 8..entry + 12].copy_from_slice(&(stored.len() as u32).to_be_bytes());
        output[entry + 12..entry + 16].copy_from_slice(&(*original as u32).to_be_bytes());
        output[entry + 16..entry + 20].copy_from_slice(&checksum.to_be_bytes());
        output.extend_from_slice(stored);
        output.resize((output.len() + 3) & !3, 0);
    }
    let length = output.len() as u32;
    output[8..12].copy_from_slice(&length.to_be_bytes());
    Ok(output)
}
