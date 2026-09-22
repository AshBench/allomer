use std::fs::{File, OpenOptions};
use std::io::{self, BufWriter, Read, Write};
use std::path::Path;
use visioncortex::{PathSimplifyMode, PointF64};
use vtracer::{ColorImage, ColorMode, Config, Preset, SvgFile};

#[path = "../../bounded_heap.rs"]
mod bounded_heap;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const HEAP_LIMIT: usize = 1024 * 1024 * 1024;
const OUTPUT_LIMIT: usize = 64 * 1024 * 1024;
const PATH_LIMIT: usize = 99_980;

#[test]
fn large_region_color_stays_exact() {
    let color = visioncortex::Color::new_rgba(30, 100, 200, 255);
    let mut sum = visioncortex::ColorSum::new();
    sum.add(&color);
    for _ in 0..25 {
        sum.merge(&sum.clone());
        assert_eq!(sum.average(), color);
    }
}

struct Output {
    file: BufWriter<File>,
    remaining: usize,
    paths: usize,
}

impl Write for Output {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > self.remaining {
            return Err(io::Error::other("The traced SVG exceeds 64 MiB."));
        }
        let count = self.file.write(bytes)?;
        self.remaining -= count;
        Ok(count)
    }
    fn flush(&mut self) -> io::Result<()> { self.file.flush() }
}

fn write_paths(output: &mut Output, svg: SvgFile) -> Result<()> {
    if svg.paths.len() > PATH_LIMIT - output.paths {
        return Err("The image produces too many vector paths.".into());
    }
    output.paths += svg.paths.len();
    for item in svg.paths {
        let (data, offset) = item.path.to_svg_string(true, PointF64::default(), svg.path_precision);
        if !offset.x.is_finite() || !offset.y.is_finite() || data.contains("NaN") || data.contains("inf") {
            return Err("Tracing produced an invalid path coordinate.".into());
        }
        writeln!(output, "<path fill=\"{}\" d=\"{data}\" transform=\"translate({},{})\"/>",
            item.color.to_hex_string(), offset.x, offset.y)?;
    }
    Ok(())
}

fn opacity_paths(image: ColorImage) -> Result<SvgFile> {
    use visioncortex::color_clusters::{Runner, RunnerConfig};
    let mut svg = SvgFile::new(image.width, image.height, Some(0));
    let clusters = Runner::new(RunnerConfig {
        good_min_area: 0, good_max_area: image.width * image.height,
        is_same_color_a: 0, is_same_color_b: 0, deepen_diff: 0, hollow_neighbours: 0,
        ..RunnerConfig::default()
    }, image).run();
    let view = clusters.view();
    if view.clusters_output.len() > PATH_LIMIT { return Err("The opacity mask has too many paths.".into()); }
    for &index in view.clusters_output.iter().rev() {
        let cluster = view.get_cluster(index);
        svg.add_path(cluster.to_compound_path(&view, false, PathSimplifyMode::None, 0.0, 1.0, 1, 0.0),
            cluster.residue_color());
    }
    Ok(svg)
}

fn trace(mut pixels: Vec<u8>, width: usize, height: usize, config: Config, output: &mut Output) -> Result<()> {
    writeln!(output, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{width}\" height=\"{height}\" viewBox=\"0 0 {width} {height}\">")?;
    let masked = pixels.chunks_exact(4).any(|pixel| pixel[3] != 255);
    if masked {
        let mut alpha = Vec::with_capacity(pixels.len());
        for pixel in pixels.chunks_exact_mut(4) {
            alpha.extend_from_slice(&[pixel[3], pixel[3], pixel[3], 255]);
            if pixel[3] == 0 { pixel[..3].fill(255); }
            pixel[3] = 255;
        }
        writeln!(output, "<defs><mask id=\"opacity\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"{width}\" height=\"{height}\" style=\"mask-type:luminance\" color-interpolation=\"sRGB\" shape-rendering=\"crispEdges\">")?;
        write_paths(output, opacity_paths(ColorImage { pixels: alpha, width, height })?)?;
        // Combine overlapping colors before applying the mask in the native renderer.
        writeln!(output, "</mask><filter id=\"colors\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"{width}\" height=\"{height}\" color-interpolation-filters=\"sRGB\"><feComponentTransfer><feFuncR type=\"linear\" slope=\"1\" intercept=\"0\"/></feComponentTransfer></filter></defs><g mask=\"url(#opacity)\"><g filter=\"url(#colors)\">")?;
    }
    if matches!(config.color_mode, ColorMode::Binary) {
        for pixel in pixels.chunks_exact_mut(4) {
            let gray = (2126 * u32::from(pixel[0]) + 7152 * u32::from(pixel[1]) + 722 * u32::from(pixel[2]) + 5000) / 10000;
            pixel[..3].fill(gray as u8);
        }
    }
    write_paths(output, vtracer::convert(ColorImage { pixels, width, height }, config)?)?;
    if masked { writeln!(output, "</g></g>")?; }
    writeln!(output, "</svg>")?;
    output.flush()?;
    Ok(())
}

