# Document conversion

Change a document's extension in a watched folder to convert it. Manual conversion uses the same engine. Automatic conversion keeps the original for Undo.

The document adapter reads binary Word DOC, plain text, Markdown, HTML, DOCX, ODT, EPUB, RTF, notebooks, LaTeX, man pages, MediaWiki, OPML, Org, reStructuredText, CSV, and TSV. It writes DOC, Markdown, HTML, DOCX, ODT, EPUB, RTF, notebooks, LaTeX, man pages, MediaWiki, OPML, Org, reStructuredText, AsciiDoc, plain text, and Typst. Table inputs also use the [spreadsheet adapter](spreadsheets.md).

These routes convert document content. They do not preserve every layout feature, formula, reference, comment, or attachment. Complex office documents still need more support and checks.

**Markdown flavor** applies when reading or writing Markdown. The default is GitHub. Other choices are CommonMark, CommonMark with extensions, Pandoc Markdown, MultiMarkdown, PHP Markdown Extra, and Original Markdown. These use the bundled document tool. A flavor can change how tables, links, and other markup are represented. For example, GitHub supports pipe tables; CommonMark can write tables as embedded HTML. The choice also applies when Markdown is an intermediate stage or is printed to PDF. Saved settings from older builds keep the GitHub default.

## Legacy Word input and output

Plain text converts directly to RTF or binary Word `.doc` through macOS AppKit. RTF also converts to DOC. Other documents reach DOC through RTF. Plain text can reach HTML, DOCX, PDF, and the other document writers through the same intermediate. Literal markup stays text. UTF-8, UTF-16, and UTF-32 fixtures pass.

Binary DOC imports directly to HTML, RTF, or UTF-8 text through the same native helper. The other current targets use the HTML result and existing conversion graph. Basic text, paragraph order, bold, italic, underline, and color pass. An independently sourced Word 97-SR2 file also retains its expected text. Automatic conversion keeps the original for exact Undo.

The DOC output has the binary Word compound-file container. The helper checks the generated Word text range against the source, including paragraph order. It rebuilds the container's sector table because the tested macOS writer omits entries in some larger files. Document streams stay intact. This repair applies only to the known native output layout. Unexpected layouts fail before publication. RTF output is reopened and checked through the native reader.

The container follows Microsoft's [MS-CFB specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/53989ce4-7b05-4f8d-829b-d08d6148375b). The text check uses the declared [Word text piece](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-doc/1caae71f-35c4-49d7-adf0-af5fc766331c). Development checks use Antiword and the pinned `cfb` crate's strict reader. They cover files with 1.525, 3.6, and 7.9 million text characters, plus 25,000 bold spans. Native checks cover Unicode, underline, and color too.

The tested macOS DOC reader cannot reopen the larger containers that need extended sector tables. Their container structure and text pass the independent readers. DOC import therefore covers ordinary files that AppKit can open; it does not promise every valid compound-file layout. Microsoft Word and macOS 14 runtime checks remain pending.

DOC import is a basic text-and-formatting path. Pictures, embedded objects, drawings, revisions, notes, headers, footers, text boxes, and hyperlink destinations are not qualified and can be omitted by the system importer. A detected attachment is refused. DOC output also refuses pictures, embedded data, notes, headers, footers, and hyperlinks because its writer cannot keep them. The source remains intact. Use DOCX, ODT, EPUB, or RTF input for the checked image and link paths.

Native input is limited to 64 MiB, eight million text characters, and 100,000 formatting runs. Output is limited to 512 MiB. The existing helper timeout, process limits, and file-access rules apply. This adds no helper or library to the app. `allomer formats` reports output writers; `no output writer` does not mean a format cannot be read.

## PDF output

