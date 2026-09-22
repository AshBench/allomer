//! Writes a CFF table from outlines, for the one conversion HarfBuzz does not perform:
//! TrueType outlines into an OpenType/CFF font. Quadratic curves are raised to cubic exactly,
//! so this path moves no point on the curve.

use crate::Result;
use kurbo::{BezPath, PathEl, Point};

const STACK_LIMIT: usize = 48;
const OP_RLINETO: u8 = 5;
const OP_RRCURVETO: u8 = 8;
const OP_ENDCHAR: u8 = 14;
const OP_RMOVETO: u8 = 21;

/// One glyph's outline in font units, with the advance its charstring declares.
pub struct Outline {
    pub path: BezPath,
    pub advance: i32,
    pub name: String,
}

fn integer(value: i32, out: &mut Vec<u8>) {
    match value {
        -107..=107 => out.push((value + 139) as u8),
        108..=1131 => {
            let shifted = value - 108;
            out.push((shifted / 256 + 247) as u8);
            out.push((shifted % 256) as u8);
        }
        -1131..=-108 => {
            let shifted = -value - 108;
            out.push((shifted / 256 + 251) as u8);
            out.push((shifted % 256) as u8);
        }
        -32768..=32767 => {
            out.push(28);
            out.extend_from_slice(&(value as i16).to_be_bytes());
        }
        _ => {
            out.push(255);
            out.extend_from_slice(&((value as i64) << 16).to_be_bytes()[4..]);
        }
    }
}

/// Dictionary offsets always use the five-byte form, so the dictionary's length does not depend
/// on the values written into it. That lets the table be assembled without iterating to a fixpoint.
fn dict_offset(value: i32, out: &mut Vec<u8>) {
    out.push(29);
    out.extend_from_slice(&value.to_be_bytes());
}

fn dict_real(value: f64, out: &mut Vec<u8>) {
    let mut nibbles: Vec<u8> = Vec::new();
    for character in format!("{value}").chars() {
        nibbles.push(match character {
            '0'..='9' => character as u8 - b'0',
            '.' => 0xa,
            '-' => 0xe,
            // Rust prints finite values without an exponent, so this is unreachable in practice.
            _ => return dict_offset(0, out),
        });
    }
    nibbles.push(0xf);
    if nibbles.len() % 2 == 1 {
        nibbles.push(0xf);
    }
    out.push(30);
    out.extend(nibbles.chunks(2).map(|pair| pair[0] << 4 | pair[1]));
}

fn index(items: &[Vec<u8>]) -> Vec<u8> {
    if items.is_empty() {
        return vec![0, 0];
    }
    let total: usize = items.iter().map(Vec::len).sum();
    let width: usize = match total + 1 {
        0..=0xff => 1,
        0x100..=0xffff => 2,
        0x1_0000..=0xff_ffff => 3,
        _ => 4,
    };
    let mut out = Vec::with_capacity(total + (items.len() + 1) * width + 3);
    out.extend_from_slice(&(items.len() as u16).to_be_bytes());
    out.push(width as u8);
    let mut position: u32 = 1;
    out.extend_from_slice(&position.to_be_bytes()[4 - width..]);
    for item in items {
        position += item.len() as u32;
        out.extend_from_slice(&position.to_be_bytes()[4 - width..]);
    }
    for item in items {
        out.extend_from_slice(item);
    }
    out
}

