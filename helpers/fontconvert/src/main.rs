//! Converts a font between TTF, OTF, WOFF, and WOFF2 at its default design location.
//!
//! Variable fonts lose their axes: the pinned HarfBuzz subsetter rewrites the font at the
//! default instance and removes variation and signature tables, CFF2 becomes CFF, and only
//! the outline flavour is changed here when the target container requires it.

mod cff;
mod container;
mod outline;
mod shim;

use container::Container;
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use write_fonts::types::Tag;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

pub const INPUT_LIMIT: usize = 64 * 1024 * 1024;
pub const EXPANDED_LIMIT: usize = 128 * 1024 * 1024;

/// Colour and bitmap-strike fonts have no faithful static form on this path, so they are refused
/// rather than silently flattened.
const UNSUPPORTED: [&[u8; 4]; 8] =
    [b"COLR", b"CBDT", b"sbix", b"SVG ", b"EBDT", b"EBLC", b"bdat", b"bloc"];
/// No variation data may remain in a static font, and a signature cannot survive the rewrite.
const STALE: [&[u8; 4]; 9] =
    [b"fvar", b"gvar", b"avar", b"cvar", b"HVAR", b"VVAR", b"MVAR", b"CFF2", b"DSIG"];

fn tags(sfnt: &[u8]) -> Result<Vec<Tag>> {
    if sfnt.len() < 12 {
        return Err("The font has no table directory.".into());
    }
    let count = u16::from_be_bytes([sfnt[4], sfnt[5]]) as usize;
    if count == 0 || count > 256 || 12 + count * 16 > sfnt.len() {
        return Err("The font declares an unusable table count.".into());
    }
    Ok((0..count)
        .map(|index| {
            let at = 12 + index * 16;
            Tag::new(&[sfnt[at], sfnt[at + 1], sfnt[at + 2], sfnt[at + 3]])
        })
        .collect())
}

fn has(list: &[Tag], name: &[u8; 4]) -> bool {
    list.contains(&Tag::new(name))
}

fn convert(source: &[u8], format: &str) -> Result<Vec<u8>> {
    let target = match format {
        "ttf" | "otf" => Container::Sfnt,
        "woff" => Container::Woff,
        "woff2" => Container::Woff2,
        _ => return Err("The font output format is unknown.".into()),
    };
    let sfnt = container::decode(source)?;
    if sfnt.len() > EXPANDED_LIMIT {
        return Err("The expanded font exceeds its size limit.".into());
    }
    let present = tags(&sfnt)?;
    for name in UNSUPPORTED {
        if has(&present, name) {
            return Err("Fonts with colour data or bitmap strikes are not supported by this font conversion path.".into());
        }
    }
    let normalized = shim::normalize(&sfnt)
        .ok_or("The font could not be read at its default design location.")?;
    let present = tags(&normalized)?;
    for name in STALE {
        if has(&present, name) {
            return Err("Variation or signature data remained after the font was made static.".into());
        }
    }
    // Only OTF carries CFF outlines. Keeping CFF inside the web containers instead was measured
    // at roughly a third larger, because WOFF2 transforms TrueType outlines and cannot transform
    // CFF, so the web formats stay on TrueType outlines.
    let want_cff = format == "otf";
    let sfnt = match (has(&present, b"glyf"), want_cff) {
        (true, true) => outline::to_cff(&normalized)?,
        (false, false) => outline::to_truetype(&normalized)?,
        _ => normalized,
    };
    let produced = tags(&sfnt)?;
    let cff = has(&produced, b"CFF ");
    if cff == has(&produced, b"glyf") || !has(&produced, b"cmap") || !has(&produced, b"name") {
        return Err("The converted font is missing its outline or naming tables.".into());
    }
    if want_cff != cff {
        return Err("The converted font has the wrong outline format.".into());
    }
    container::encode(sfnt, target)
}

fn run() -> Result<()> {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let [input, output, format] = arguments.as_slice() else {
        return Err("Expected an input font, an output path, and a format.".into());
    };
    let source = std::fs::read(Path::new(input))?;
    if source.len() < 12 || source.len() > INPUT_LIMIT {
        return Err("Font files must be between 12 bytes and 64 MiB.".into());
    }
    let produced = convert(&source, format)?;
    if produced.len() > EXPANDED_LIMIT {
        return Err("The converted font exceeds its size limit.".into());
    }
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(Path::new(output))?;
    file.write_all(&produced)?;
    file.sync_all()?;
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