HTML and Markdown print to PDF through WebKit supplied by macOS. DOCX prints to PDF in one direct stage; see [DOCX page layout](#docx-page-layout). ODT, RTF, EPUB, and the other supported documents can pass through HTML. That intermediate step reflows text and can change the original page layout. PowerPoint input and output remain in development.

PDF output keeps selectable text, links, tables, print backgrounds, and supported images. HTML print styles and explicit page breaks apply. Document scripts are disabled. System fonts and the macOS version can affect layout.

After printing, the bundled PDF helper rebuilds the file index. This removes unused entries left by the macOS print writer. Checked page content streams, image pixels, links, and metadata remain unchanged.

| Setting | Default | Behavior |
| --- | --- | --- |
| Page size | A4 | Choose A4 or US Letter for HTML and Markdown. Print margins are half an inch. DOCX uses its own page setup. |
| Markdown template | GitHub | Choose a sans-serif document style or Minimal / Print with serif body text. |
| Syntax highlighting | On | Color supported Markdown code blocks. |
| Complete document | On | Include the outer document structure for markup output. PDF output always prepares a complete document. |

The Markdown styles are original app styles. The template setting does not restyle an HTML source. Settings apply to automatic and manual conversion. The command currently uses the defaults.

## DOCX page layout

DOCX converts to PDF in one direct stage. It does not pass through HTML. The converter reads `w:sectPr` for the page width and height, the four page margins, and the header and footer distances. A landscape section records its own swapped width and height, so it needs no separate handling. A pinned local renderer lays the document out inside WebKit at that page size, and the result is printed at the same size. Every other DOCX route is unchanged: DOCX still converts to HTML, Markdown, RTF, ODT, and the remaining document targets through the bundled document tool.

The saved Document to PDF page size still applies to HTML and Markdown. It does not apply to DOCX, because the document's own page size wins. A section that leaves out `w:pgSz` falls back to Word's own default of US Letter with one-inch margins.

Original fixtures check the declared page size for a landscape section, asymmetric margins, a manual page break, run size and color, table width and column widths, table borders, cell shading, a custom style's font and color, paragraph spacing, an inline image at its declared size, an external hyperlink and its target, and a header and footer on every page.

Before anything is rendered, conversion refuses a document that mixes page sizes or margins between sections, uses multiple text columns, uses text boxes, uses floating images or shapes, uses fields such as page numbers in a header or footer, puts a link in a header or footer, declares more than one header or more than one footer, keeps its text under a part name this conversion does not read, refers to a part missing from the file, links an image from another location, or declares no usable page size. Two more are found while rendering: a header or footer the renderer cannot draw at all, and a header and footer that between them leave no room for the body text. A refusal leaves the source file unchanged and writes nothing.

A header or footer taller than the distance the page setup gives it pushes the body text down or up, the way Word does, rather than printing over it.

Links stay clickable, both to an address outside the document and to a bookmark inside it. A link inside a header or footer is refused rather than printed with nothing behind it. Comments and tracked changes are not drawn, which matches the route this replaces; a tracked change to the page setup is ignored, so the page prints at the setup currently in effect.

Conversion stays offline. Page JavaScript is disabled and the renderer runs as an injected script. The content security policy permits inline styles, data and blob images and fonts, and requests to the helper's own scheme. Nothing else loads. The sandbox, the 64 MiB input limit, the 512 MiB output limit, the 10,000-page limit, the 100,000-element limit, the 32-megapixel limit for one image, the 128-megapixel total, and the 192 MiB media limit are the same as the [presentation path](presentations.md).

## Images and local resources

Keep relative images, stylesheets, and fonts in the source folder or its subfolders. Escaped file names with spaces, percent signs, Unicode, and encoded extensions are supported. Image URL query strings and fragments do not change the file's recorded type. DOCX, ODT, EPUB, and RTF carry embedded images through the HTML intermediate step. DOCX to PDF carries them through its direct stage instead.

Missing images stop container output instead of being silently dropped. Referenced files outside the source folder, including symlink targets, are rejected. Each local file read by the document tool is limited to 64 MiB. The document tool is built without network fetching.

HTML printing also rejects missing or remote resources. Its local resource handler checks regular files, allowed types, size, image dimensions, and file changes. Remote links remain clickable in the PDF; following one is separate from conversion.

## Limits and checks

HTML and Markdown PDF input is limited to 64 MiB. HTML must be UTF-8 text without NUL bytes. Printing is limited to 100,000 document elements, 10,000 pages, and a 512 MiB output file. The renderer has a 110-second deadline. The parent also applies its shared timeout and cancellation.

HTML printing permits at most 1,023 distinct local assets. Each can use at most 64 MiB, with a combined limit of 512 MiB. Each local raster image is limited to 32 million pixels. Distinct local raster images have a combined limit of 128 million pixels. Embedded data URLs do not have that separate asset check. These checks do not cap all memory used by WebKit services.

The document adapters check container integrity and output structure before publication. The PDF checks verify page sizes and readable pages. These runtime checks do not prove full content fidelity.

Original fixtures check HTML and Markdown text, page breaks, A4 and Letter settings, links, tables, exact embedded image pixels, print backgrounds, automatic conversion, and Undo. Document bridge checks compare image pixels after DOCX, ODT, RTF, and EPUB intermediates. They also check the declared image type in each ZIP container. Basic text and table fixtures cover PDF output from the other current document input types. Poppler independently renders the printed PDF. A loopback server checks that blocked resources and document scripts send no requests.

## Development build

Use an Apple Silicon Mac, Xcode, and Python 3.12 or later:

```sh
python3 tools/setup-rust.py
python3 tools/build-rust.py carta
python3 tools/build-mupdf.py
python3 tools/build-native.py
swift build
```

The document build verifies a pinned official source archive. It applies the retained local-resource patch and collects dependency and syntax-grammar notices. It retains the source, patch, build script, and hashes under `.tools/carta`. The app bundles the resulting tool. End users need no compiler, tool download, or separate installation.

Run `tools/check-document-pdf.py --renderer /absolute/path/to/pdftoppm` with Python that has Pillow and pypdf. Add `--command /absolute/path/to/Allomer.app/Contents/MacOS/allomer` to check the packaged app. Add `--benchmark` for three warm HTML printing measurements after the content checks. These check tools and original fixtures are development files and are not bundled.

Run `python3 tools/check-word-pdf.py` with Python that has pypdf and pypdfium2. It converts the original DOCX fixtures and checks the printed page size, margins, page breaks, text size and color, tables, shading, fonts, spacing, images, external links, and headers and footers, then checks each refusal and that the refused source is unchanged. Add `--command /absolute/path/to/Allomer.app/Contents/MacOS/allomer` to check the packaged app.

Run `swift test --filter NativeDocumentTests` for native Word text, formatting, encodings, automatic conversion, exact Undo, known lossy-feature refusals, malformed input, and collisions. `python3 tools/check-native-doc.py --antiword /path/to/antiword` adds independent DOC reading and chained document checks. It needs Pillow. Add `--command` and `--tools` for a packaged app, and `--benchmark` for three complete conversions of an original 25,000-paragraph text file. Run measurements without other build or conversion jobs.

Run `python3 tools/check-doc-input.py` for all 43 current DOC-input outputs, one occupied destination, one malformed compound file, source preservation, and temporary-file cleanup. It creates a basic DOC through the bundled writer, then sends that file through every route. Pass `--command` and `--tools` to check a packaged app. This proves route integration for the checked basic document. It does not qualify the unsupported DOC features above.

`tools/check-doc-container.rs` uses the existing pinned `cfb` development library. Compile it with the pinned Rust compiler, `-O -C lto=fat -C embed-bitcode=yes`, the built `libcfb-*.rlib` as `--extern cfb=…`, and the mail helper's release dependency folder as `-L dependency=…`. Pass the resulting command as `--cfb-check` to add strict container checks. This development command is not bundled.

The development check used Antiword 0.37 with Debian's 0.37-18 patches. The source and patch hashes are listed in the [Debian source record](https://deb.debian.org/debian/pool/main/a/antiword/antiword_0.37-18.dsc). Antiword is not shipped and end users do not need it. Its normal UTF-8 text and DocBook outputs read the checked DOC files. The native check supplies the broader Unicode and color comparisons.

The 25,000-paragraph TXT-to-DOC workload takes a median 0.22 seconds across three packaged runs. Median per-process peak RSS is 40,681,472 bytes. Each output is 3,091,968 bytes and passes the independent readers. This includes native input reading, DOC writing, declared text checks, container rebuilding, and publication. Source hashing warms the file cache. Python, independent readers, and GUI memory are excluded. RSS is not aggregate simultaneous memory. `research/native-doc-performance.json` records the samples and hashes. The original native container failed this same workload; that failed attempt is recorded separately.

The checked two-page HTML prints in a median 0.39 seconds. Median peak helper RSS is 70,680,576 bytes. These figures exclude separate WebKit services, the native app, Swift adapter checks, and PDF index rebuilding. They are not total conversion memory or time. `research/document-pdf-performance.json` records the workload, assets, helper hashes, and all three samples.