fn charstring(outline: &Outline) -> Vec<u8> {
    let quantise = |point: &Point| (point.x.round() as i32, point.y.round() as i32);
    let mut out = Vec::new();
    let mut pending: Vec<i32> = Vec::new();
    let mut pending_operator = 0u8;
    let mut current = (0i32, 0i32);
    // The leading odd operand of the first stack-clearing operator is the glyph's width, measured
    // against the nominalWidthX of 0 written into the Private dictionary.
    let mut width = Some(outline.advance).filter(|advance| *advance != 0);

    fn flush(pending: &mut Vec<i32>, operator: u8, out: &mut Vec<u8>) {
        if pending.is_empty() {
            return;
        }
        for value in pending.drain(..) {
            integer(value, out);
        }
        out.push(operator);
    }

    for element in outline.path.elements() {
        let (values, operator) = match element {
            PathEl::MoveTo(point) => {
                flush(&mut pending, pending_operator, &mut out);
                let (x, y) = quantise(point);
                if let Some(advance) = width.take() {
                    integer(advance, &mut out);
                }
                integer(x - current.0, &mut out);
                integer(y - current.1, &mut out);
                out.push(OP_RMOVETO);
                current = (x, y);
                continue;
            }
            PathEl::LineTo(point) => {
                let (x, y) = quantise(point);
                let values = vec![x - current.0, y - current.1];
                current = (x, y);
                (values, OP_RLINETO)
            }
            PathEl::CurveTo(first, second, point) => {
                let (x1, y1) = quantise(first);
                let (x2, y2) = quantise(second);
                let (x3, y3) = quantise(point);
                let values = vec![x1 - current.0, y1 - current.1, x2 - x1, y2 - y1, x3 - x2, y3 - y2];
                current = (x3, y3);
                (values, OP_RRCURVETO)
            }
            PathEl::QuadTo(..) => unreachable!("quadratic curves are raised to cubic before this"),
            PathEl::ClosePath => continue,
        };
        if pending_operator != operator || pending.len() + values.len() > STACK_LIMIT {
            flush(&mut pending, pending_operator, &mut out);
            pending_operator = operator;
        }
        pending.extend(values);
    }
    flush(&mut pending, pending_operator, &mut out);
    if let Some(advance) = width.take() {
        integer(advance, &mut out);
    }
    out.push(OP_ENDCHAR);
    out
}

/// A CFF table holding every supplied outline, named for the font's PostScript name.
pub fn build(name: &str, units_per_em: u16, outlines: &[Outline]) -> Result<Vec<u8>> {
    if outlines.is_empty() || outlines.len() > u16::MAX as usize {
        return Err("The font has an unusable glyph count for CFF output.".into());
    }
    let cleaned: String = name
        .chars()
        .filter(|character| character.is_ascii_graphic() && !"()[]{}<>/%".contains(*character))
        .take(63)
        .collect();
    let font_name = if cleaned.is_empty() { "Converted".to_owned() } else { cleaned };

    // Glyph zero is .notdef, which the charset leaves implicit; every later glyph contributes one
    // custom string, so its identifier is 391 plus its position.
    let strings: Vec<Vec<u8>> = outlines[1..].iter().map(|o| o.name.as_bytes().to_vec()).collect();
    let charstrings: Vec<Vec<u8>> = outlines.iter().map(charstring).collect();
    let mut charset = vec![0u8];
    for position in 0..strings.len() {
        charset.extend_from_slice(&((391 + position) as u16).to_be_bytes());
    }
    let mut private = Vec::new();
    integer(0, &mut private);
    private.push(20); // defaultWidthX
    integer(0, &mut private);
    private.push(21); // nominalWidthX

    let header = [1u8, 0, 4, 4];
    let name_index = index(&[font_name.into_bytes()]);
    let string_index = index(&strings);
    let global_subrs = index(&[]);
    let charstring_index = index(&charstrings);

    let top_dict = |charset_at: i32, charstrings_at: i32, private_at: i32| {
        let mut dict = Vec::new();
        if units_per_em != 1000 {
            let scale = 1.0 / f64::from(units_per_em);
            for value in [scale, 0.0, 0.0, scale, 0.0, 0.0] {
                dict_real(value, &mut dict);
            }
            dict.extend_from_slice(&[12, 7]); // FontMatrix
        }
        dict_offset(charset_at, &mut dict);
        dict.push(15); // charset
        dict_offset(charstrings_at, &mut dict);
        dict.push(17); // CharStrings
        dict_offset(private.len() as i32, &mut dict);
        dict_offset(private_at, &mut dict);
        dict.push(18); // Private
        dict
    };

    let measured = index(&[top_dict(0, 0, 0)]);
    let charset_at = header.len() + name_index.len() + measured.len() + string_index.len() + global_subrs.len();
    let charstrings_at = charset_at + charset.len();
    let private_at = charstrings_at + charstring_index.len();
    let top_index = index(&[top_dict(charset_at as i32, charstrings_at as i32, private_at as i32)]);
    if top_index.len() != measured.len() {
        return Err("The CFF dictionary changed length while being written.".into());
    }

    let mut out = Vec::with_capacity(private_at + private.len());
    for part in [&header[..], &name_index, &top_index, &string_index, &global_subrs,
                 &charset, &charstring_index, &private] {
        out.extend_from_slice(part);
    }
    Ok(out)
}
