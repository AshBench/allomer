# PDF and PostScript

The current adapter converts PDF to PostScript or EPS, and PostScript or EPS to PDF. EPS and PostScript also connect through PDF. Automatic extension changes and manual conversion use the same adapter. Automatic conversion keeps the original for Undo.

PostScript output keeps all PDF pages and their visible crop bounds. EPS output uses one selected page. Page numbers start at one. An invalid page stops conversion before publication.

The PDF preset for PostScript and EPS input defaults to Prepress. Default, Screen, Ebook, Printer, and Prepress are available. Screen and Ebook reduce image resolution. These are Ghostscript presets; they can change compression, colors, and fonts. They are not archival or accessibility certification settings.

EPS cropping is on by default. It uses the source's bounding box. Turn it off to keep the interpreter's page size.

The output language level can be Level 2 or Level 3. Level 2 uses Ghostscript. Level 3 uses Poppler and can use Flate image compression. Its common linear, radial, and multi-stop gradients use native shading commands. EPS uses the selected language level too.

PDF pages with a `UserUnit` coordinate scale first pass through the existing PDF engine. This expresses their physical dimensions in PDF 1.5 coordinates before Level 3 export. The app checks their original drawing commands before normalization and verifies the resulting dimensions. Level 2 input also receives the drawing-command check. Ordinary Level 3 pages are checked during writing and skip the extra step.

PostScript has no native PDF transparency model. Transparent pages can become raster images. Level 3 flattens these pages at 300 DPI with antialiasing. Their appearance can remain intact while their text loses selectability. PDF Unicode mappings can also be lost in vector text. Glyphs can look correct while text copied from a resulting PDF differs. Links, forms, annotations, signatures, tags, and layers are not preserved as interactive PDF objects through PostScript. See [PDF pages and documents](pdf.md) for direct PDF rendering and editable document export. OCR and full document fidelity remain in development.

The native gradient patch handles exponential and stitched color functions. Other gradient functions retain the upstream rendering path. Some viewers can show seams between their small vector fills at low zoom. Complex gradients, unembedded fonts beyond the standard fourteen, and full color fidelity still need broader checks.

## Checks and limits

The app checks readable PDF pages, output headers, page counts, and visible page sizes where applicable. It reinterprets generated PostScript before publishing it. These checks detect broken output but do not prove full visual or text fidelity for every document.

The checks use original fixtures, a separate PDF renderer, and pypdf. They cover both language levels, Flate output, mixed page sizes, scaled and rotated crop boxes, transparency, EPS page selection, embedded TrueType fonts, JPEG and JPEG 2000 images, and gradients. Swift tests cover five PDF presets and four automatic conversions with exact Undo. Malformed PDF, encrypted PDF, invalid drawing commands, invalid pages, output collisions, and file access attempts must fail without replacing the source.

Input and each output file are limited to 512 MiB. PDFs are limited to 10,000 pages. Each helper invocation has a 120-second time limit. Ghostscript uses one rendering thread and 16 MiB display-list buffers. Poppler flattens transparent pages in strips of about 20 million pixels. These settings are not a hard limit on total memory.

The native launcher denies network access. It restricts file reads to the input, private work folder, bundled resources, and required system files. It restricts writes to the private work folder. It clears inherited tool settings and applies CPU and file-size limits. The native file boundary is also tested with Ghostscript's own file checks disabled.

## Development build

Run `python3 tools/build-postscript.py` on an Apple Silicon Mac with Xcode and Python 3.12 or later. The script verifies the official Ghostscript 10.07.1 source archive and builds its PDF, PostScript, and EPS writers. Fonts and startup resources are built into the executable. The app bundles it and the small original launcher. End users need no extra installation.

Also run `python3 tools/build-pdftops.py` with CMake installed for development. It builds only the Poppler 26.09.0 PostScript command. FreeType, libjpeg-turbo, Little CMS, and OpenJPEG are linked statically. Network support, GUI wrappers, and unrelated commands are disabled. The build reuses the existing FreeType and Ghostscript source pins. The app includes local character maps and fourteen fallback fonts. It needs no runtime downloads or Homebrew installation.

The build retains source, build instructions, and dependency notices under `.tools/pdf`. Ghostscript uses AGPL-3.0-or-later. Fonts and character maps retain their notices and stated exceptions. The source archive does not contain the optional JPEG XR component. Supply the complete matching source bundle with a distributed release.

The Level 3 source bundle is under `.tools/poppler`. It includes the two original Poppler source patches, their GPL-2.0-or-later notices, official source archives, build commands, resource hashes, and dependency notices. One patch loads local resources, checks drawing commands, and propagates errors. The other emits native Level 3 gradients. Source updates must apply both patches without skipped context and pass the content checks.

The command accepts `--postscript-options FILE.json`. For example, `{"languageLevel":3,"epsPage":2}` selects Level 3 and the second EPS page. Omitted settings retain their defaults. The same settings are available in the app.

`tools/check-postscript.py --renderer /absolute/path/to/pdftoppm` runs independent content checks. Its development Python needs reportlab, pypdf, and Pillow. Use `--command /absolute/path/to/Allomer.app/Contents/MacOS/allomer` to check a packaged build. These check tools are not part of the app runtime.

## Measured defaults

Three runs per original fixture were measured on an M2 Max with 32 GiB RAM. These include conversion and output validation. The previous default emitted Level 2; the current default emits Level 3. `tools/check-postscript-performance.py` reproduces the measurements. The reports retain input and executable hashes.

| PDF fixture | Previous median | Current median | Previous output | Current output |
| --- | --- | --- | --- | --- |
| 30 vector pages | 0.18 s | 0.10 s | 189,208 bytes | 42,301 bytes |
| 20 gradient pages | 0.29 s | 0.10 s | 1,668,078 bytes | 37,771 bytes |
| One transparent page | 3.60 s | 0.53 s | 1,024,537 bytes | 112,175 bytes |

Reported peak memory stays near 20 MB for the first two fixtures. The transparent page changes from about 20.2 to 42.9 MB. Its flattening resolution also changes from the previous writer's 720 DPI to 300 DPI. The results therefore compare defaults with different output choices. They do not isolate compression speed or prove equal quality. The current gradient fixture remains vector content; the previous writer rasterized its gradient. Memory is the peak reported by macOS `time -l`, not combined simultaneous process memory. The GUI is excluded.
