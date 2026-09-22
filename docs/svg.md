# SVG conversion

Change `.svg` or `.svgz` to `.png` or `.pdf` in a watched folder. The app renders the artwork locally. Manual conversion uses the same engine. Automatic conversion keeps the original for Undo.

SVGZ is a GZIP-compressed SVG. Conversion between SVG and SVGZ keeps the decompressed SVG bytes unchanged. PNG also connects SVG input to the supported image outputs, such as JPEG, TIFF, BMP, GIF, HEIC, and AVIF.

[Bitmap tracing](tracing.md) converts still images to SVG paths. It has separate presets and advanced controls. The size controls below apply when rendering an existing SVG.

## Size settings

**SVG size** applies to automatic and manual rendering.

| Setting | Default | Behavior |
| --- | --- | --- |
| Width | 0 | Use the original width unless a height sets the size. |
| Height | 0 | Use the original height unless a width sets the size. |
| Scale | 1 | Multiply both original dimensions when width and height are zero. |

One explicit dimension keeps the original aspect ratio. Two explicit dimensions stretch the artwork to that size. An explicit width or height makes scale inactive. PNG dimensions round to whole pixels. PDF dimensions retain fractional values. Each SVG pixel becomes one PDF point before scaling.

These settings do not change SVG or SVGZ bytes during compression or decompression.

## Artwork and local resources

Rendering uses WebKit supplied by macOS. Checked artwork retains styled text, gradients, clipping, patterns, dashed paths, filters, transparency, and local images. PDF keeps selectable text and vector drawing where WebKit supports them. Filters can create bitmap regions.

Keep relative images, stylesheets, and fonts in the SVG's folder or its subfolders. Supported local resources include PNG, JPEG, GIF, WebP, AVIF, SVG, CSS, TTF, OTF, WOFF, and WOFF2. Paths with spaces, percent signs, and Unicode are supported. Files outside that folder, including symlink targets, are rejected. Missing resources stop conversion.

Document scripts are disabled. Remote resources are blocked. CSS and SVG animations are paused at time zero before rendering. Embedded animated images and complex SVG features need more fidelity checks. Installed system fonts and macOS versions can affect the result.

PDF export redraws the rendered page. It does not preserve PDF link annotations or all SVG metadata. Full SVG feature coverage is still in development.

## Limits and checks

SVG input is limited to 64 MiB. Compressed SVGZ input is limited to 65 MiB and must expand to no more than 64 MiB. The main SVG must have a valid namespace, no more than 100,000 XML elements, and depth at most 256.

Both the original canvas and the requested output are limited to 32 million pixels. Neither edge can exceed 100,000 pixels. There can be at most 1,023 separate local assets, each up to 64 MiB, with a combined limit of 512 MiB. Each local raster asset must fit the same pixel limits. Distinct local raster assets have a combined limit of 128 million pixels. Embedded data URLs are handled by WebKit and do not have that separate asset check.

The helper has a 110-second render deadline. The parent applies its shared 120-second timeout and cancellation. File sizes and image dimensions are bounded. These limits are not a hard cap on all memory used by WebKit services.

The helper's process profile restricts file access and denies network access. WebKit's separate system services do not inherit that profile. A content policy, a local resource handler, disabled document scripts, and navigation checks control document access in those services. A loopback network probe checks that remote resources and document scripts send no requests.

Original fixtures check artwork, selectable PDF text, unchanged bitmap pixels, transparent backgrounds, real artwork scaling, local resources, exact SVGZ round trips, automatic conversion, and Undo. An independent Poppler render is compared with the PNG result. Invalid XML, oversized canvases, missing resources, folder escapes, and damaged GZIP input fail without publishing an output.

## Development build

Run `python3 tools/build-native.py` on an Apple Silicon Mac with Xcode. The build creates the original `webconvert` helper and `webguard` launcher. Both use macOS libraries only. The app bundles both executables. End users need no extra tool installation.

Run `tools/check-svg.py --renderer /absolute/path/to/pdftoppm` with Python that has Pillow and pypdf. Add `--command /absolute/path/to/Allomer.app/Contents/MacOS/allomer` to check the packaged app. The check tools and generated fixtures are development files and are not bundled.

Add `--benchmark` for three warm runs after the content checks. The checked 640 by 400 artwork takes median 0.29 seconds for PDF and 0.39 seconds for a 2560 by 1600 PNG. Median peak helper RSS is 64,749,568 and 104,857,600 bytes, respectively. These figures exclude separate WebKit services, the app, and Swift adapter checks. They are not total conversion memory. `research/svg-performance.json` records the source, asset and helper hashes, samples, and measurement scope.