fn run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() == 2 && args[1] == "--version" { println!("vectortrace 0.1.0"); return Ok(()); }
    if args.len() != 17 {
        return Err("Expected RGBA input, SVG output, width, height, advanced, preset, color, hierarchy, path, speckle, precision, layer, corner, length, splice, and iterations.".into());
    }
    let text = |index: usize| args[index].to_str().ok_or("Invalid tracing argument text.");
    let width = text(3)?.parse::<usize>()?;
    let height = text(4)?.parse::<usize>()?;
    if width == 0 || height == 0 || width > 100_000 || height > 100_000 || width > 32_000_000 / height {
        return Err("Tracing needs an image within 32 million pixels and 100,000 pixels per edge.".into());
    }
    let advanced = text(5)?.parse::<bool>()?;
    let preset = match text(6)? {
        "photo" => Preset::Photo, "poster" => Preset::Poster, "line_art" => Preset::Bw,
        _ => return Err("Unknown tracing preset.".into()),
    };
    let mut config = Config::default();
    config.color_mode = text(7)?.parse()?;
    config.hierarchical = text(8)?.parse()?;
    config.mode = match text(9)? {
        "pixel" => PathSimplifyMode::None, "polygon" => PathSimplifyMode::Polygon, "spline" => PathSimplifyMode::Spline,
        _ => return Err("Unknown tracing path mode.".into()),
    };
    config.filter_speckle = text(10)?.parse()?;
    let precision: i32 = text(11)?.parse()?;
    config.layer_difference = text(12)?.parse()?;
    config.corner_threshold = text(13)?.parse()?;
    config.length_threshold = text(14)?.parse()?;
    config.splice_threshold = text(15)?.parse()?;
    config.max_iterations = text(16)?.parse()?;
    if config.filter_speckle > 256 || !(1..=12).contains(&precision)
        || !(1..=128).contains(&config.layer_difference) || !(0..=180).contains(&config.corner_threshold)
        || !config.length_threshold.is_finite() || !(0.0..=100.0).contains(&config.length_threshold)
        || !(0..=180).contains(&config.splice_threshold) || !(1..=100).contains(&config.max_iterations) {
        return Err("A tracing setting is outside its allowed range.".into());
    }
    // Prepared pixels have eight bits per color channel.
    config.color_precision = precision.min(8);
    if !advanced { config = Config::from_preset(preset); }
    let source = Path::new(&args[1]);
    let destination = Path::new(&args[2]);
    let expected = width * height * 4;
    let metadata = std::fs::symlink_metadata(source)?;
    if !metadata.is_file() || metadata.len() != expected as u64 { return Err("The prepared RGBA file has an invalid size or type.".into()); }
    let mut pixels = Vec::with_capacity(expected);
    File::open(source)?.take(expected as u64 + 1).read_to_end(&mut pixels)?;
    if pixels.len() != expected { return Err("The prepared RGBA file changed while reading.".into()); }
    let file = OpenOptions::new().write(true).create_new(true).open(destination)?;
    let mut output = Output { file: BufWriter::new(file), remaining: OUTPUT_LIMIT, paths: 0 };
    let result = trace(pixels, width, height, config, &mut output);
    drop(output);
    if result.is_err() { let _ = std::fs::remove_file(destination); }
    result
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
