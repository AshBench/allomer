# PDF pages and documents

PDF conversion uses the same settings for automatic extension changes and manual conversion. Automatic conversion keeps the original for Undo.

## Pages and resolution

PNG and SVG output use one selected page. The default is page 1. Raster output accepts 72–1200 DPI and defaults to 300 DPI. SVG keeps vector shapes and does not use a raster resolution setting. Text in SVG is drawn as outlines. It keeps its appearance without requiring the original fonts, but it is not editable text.

PNG connects PDF pages to the native image outputs, including JPEG, TIFF, BMP, GIF, HEIC, and AVIF. This PDF route writes one selected frame. It does not convert a whole PDF into a multipage image or animation. The separate [TIFF image path](images.md) can preserve all TIFF pages in TIFF or PDF output.

DOCX, HTML, and PPTX export use the document page selection. The default is `all`. Enter pages and ranges such as `1-3,5`. Page numbers start at one. Repeated pages are included once, in the order first requested. Missing pages and invalid ranges stop conversion before saving.

## PowerPoint slides

PPTX output places one PDF page image on each slide. Slides have their own resolution setting. It defaults to 144 DPI, which matches the two-times page scale the slide geometry is measured against, and accepts the same 72–1200 DPI range. The page image includes its visible text, graphics, and transparency flattened onto white. Text and links are part of the image; they are not editable text or active links.

The first selected page sets the slide size. Other pages fit in that canvas without changing their proportions. White margins fill unused space. Crop bounds, page rotation, and the PDF coordinate scale apply to rendered pages. Slide edges stay within PowerPoint's one-to-56-inch range. Large canvases scale down; small edges gain white margins.

The original writer uses the bundled PDF renderer and macOS ZIP library. It renders and archives one page at a time, then removes the private image. File reads reuse one 64 KiB buffer. Temporary Foundation and image-reader objects are released after each part. PNG members are stored without a second compression pass. Every stored part is read back and checked against its streamed hash before publication. No extra app or download is needed. For PPTX input to PDF, see [presentations](presentations.md).

## Editable documents

DOCX export keeps text, basic formatting, detected tables, and supported embedded images. An original patch to the upstream writer fixes repeated images, images from earlier pages, image orientation, displayed image size, and invisible OCR text. The patch is retained with its source build.

HTML export embeds image data and preserves selectable text. HTML also connects PDF to Markdown and other document formats. Markdown output can contain HTML page wrappers and embedded image links.

Turn on **Recognize scanned PDF text** to extract text from selected scanned pages. It is off by default. Pages with existing selectable text are skipped. Recognition adds an invisible text layer to a private PDF copy before document export. See [text recognition](ocr.md) for its limits and checks.

These outputs reconstruct a document from positioned PDF content. They are not a copy of the original page layout. Complex columns, vector diagrams, clipping, blend effects, annotations, reading order, and accessibility tags still need complete support and checks. DOCX images can move into the text flow. Full document layout fidelity remains in development.

## Checks and limits

Before saving, the adapter validates the output container and document XML. It compares readable source characters with exported text. That count check detects missing text. It does not prove reading order, style, or layout fidelity. PNG headers and dimensions are checked. SVG receives a namespace and XML check.

The independent development check verifies Unicode text, a three-row table, bold text, repeated and rotated image pixels, and image display sizes. It compares PNG output with Poppler. It compares native macOS SVG rendering with an independent PDF render. It also checks six image routes, malformed and encrypted inputs, source preservation, and temporary-file cleanup. Swift checks cover page selection, 1200 DPI A4 output, seven automatic conversions, and exact Undo.

The presentation check reads the generated deck with python-pptx and compares all four embedded page images with PDFium. It checks crop bounds, rotation, coordinate scales, transparency, image placement, package relationships, and canvas limits. Swift checks also cover ordered slide selection and removal of a partial ZIP after cancellation. macOS Quick Look renders the first slide. A full PowerPoint or Keynote editing and export check is still open.

An image-heavy A4 benchmark takes median 0.19 seconds for one slide and 1.79 seconds for twelve slides at 144 DPI. The reported peak resident size is 20.8 MB and 21.2 MB, respectively. These are three warm runs of the packaged command. Timing includes rendering, ZIP writing, checks, and publication. Memory comes from macOS `time -l`; it is not the sum of parent and helper memory and excludes the GUI. `research/presentation-performance.json` records the workloads and executable hashes. Run the presentation check with `--benchmark` and a packaged `--command` to repeat it.

Inputs and individual output files are limited to 512 MiB. The combined uncompressed PPTX parts also have a 512 MiB limit. PDFs are limited to 10,000 pages. Raster pages are limited to 256 million pixels and 100,000 pixels on either edge. An A4 page at 1200 DPI fits this limit. The DOCX image writer limits each decoded or transformed image to 128 million pixels.

PNG rendering uses 128-row bands and one worker. Draw commands have a 256 MiB internal allocation limit. This is not a limit on total process memory. The DOCX writer has no hard heap quota yet. The shared process runner enforces cancellation and a 120-second time limit.

An original A4 benchmark with text, vector shapes, and a 1024-square image takes a median 0.10 seconds at 144 DPI. The renderer's median peak RSS is 10,010,624 bytes. At 1200 DPI, it takes 1.93 seconds with 17,743,872 bytes peak RSS. Each figure uses three runs on the development Mac after other checks finished. These measurements cover the renderer process only. They exclude the native app, Swift validation, and later image conversion. `tools/check-pdf-performance.py` reproduces the workload. `research/pdf-performance.json` records every sample and the packaged helper hashes.

The native launcher clears inherited tool settings. It denies network use and restricts reads to the input, private work folder, and required runtime files. It permits writes only in the private work folder. It also applies CPU and file-size limits.

## Development build

Run `python3 tools/build-mupdf.py` on an Apple Silicon Mac with Xcode and Python 3.12 or later. The script builds pinned official MuPDF 1.28.3 sources, including its document writer and fallback fonts. JavaScript, network fetching, GUI tools, and Tesseract are disabled. The app bundles the executable and its small native launcher. End users need no extra tool installation.

The matching source archive, original patches, text-layer command, launcher source, build instructions, and upstream notices are retained under `.tools/mupdf`. MuPDF and the patched writer use AGPL-3.0-or-later. The original text-layer command source uses MIT; the combined executable uses AGPL-3.0-or-later. Third-party libraries and fonts retain their own notices. Supply the matching source bundle with a distributed release.

Run `tools/check-pdf.py --renderer /absolute/path/to/pdftoppm` with Python that has reportlab, pypdf, and Pillow. The SVG check uses the Xcode Swift command and macOS AppKit. Add `--command /absolute/path/to/Allomer.app/Contents/MacOS/allomer` to check a packaged build. These development check tools are not bundled in the app.

Run `tools/check-presentation.py` with Python that also has python-pptx and pypdfium2. It accepts the same `--command` option.
