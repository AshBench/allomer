//! Outline-flavour conversion. HarfBuzz rewrites tables but never changes a font between
//! TrueType and CFF outlines, so those two directions are performed here.

use crate::cff::{self, Outline};
use crate::Result;
use kurbo::{Affine, BezPath, CubicBez, PathEl, Point};
use skrifa::instance::{LocationRef, Size};
use skrifa::outline::{DrawSettings, OutlinePen};
use skrifa::raw::tables::glyf::{Anchor, CurvePoint, Glyf, Glyph};
use skrifa::raw::tables::loca::Loca;
use skrifa::raw::TableProvider;
use skrifa::string::StringId;
use skrifa::{FontRef, GlyphId, MetadataProvider};
use write_fonts::tables::glyf::{GlyfLocaBuilder, SimpleGlyph};
use write_fonts::types::Tag;
use write_fonts::FontBuilder;

/// Tables that belong only to a TrueType-outline font.
const TRUETYPE_ONLY: [&[u8; 4]; 8] = [b"glyf", b"loca", b"cvt ", b"fpgm", b"prep", b"gasp", b"hdmx", b"LTSH"];
/// Tables that belong only to a CFF-outline font.
const CFF_ONLY: [&[u8; 4]; 3] = [b"CFF ", b"CFF2", b"VORG"];

#[derive(Default)]
struct PathPen {
    path: BezPath,
    open: bool,
}

impl PathPen {
    fn finish(mut self) -> BezPath {
        if self.open {
            self.path.close_path();
        }
        self.path
    }
}

impl OutlinePen for PathPen {
    fn move_to(&mut self, x: f32, y: f32) {
        if self.open {
            self.path.close_path();
        }
        self.path.move_to((f64::from(x), f64::from(y)));
        self.open = true;
    }
    fn line_to(&mut self, x: f32, y: f32) {
        self.path.line_to((f64::from(x), f64::from(y)));
    }
    fn quad_to(&mut self, cx: f32, cy: f32, x: f32, y: f32) {
        self.path.quad_to((f64::from(cx), f64::from(cy)), (f64::from(x), f64::from(y)));
    }
    fn curve_to(&mut self, cx0: f32, cy0: f32, cx1: f32, cy1: f32, x: f32, y: f32) {
        self.path.curve_to((f64::from(cx0), f64::from(cy0)), (f64::from(cx1), f64::from(cy1)),
                           (f64::from(x), f64::from(y)));
    }
    fn close(&mut self) {
        if self.open {
            self.path.close_path();
            self.open = false;
        }
    }
}

/// Every glyph's outline in font units, for a font with CFF or CFF2 outlines.
fn paths(font: &FontRef) -> Result<Vec<BezPath>> {
    let glyphs = font.outline_glyphs();
    let count = font.maxp()?.num_glyphs();
    let mut collected = Vec::with_capacity(count as usize);
    for identifier in 0..count {
        let mut pen = PathPen::default();
        if let Some(glyph) = glyphs.get(GlyphId::from(identifier)) {
            glyph
                .draw(DrawSettings::unhinted(Size::unscaled(), LocationRef::default()), &mut pen)
                .map_err(|_| "A glyph outline could not be read.")?;
        }
        collected.push(pen.finish());
    }
    Ok(collected)
}

/// Every glyph's outline read straight from the glyph table, with composite components placed by
/// their own transform in full precision.
///
/// The outline readers available here resolve a composite the way FreeType does, rounding the
/// placement to whole units and, for a component carrying a scale, landing a unit away from where
/// macOS draws the same glyph. That is within what a rasterizer may do and outside what this
/// app's own outline check allows, so the placement is done here instead.
fn glyf_paths(font: &FontRef) -> Result<Vec<BezPath>> {
    let glyf = font.glyf()?;
    let loca = font.loca(None)?;
    let count = font.maxp()?.num_glyphs();
    let mut collected = Vec::with_capacity(count as usize);
    for identifier in 0..count {
        let mut path = BezPath::new();
        append_glyph(&glyf, &loca, GlyphId::from(identifier), Affine::IDENTITY, 0, &mut path)?;
        collected.push(path);
    }
    Ok(collected)
}

