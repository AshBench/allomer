# Text recognition

Change a single image's extension to `.txt`, `.md`, or `.docx` in a watched folder to recognize its text. Manual conversion uses the same path. Automatic conversion keeps the original for Undo.

TXT output contains recognized lines. HTML output connects to Markdown, DOCX, and other document formats. This path extracts text. It does not copy the image's page layout, table structure, or illustrations into the text document.

For PDF output, turn on **Make image text searchable**. The setting is off by default. The PDF keeps the image and adds an invisible text layer over recognized lines. The text can be searched and selected. The page size uses the image's pixel dimensions and recorded DPI, with 72 DPI as the fallback. EXIF orientation determines the displayed rotation and mirroring.

Searchable PDFs use the same image writer as ordinary image PDFs. Quality, metadata retention, and sRGB settings reach that writer. Recognition reads the source image before any lossy output encoding. The PDF helper then adds only the invisible text layer. It keeps the encoded image and its color profile intact. Private image and text-layer PDFs are removed after conversion.

Recognition uses [Apple Vision](https://developer.apple.com/documentation/vision/recognizing-text-in-images) on the Mac. It uses accurate recognition and language correction. **Text language** defaults to **Automatic**. Choose a specific language when you know the source language. The menu lists languages supported by this Mac. This saved choice applies to image recognition and scanned PDF pages, in both automatic and manual conversion. An unavailable saved language stops OCR instead of silently changing the choice.

Apple supplies the recognition models through macOS. No OCR service is called by the app. Reading errors remain possible. Check names, numbers, and unfamiliar text before relying on the result. Available languages and recognition quality depend on macOS.

A blank image can become a PDF without selectable text. A text-only conversion fails when no readable text is found. It leaves the source intact.

## Scanned PDFs

Turn on **Recognize scanned PDF text** to use OCR when converting PDF pages to DOCX, HTML, Markdown, or connected document formats. This setting is off by default. The document page selection applies. Pages that already have selectable text are skipped. A page with some selectable text is skipped even if it also contains scanned text.

Each selected scanned page is rendered for recognition. The helper adds its recognized text to a private copy of the PDF. It retains the existing page content and image streams. The text layer is invisible. The document writer then uses that text when it builds the output. The private copy is removed after conversion. The source PDF stays intact.

The layer keeps text selection near the printed lines. It does not identify editable tables or recover the original document's layout. A blank scanned page can produce no text. The private PDF rewrite is not a signature-preservation feature. This path does not publish a replacement searchable PDF.

## Checks and limits

The image path accepts one image up to 32 million pixels and 512 MiB. Neither edge can exceed 100,000 pixels. It rejects animation and multipage images. The PDF path accepts unencrypted PDFs up to 512 MiB and 10,000 pages. It renders one page at a time, at up to 300 DPI. Large pages use a lower resolution to keep the render buffer below 32 million pixels. This can reduce recognition quality. Recognized text is limited to 100,000 lines and 16 MiB per page or image. Each helper stage has a 120-second time limit and supports cancellation through the parent process.

The PDF writer checks the recognized characters after reading the result back. This confirms that the text layer contains the recognition result. It does not confirm that OCR read the source correctly. The normal document and file checks run before publication.

The process profile denies network access and restricts file reads. It allows the input, private work folder, executable directory entry, and required runtime files. Metal uses its system graphics cache under the current user's Darwin cache directory. On current macOS, Vision also compiles system recognition models into `Library/Caches/nativeconvert`. The profile permits only these framework caches, while unrelated file contents remain blocked. It clears inherited tool settings and applies CPU and file-size limits. The first recognition after an app or macOS update can take longer while macOS rebuilds that private cache. No recognition model is shipped in the app.

Original fixtures check readable lines, searchable text positions, automatic routes with exact Undo, output collisions, misleading input extensions, and denial of unrelated file access. The app check covers all eight EXIF orientations, physical page size, quality changes, Display P3-to-sRGB conversion, image and profile stream preservation, failure cleanup, and unchanged sources. The independent packaged check also covers all eight orientations through the image writer and text-layer merger. It compares embedded image bytes and renders the resulting PDFs with Poppler. Scanned PDF checks compare visible pixels and original image streams. They cover selectable and blank pages, fields, links, outlines, metadata, all four page rotations, crop bounds, and scaled PDF page units. PDFium checks text positions. Language checks cover Automatic, explicit English, unsupported choices, and saved settings. OCR accuracy on complex scripts, handwriting, damaged scans, and unusual image profiles still needs broader coverage.

The standalone helper took a median 0.34 seconds to recognize a 1000 by 480 image and write a searchable PDF. Median peak helper RSS was 66,174,976 bytes. These are three earlier warm runs after content checks. They include the helper's PDF text check. They exclude the app, separate system services, and the image-encoding and text-layer merge stages now used by the app. `research/ocr-performance.json` records every sample and the measured helper hashes.

A seven-page PDF with five scanned pages, one selectable page, and one blank page takes a median 1.05 seconds through recognition, text-layer merge, and Word export. Median peak helper RSS is 210,731,008 bytes. Recognition takes most of the time and memory. Each stage runs in sequence. This measurement uses the largest stage's peak; it is not total app memory. It excludes Swift adapter checks and separate macOS services. `research/pdf-ocr-performance.json` records all three warm runs, stage timings, and packaged helper hashes. Add `--benchmark` to the independent check to repeat both OCR measurements.

## Development build

Run `python3 tools/build-native.py` on an Apple Silicon Mac with Xcode. The small original helper uses only macOS frameworks. The build retains source hashes and instructions under `.tools/native`. The app bundles the helper and launcher. End users need no additional converter installation.

Run `tools/check-ocr.py --renderer /absolute/path/to/pdftoppm` with Python that has Pillow, pypdf, reportlab, and pypdfium2. Add `--command /absolute/path/to/Allomer.app/Contents/MacOS/allomer` to check a packaged build. These independent check tools are not app dependencies.
