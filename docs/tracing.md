# Bitmap images to SVG

Change a still image's extension to `.svg` in a watched folder to trace its shapes and colors. `.svgz` produces the same drawing with GZIP compression. Manual conversion uses the same engine. Automatic conversion keeps the original for exact Undo.

The output contains vector paths. Tracing approximates the source shapes and colors. It does not make a photo lossless or recover the original drawing commands. Photos and noisy images can produce large SVG files.

Photo smoothing can round canvas corners. Speckle removal can omit small regions. Both can leave transparent gaps in output from an opaque source. Use pixel paths and a zero speckle filter when sharp boundaries matter.

## Presets and controls

Photo is the default preset. Poster keeps smaller color regions. Line Art traces dark regions as black paths and leaves light regions transparent. It uses weighted sRGB brightness with a threshold of 128 out of 255.

| Preset | Colors | Speckle filter | Color precision | Layer difference | Corner threshold |
| --- | --- | --- | --- | --- | --- |
| Photo | Color | 10 | 8 | 48 | 180° |
| Poster | Color | 4 | 8 | 16 | 60° |
| Line Art | Black | 4 | Inactive | Inactive | 60° |

All presets use smooth paths, segment length 4, splice threshold 45°, and up to 10 fitting iterations. Color presets use overlapping layers.

Turn on **Advanced tracing** to use the individual controls. The saved preset then becomes inactive. Switching between presets and advanced controls keeps the inactive values saved.

| Advanced control | Default | Range or choices | Effect |
| --- | --- | --- | --- |
| Colors | Color | Color, Black and white | Trace color regions or dark shapes. |
| Layers | Stacked | Stacked, Cutout | Overlap color layers or cut holes through them. Inactive for black and white. |
| Paths | Spline | Spline, Polygon, Pixel | Use smooth curves, straight segments, or pixel boundaries. |
| Speckle filter | 4 | 0–256 | Remove color regions smaller than the square of this value. 4 means 16 pixels. 0 keeps small regions. |
| Color precision | 6 | 1–12 | Keep more color detail. Prepared colors have 8 bits per channel, so 8–12 give the same precision. Inactive for black and white. |
| Layer difference | 16 | 1–128 | Control color differences between layers. Inactive for black and white. |
| Corner threshold | 60° | 0–180° | Select corners during curve fitting. |
| Segment length | 4 | 0–100 | Limit segment length during curve fitting. The arrows move in steps of 0.5. Zero applies no minimum length. |
| Splice threshold | 45° | 0–180° | Control where fitted curves join. |
| Iterations | 10 | 1–100 | Limit repeated curve fitting. |

Corner, segment, splice, and iteration controls apply to Spline paths. More iterations and shorter segments can increase work and output size. Settings are validated even when inactive.

## Color, transparency, and source content

macOS decodes the image, applies its orientation, and prepares 8-bit sRGB pixels. Higher source precision is reduced before tracing. The shared lossy quality and image metadata controls do not affect tracing. SVG output omits source EXIF, XMP, and descriptive image metadata.

Transparency uses a separate vector opacity mask. Fully hidden RGB values do not affect the drawing. An identity group filter combines overlapping colors before the mask is applied. This avoids a native renderer error that otherwise increases opacity where paths overlap. The SVG keeps its paths, but an editor or a later PDF export can rasterize filtered groups. Renderers differ in mask and filter support.

Original tests preserve every alpha value in a 256-level opacity ramp through the native renderer. A small transparent hole and a half-transparent color region keep their intended interior opacity. Hard mask edges can soften during rendering. These checks do not establish pixel-exact edges for arbitrary artwork.

Checked still inputs include PNG, JPEG, BMP, TIFF, GIF, WebP, HEIC, AVIF, and JPEG XL. Other inputs depend on the native image reader. Complete RAW and icon-variant coverage remains in development. Timed images and multipage bitmaps are refused. Their pages cannot be discarded through an intermediate PDF route. PDF-to-SVG conversion has its own page controls and retains its existing document behavior.

## Limits and implementation

Source files are limited to 512 MiB, with 32 million pixels and at most 100,000 pixels per edge. SVG output is limited to 64 MiB and 99,980 paths. These limits also apply before SVGZ compression.

The tracing helper uses one CPU thread and permits at most 1 GiB of live Rust allocations. This is not a total process RSS limit or an aggregate memory limit. Native image preparation and allocator overhead use additional memory. A complex image can reach the path, memory, or time limit before its pixel limit. The external stage has a 120-second timeout. Failures and cancellation remove private output and keep the source.

The original adapter writes one private RGBA file. It reuses native orientation and color preparation and the shared streaming pixel writer. The helper uses VTracer 0.6.5 for color tracing and visioncortex 0.8.10 for exact opacity regions. It calls their in-memory APIs. A small source patch widens color totals to 64 bits. This prevents large regions from overflowing and receiving the wrong color. The sandbox launcher denies network access and restricts file access. Existing destinations are never overwritten. The source version is checked again before publication.

## Measured performance

These are medians from three complete packaged command conversions on an M2 Max with macOS 26.6.2. Time includes native input preparation and SVG validation. Output rendering for error checks is outside the timed conversion. Reported RSS can include a child helper's peak. It is not the simultaneous memory total of all processes. The GUI is excluded.

| Original workload | Preset | Time | Reported peak RSS | SVG bytes |
| --- | --- | --- | --- | --- |
| 512 × 512 artwork | Poster | 0.07 s | 22.4 MiB | 911 |
| 1-megapixel noise | Photo | 6.61 s | 345.4 MiB | 1,510,380 |
| 24-megapixel flat color | Photo | 1.21 s | 798.8 MiB | 890 |
| 1-megapixel opacity ramp | Poster | 0.30 s | 68.4 MiB | 24,502 |

The artwork has RGB RMS errors of 0.62, 2.83, and 1.39 on a 0–255 scale after rendering on white. The noisy source has errors near 77 in each channel. Photo tracing is a strong approximation of noise. The large flat image keeps its color but has rounded boundary differences. Both Photo workloads include fully transparent edge or omitted pixels. The opacity ramp preserves every alpha value and has RGB RMS errors of 1.21, 0, and 0.70. These results do not establish full image fidelity or low memory use for every input.

Samples, hashes, and measurement scope are recorded in `research/tracing-performance.json` in the source repository.

## Build and checks

```sh
python3 tools/build-rust.py vectortrace
swift test --filter testSVGTracingAndAutomaticUndo
```

Cargo manifests and lock files pin the helper's dependencies. The build retains notices, matching source where needed, and the original build inputs. The app bundles the helper and launcher. Users need no Rust tools or separate downloads.

For example, this image options file selects polygon paths and keeps small regions:

```json
{"tracing":{"advanced":true,"pathMode":"polygon","filterSpeckle":0,"colorPrecision":8}}
```

```sh
swift run allomer convert artwork.png artwork.svg --image-options image-options.json
```

Run `python3 tools/check-tracing.py` with Pillow for preset differences, every advanced control, the 8-bit precision ceiling, all eight orientations, opacity, SVGZ, source formats, invalid settings, page and animation refusal, path limits, source preservation, and failure cleanup. It checks vector structure and renders output through the native SVG engine. `--command` and `--tools` select the packaged app. `--benchmark-only` measures three complete conversions per workload; `--report` selects the result file. Rendering for color-error measurements is outside the timed conversion.