fn append_glyph(glyf: &Glyf, loca: &Loca, glyph: GlyphId, placement: Affine, depth: u8,
                path: &mut BezPath) -> Result<()> {
    if depth > 8 {
        return Err("A composite glyph nests too deeply.".into());
    }
    let Some(outline) = loca.get_glyf(glyph, glyf)? else { return Ok(()) };
    match outline {
        Glyph::Simple(simple) => {
            let points: Vec<CurvePoint> = simple.points().collect();
            let mut start = 0usize;
            for end in simple.end_pts_of_contours() {
                let end = end.get() as usize + 1;
                if end > points.len() || end <= start {
                    return Err("A glyph contour runs past its points.".into());
                }
                append_contour(&points[start..end], placement, path);
                start = end;
            }
        }
        Glyph::Composite(composite) => {
            for component in composite.components() {
                let Anchor::Offset { x, y } = component.anchor else {
                    return Err("Composite glyphs anchored to a point are not supported.".into());
                };
                let matrix = component.transform;
                // OpenType places a component at (xx*x + xy*y + dx, yx*x + yy*y + dy).
                let step = Affine::new([
                    f64::from(matrix.xx.to_f32()), f64::from(matrix.yx.to_f32()),
                    f64::from(matrix.xy.to_f32()), f64::from(matrix.yy.to_f32()),
                    f64::from(x), f64::from(y),
                ]);
                append_glyph(glyf, loca, component.glyph.into(), placement * step, depth + 1, path)?;
            }
        }
    }
    Ok(())
}

/// One TrueType contour, where consecutive off-curve points imply an on-curve point between them.
fn append_contour(points: &[CurvePoint], placement: Affine, path: &mut BezPath) {
    if points.is_empty() {
        return;
    }
    let at = |point: &CurvePoint| placement * Point::new(f64::from(point.x), f64::from(point.y));
    let between = |first: Point, second: Point| first.midpoint(second);
    let (start, from) = match points.iter().position(|point| point.on_curve) {
        Some(index) => (at(&points[index]), index),
        // A contour of nothing but off-curve points begins between its last and first points.
        None => (between(at(&points[points.len() - 1]), at(&points[0])), points.len() - 1),
    };
    path.move_to(start);
    let mut control: Option<Point> = None;
    for step in 1..=points.len() {
        let point = &points[(from + step) % points.len()];
        let position = at(point);
        if point.on_curve {
            match control.take() {
                Some(previous) => path.quad_to(previous, position),
                None => path.line_to(position),
            }
        } else if let Some(previous) = control.replace(position) {
            path.quad_to(previous, between(previous, position));
        }
    }
    if let Some(previous) = control {
        path.quad_to(previous, start);
    }
    path.close_path();
}

fn rounded(point: Point) -> Point {
    Point::new(point.x.round(), point.y.round())
}

/// Replaces the outline tables of `font` and repairs the headers that name the outline format.
fn rebuild(font: &FontRef, drop: &[&[u8; 4]], add: Vec<(Tag, Vec<u8>)>, loca_long: Option<bool>,
           maxp: Vec<u8>, post_version: Option<u32>) -> Result<Vec<u8>> {
    let mut builder = FontBuilder::new();
    for record in font.table_directory().table_records() {
        let tag = record.tag();
        if drop.iter().any(|name| tag == Tag::new(name)) || tag == Tag::new(b"maxp") {
            continue;
        }
        let data = font.table_data(tag).ok_or("A font table could not be read.")?;
        let mut bytes = data.as_bytes().to_vec();
        if tag == Tag::new(b"head") && bytes.len() >= 54 {
            if let Some(long) = loca_long {
                bytes[50..52].copy_from_slice(&i16::from(long).to_be_bytes());
            }
            bytes[52..54].copy_from_slice(&0i16.to_be_bytes());
        }
        if tag == Tag::new(b"post") {
            if let Some(version) = post_version {
                bytes.truncate(32);
                if bytes.len() < 32 {
                    return Err("The font's post table is too short.".into());
                }
                bytes[0..4].copy_from_slice(&version.to_be_bytes());
            }
        }
        builder.add_raw(tag, bytes);
    }
    builder.add_raw(Tag::new(b"maxp"), maxp);
    for (tag, data) in add {
        builder.add_raw(tag, data);
    }
    Ok(builder.build())
}

