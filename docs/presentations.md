# Presentations

PPTX converts to PDF locally. Each slide becomes one page at its original size. Slides keep their package order. Hidden slides are included. The route works for extension changes and manual conversion. Undo restores the original file bytes.

The reader uses the system WebKit engine with a bundled static presentation library. No Office app, Node.js runtime, network service, or runtime download is needed. PDF also connects presentations to the existing document and image routes. Those later conversions retain their own limits and page settings.

Text stays selectable where WebKit exports text. Charts use SVG and keep selectable labels. The checks cover inherited titles and body text, mixed fonts and colors, tables, a chart, cropped images, and rotated groups. WebKit rasterizes some transformed shapes. This is not a guarantee of complete PowerPoint layout fidelity.

## Current limits

Animations, slide transitions, speaker notes, embedded media playback, and active links are not retained in PDF. Full 3D effects, equations, all chart types, vector EMF/WMF pictures, advanced embedded fonts, and complete Office interoperability still need support and checks. Some unsupported images stop conversion. Full detection of unsupported content is also still in progress. The alternate office-engine setting is not implemented yet.

Missing internal package parts, invalid XML, XML entity declarations, excessive dimensions, unreadable pictures, and blocked network pictures fail before publication. Conversion keeps the original source and never overwrites an existing output. Document JavaScript is disabled. A private content world runs the bundled library. The document can load only its own supplied bytes and embedded image and font data.

Input files are limited to 64 MiB. ZIP parts are limited to 32 MiB each and 256 MiB in total. There can be at most 100,000 archive entries and 10,000 slides. Images are limited to 32 million pixels per frame and 128 million pixels in total. The slide canvas is limited to 32 million CSS pixels and 10,000 pixels per edge. Output is limited to 512 MiB. The helper has a 110-second deadline within the shared 120-second process limit.

The native reader validates package parts and stores them in a private directory. It gives WebKit a smaller ZIP without the media, then serves each needed picture or font by a generated numeric filename. Archive paths never become local filenames. Media paths use a consistent Unicode form. Empty unused parts are allowed.

The reader renders one slide at a time. It releases each slide's DOM, decoded media, and parsed shape list after writing the page. The private directory is removed when conversion ends. WebKit uses separate system processes. Their combined peak memory is not yet subject to an application heap quota.

## Measurements

Three warm runs of the packaged command give these medians. Each slide has text and a 1024-square noise image.

| Slides | Images | Input size | Time | Reported process RSS |
| --- | --- | --- | --- | --- |
| 1 | One image | 3.2 MB | 0.67 s | 88.3 MB |
| 12 | One shared image | 3.2 MB | 1.54 s | 93.0 MB |
| 12 | Twelve distinct images | 37.9 MB | 2.29 s | 129.3 MB |

Timing covers the complete conversion. These RSS figures exclude separate WebKit services and do not give total app memory. The workload and executable hashes are in `research/presentation-reader-performance.json`.

A separate diagnostic run sampled the command, its children, and newly started WebKit services. The largest observed sum was 493.7 MB for the twelve-image case. WebKit ownership was inferred from start time. Shared physical pages can be counted twice, pre-existing services are excluded, and sampling can miss short peaks. This is an estimate, not a hard memory limit. The full observations are in `research/presentation-process-memory.json`.

Before the private-media change, the same large-deck workload reported 163.6 MB of process RSS. Diagnostic samples varied: the earlier reader reached 617.6 MB, and earlier private-media samples reached 550.1 MB and 484.8 MB. These samples do not establish a precise total-memory reduction. Large-deck memory use remains an open optimization.

For the reverse route, see [PDF pages to slides](pdf.md). It creates one page picture per slide.

## Development checks

Run `python3 tools/build-native.py` on Apple Silicon with Xcode, Python 3.12 or later, Node.js, and npm. The script builds the static reader from pinned upstream source and retains the dependency notices and build hashes. These tools are needed only for development.

Run `tools/check-presentation-reader.py` with Python that has python-pptx, Pillow, pypdf, and pypdfium2. It generates an original two-slide deck and checks text, page dimensions, raster colors, vector charts, slide order, hidden slides, encoded and Unicode paths, empty unused parts, malformed parts, unsafe media indexes, links, network images, limits, source preservation, cleanup, and collisions. It also writes page previews for visual review. Add `--command /absolute/path/to/Allomer.app/Contents/MacOS/allomer` to check a packaged build. Add `--benchmark` to record three complete runs with one and twelve image-heavy slides, including shared and distinct pictures. Reported process RSS excludes separate WebKit services and is not aggregate app memory. Run `python3 tools/check-presentation-memory.py` afterward on a quiet Mac for the separate process sample.

Swift checks cover PDF-to-PPTX-to-PDF conversion, automatic extension changes, and exact Undo. A full Microsoft PowerPoint or Keynote application export comparison remains open.