/// CFF or CFF2 outlines rewritten as TrueType outlines. Cubic curves become quadratic within
/// `tolerance` font units, which is the only approximation this helper performs.
pub fn to_truetype(sfnt: &[u8]) -> Result<Vec<u8>> {
    let font = FontRef::new(sfnt)?;
    let units_per_em = font.head()?.units_per_em();
    let tolerance = f64::from(units_per_em) / 1000.0;
    let mut builder = GlyfLocaBuilder::new();
    let mut max_points = 0u16;
    let mut max_contours = 0u16;
    // A CFF glyph is drawn at absolute coordinates and its recorded left side bearing is
    // advisory, but a TrueType glyph is placed by that bearing. Carrying the old values over
    // shifts every glyph whose bearing disagreed with its outline, so they are recomputed.
    let mut bearings: Vec<i16> = Vec::with_capacity(paths(&font)?.len());
    for path in paths(&font)? {
        let mut left = i32::MAX;
        let mut quadratic = BezPath::new();
        let mut current = Point::ZERO;
        let mut points = 0u16;
        let mut contours = 0u16;
        for element in path.elements() {
            match element {
                PathEl::MoveTo(point) => {
                    current = rounded(*point);
                    left = left.min(current.x as i32);
                    quadratic.move_to(current);
                    contours += 1;
                    points += 1;
                }
                PathEl::LineTo(point) => {
                    current = rounded(*point);
                    left = left.min(current.x as i32);
                    quadratic.line_to(current);
                    points += 1;
                }
                PathEl::QuadTo(control, point) => {
                    current = rounded(*point);
                    let control = rounded(*control);
                    left = left.min(current.x as i32).min(control.x as i32);
                    quadratic.quad_to(control, current);
                    points += 2;
                }
                PathEl::CurveTo(first, second, point) => {
                    // approx_spline is the cu2qu search: it returns the fewest quadratic
                    // segments that stay inside the tolerance, rather than subdividing blindly.
                    let cubic = CubicBez::new(current, *first, *second, *point);
                    match cubic.approx_spline(tolerance) {
                        Some(spline) => {
                            for quad in spline.to_quads() {
                                current = rounded(quad.p2);
                                let control = rounded(quad.p1);
                                left = left.min(current.x as i32).min(control.x as i32);
                                quadratic.quad_to(control, current);
                                points += 2;
                            }
                        }
                        None => {
                            for (_, _, quad) in cubic.to_quads(tolerance) {
                                current = rounded(quad.p2);
                                let control = rounded(quad.p1);
                                left = left.min(current.x as i32).min(control.x as i32);
                                quadratic.quad_to(control, current);
                                points += 2;
                            }
                        }
                    }
                }
                PathEl::ClosePath => quadratic.close_path(),
            }
        }
        max_points = max_points.max(points);
        max_contours = max_contours.max(contours);
        bearings.push(if left == i32::MAX { 0 } else { left.clamp(i16::MIN.into(), i16::MAX.into()) as i16 });
        if quadratic.is_empty() {
            builder.add_glyph(&write_fonts::tables::glyf::Glyph::Empty)?;
        } else {
            builder.add_glyph(&SimpleGlyph::from_bezpath(&quadratic)
                .map_err(|_| "A converted outline could not be stored.")?)?;
        }
    }
    let (glyf, loca, format) = builder.build();
    let count = font.maxp()?.num_glyphs();
    let mut maxp = Vec::with_capacity(32);
    maxp.extend_from_slice(&0x0001_0000u32.to_be_bytes());
    for value in [count, max_points, max_contours, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0] {
        maxp.extend_from_slice(&(value as u16).to_be_bytes());
    }
    let tables = vec![
        (Tag::new(b"glyf"), write_fonts::dump_table(&glyf)?),
        (Tag::new(b"loca"), write_fonts::dump_table(&loca)?),
        (Tag::new(b"hmtx"), horizontal_metrics(&font, &bearings)?),
    ];
    let long = matches!(format, write_fonts::tables::loca::LocaFormat::Long);
    rebuild(&font, &CFF_ONLY, tables, Some(long), maxp, None)
}

/// TrueType outlines rewritten as CFF outlines. Every quadratic curve is raised to the cubic
/// that draws the identical shape, so no point on any curve moves.
pub fn to_cff(sfnt: &[u8]) -> Result<Vec<u8>> {
    let font = FontRef::new(sfnt)?;
    let units_per_em = font.head()?.units_per_em();
    let names = font.glyph_names();
    let metrics = font.hmtx()?;
    let postscript = font
        .localized_strings(StringId::POSTSCRIPT_NAME)
        .english_or_first()
        .map(|entry| entry.to_string())
        .unwrap_or_default();
    let mut outlines = Vec::new();
    for (identifier, path) in glyf_paths(&font)?.into_iter().enumerate() {
        let glyph = GlyphId::from(identifier as u32);
        let mut cubic = BezPath::new();
        let mut current = Point::ZERO;
        for element in path.elements() {
            match element {
                PathEl::MoveTo(point) => {
                    current = *point;
                    cubic.move_to(current);
                }
                PathEl::LineTo(point) => {
                    current = *point;
                    cubic.line_to(current);
                }
                PathEl::QuadTo(control, point) => {
                    // The exact cubic form of a quadratic: both control points sit two thirds of
                    // the way from an endpoint towards the quadratic's single control point.
                    let first = current + (*control - current) * (2.0 / 3.0);
                    let second = *point + (*control - *point) * (2.0 / 3.0);
                    cubic.curve_to(first, second, *point);
                    current = *point;
                }
                PathEl::CurveTo(first, second, point) => {
                    cubic.curve_to(*first, *second, *point);
                    current = *point;
                }
                PathEl::ClosePath => cubic.close_path(),
            }
        }
        outlines.push(Outline {
            path: cubic,
            advance: i32::from(metrics.advance(glyph).unwrap_or(0)),
            name: names
                .get(glyph)
                .map(|name| name.as_str().to_owned())
                .unwrap_or_else(|| format!("g{identifier}")),
        });
    }
    let table = cff::build(&postscript, units_per_em, &outlines)?;
    let mut maxp = Vec::with_capacity(6);
    maxp.extend_from_slice(&0x0000_5000u32.to_be_bytes());
    maxp.extend_from_slice(&(outlines.len() as u16).to_be_bytes());
    rebuild(&font, &TRUETYPE_ONLY, vec![(Tag::new(b"CFF "), table)], Some(false), maxp,
            Some(0x0003_0000))
}

/// Rebuilds hmtx with the source advances and the converted outlines' own left side bearings,
/// keeping the long-metric count the hhea table declares.
fn horizontal_metrics(font: &FontRef, bearings: &[i16]) -> Result<Vec<u8>> {
    let long = font.hhea()?.number_of_h_metrics() as usize;
    let metrics = font.hmtx()?;
    let mut out = Vec::with_capacity(long * 4 + bearings.len().saturating_sub(long) * 2);
    for (identifier, bearing) in bearings.iter().enumerate() {
        let glyph = GlyphId::from(identifier as u32);
        if identifier < long {
            out.extend_from_slice(&metrics.advance(glyph).unwrap_or(0).to_be_bytes());
        }
        out.extend_from_slice(&bearing.to_be_bytes());
    }
    if out.len() < long * 4 {
        return Err("The font declares more long metrics than it has glyphs.".into());
    }
    Ok(out)
}
