---
title: Project status
description: Implemented formats, measured behavior, open checks, and release requirements.
---

# Project status

Allomer is an open source file converter for Apple Silicon Macs from AshBench. It is in early development and is not ready for production use.

The app converts file contents when you change a file's extension. It runs locally, keeps recoverable originals, and provides conversion settings in a native menu app. The target catalog contains 115 formats.

The released app must include every required converter. Installing the app must be enough to use all supported formats. Users must not need Homebrew, a separate converter download, or a network connection for conversion. The tool setup below is only for development while that bundle is being built.

## What works now

The native app opens on its Automatic tab. Add a watched folder, then change a file's extension in Finder. Subfolders are included. You can exclude folders and pause or resume monitoring from the window or menu bar. Folder choices and conversion settings persist across app launches. Manual conversion is a separate tab.

General settings include launch at login and optional conversion notifications. Both use native macOS services. Permission is requested only when notifications are enabled by the user. See [login and notifications](automatic.md#login-and-notifications) for behavior and pending runtime checks.

An optional setting checks new arrivals whose contents do not match their extensions. It uses the existing actions, format rules, and Undo. It is off by default. See [new files](automatic.md#new-files-with-the-wrong-extension) for detection limits and original-file behavior.

Monitoring can use selected folders or the whole system. A separate system/cache filter applies to both modes. Whole-system mode checks protected-folder access before enabling. See [monitoring scope](automatic.md#monitoring-scope) for excluded paths and pending runtime checks.

Choose **Convert immediately**, **Ask first**, or **Do not convert** after an extension change. Pending decisions appear on the Automatic tab and can be opened from the menu bar. Skipping leaves the new name and existing contents unchanged. See [automatic conversion](automatic.md) for approval, pause, and Undo behavior.

Format-pair rules can override the default action. Each pair can use global settings or save its own conversion options. A pending conversion's settings sheet also has **Remember settings for this pair**. These edits keep the global defaults unchanged. An original-file choice can keep a visible copy at the old name. It has default, pair, and one-time controls.

The watcher groups file events by filesystem identity and waits for the file to settle. Conversions run away from the UI, with a limit on simultaneous jobs. Idle monitoring uses filesystem events instead of scanning folders. Conversion-generated file changes do not start another conversion.

Automatic conversion takes a stable snapshot before conversion. On APFS, the snapshot uses a file clone. It checks that the live file still matches that snapshot before exchanging it with the output. Filesystem metadata, such as permissions and tags, is copied to the output. The original inode remains in a private recovery folder beside the converted file. History provides Undo. Undo refuses to discard later content changes or overwrite an occupied original filename. If a visible original was kept, Undo leaves it in place and removes the unchanged converted result from the folder.

Backup settings can expire recovery data by age or total size. Both limits are off by default. Clear All Backups requires confirmation. Cleanup waits for active work and preserves live files and history. Removed backups can no longer be used for Undo. See [backup limits](automatic.md#backup-limits-and-cleanup).

[History controls](automatic.md#search-and-manage-history) include search, status filters, individual job cancellation, conversion stages and their recorded settings, and clearing finished entries. Clearing preserves files and backups. Active work and recovery that needs review stay visible.

[Stage settings](automatic.md#settings-for-individual-stages) override the options for one stage in a route. Manual conversion, saved rules, and pending approvals use the same editor.

Pending approvals use the detected source format to show conversion options. A PDF renamed to PNG keeps its PDF page controls. SVG sizing, PostScript settings, and image tracing also follow the detected source. [Markdown flavors](documents.md) are saved with the document settings. [Searchable image PDFs](ocr.md) use the same quality and color settings as ordinary image PDFs.

The journal can recognize completed conversions and completed undo operations after a restart. Ambiguous interrupted operations keep their files and appear as needing review. Full automatic recovery for every interruption point is still in development.

The command-line engine converts single-frame images through macOS ImageIO. Multipage TIFF files convert directly to TIFF or PDF with all pages preserved. Tests cover misleading extensions, real JPEG output, all eight TIFF orientations, page dimensions, image PDF appearance, and exact Undo. The engine checks the encoded format and dimensions. It refuses to overwrite existing files and leaves the source unchanged. See [images and TIFF pages](images.md).

Animated GIF, WebP, and PNG inputs convert to GIF or WebP with frame timing, orientation, and repeat counts preserved within each format's limits. An optional [frame rate and total plays](animation.md#animated-image-input) resample that timing instead. The same routes work through automatic conversion and Undo. See [animated GIF output](animation.md) and [WebP output](webp.md) for color limits and performance.

Video inputs also convert to GIF or WebP. Settings control sampling rate, maximum width, total plays, GIF palette size, and dithering. WebP uses the shared compression settings. Tests cover all thirteen generated video containers and exact Undo. See [video animation](animation.md#video-input) for timing, color, and resource limits.

Still images and animations also convert to 13 video containers through a private GIF intermediate. The route applies orientation, retains one animation sequence, and composites transparency over black. See [images to video](image-video.md) for timing, padding, and color limits.

Still images also convert to [JPEG XL](jpegxl.md), with lossy or lossless encoding, metadata controls, and native color preparation. The automatic route supports exact Undo.

The document adapter builds official upstream carta source for markup and office-text documents. Basic binary DOC input uses the native macOS reader, then reaches every current target through HTML. Generated Markdown passes all 16 current document output formats. A DOCX check uses Apple's independent reader. A DOCX-to-HTML check verifies Unicode text and bold formatting. Another check converts a renamed Markdown file into DOCX and compares the embedded image bytes with the local image. HTML and Markdown print to PDF with macOS WebKit, and DOCX prints to PDF in one direct stage at its own page size. See [document conversion](documents.md) for settings, embedded images, and DOC limits.

The runtime checks ZIP integrity and the expected XML root for DOCX, ODT, and EPUB. XML validation uses a stream and disables external entity resolution. The largest checked XML part is limited to 512 MiB. Other outputs receive text, notebook, RTF, or OPML checks as applicable. These checks do not prove complete document fidelity. Complex layout, formulas, references, and attachments need more fixtures.

The media adapter uses FFmpeg. Generated two-second fixtures pass all 17 audio and 13 video output formats. Each result is decoded in the test. A FLAC round trip also preserves the input's decoded audio samples exactly. These tests do not cover every input combination or all codec settings.

Audio inputs also convert directly to ten video containers without adding a picture track. [Audio-only container output](audio.md#audio-in-video-containers) uses the audio settings and retains the original for Undo.

AV1 input uses bundled software decoding on Macs without AV1 hardware support. Original 8-bit and 10-bit clips pass checks in MKV, MP4, and WebM. See [video conversion](video.md) for codec selection, quality and bitrate, ProRes profiles, frame rates, and timing limits.

Video conversion checks decoded audio and picture timing. AVI and MXF use silence and black frames where their track layout needs padding. Original flash/tone tests cover delayed tracks, unequal lengths, gaps, and shifted timestamp origins across all 13 video outputs.

Audio extraction starts at the first audio sample and preserves timestamp pauses as silence. It checks decoded duration without using the video track's length. WMA and WMV preserve the checked opening sounds through encoder padding. See [audio timing](audio.md#extraction-and-timing) for codec delays, declared-length checks, short Vorbis input, and chained-stream limits.

H.264 output uses Apple's VideoToolbox encoder with hardware acceleration enabled and software fallback allowed. A local Apple M2 Max check also passed with software fallback disabled. This confirms hardware encoder availability for that fixture. It does not measure speed or GPU use. Other converters use native frameworks or CPU codecs according to their format.

The media path checks the container, codec, stream count, decoded duration, video dimensions, audio channel count, and requested sample rate before saving. It accepts one audio track and one video track. Embedded cover art has separate retention controls. Files with additional media tracks, subtitles, or unrelated attachments still need selection controls. See [audio conversion](audio.md). Video supports codec-specific higher bit depths and ProRes alpha. HDR, full metadata fidelity, and audio bit-depth controls still need further work.

Every pair in the current 3,474-route target list is connected. This does not prove every file variant, advanced option, or complex document and media feature. Multipage support currently covers TIFF-to-TIFF and TIFF-to-PDF.

The [subtitle adapter](subtitles.md) covers SRT, WebVTT, ASS, SSA, SBV, and MicroDVD. It also extracts a selected embedded text track from video. Checks cover all 36 text-file pairs and 36 extraction cases across MP4, MOV, 3GP, Matroska, and WebM fixtures. They compare cue text and timing, including supported overlaps, multiple lines, punctuation, and Unicode. Direct ASS output retains the checked styles and overrides. Picture-subtitle extraction uses the shared media libraries and Apple Vision. Captions inside video frames and full styled-subtitle fidelity still need work.

MicroDVD output includes its frame rate. A source without a frame-rate header requires a source rate in Settings. The current output rate range is 4–99 frames per second. Frame-based outputs can round timing by one frame. ASS and SSA use hundredths of a second. Basic formatting must be explicitly removed before writing the current SBV or MicroDVD output path.

The configuration adapter covers JSON, YAML, TOML, plist, and XML. A shared fixture passes all 25 input and output pairs. It keeps quoted strings and large integers distinct from booleans and decimals. Output is parsed and compared before saving. See [configuration settings and limits](configuration.md), including the XML mapping and types that cannot yet be converted.

The archive adapter covers ZIP, TAR, compressed TAR, GZIP, and 7z. A single-file fixture passes all 25 pairs. File data is streamed and hashed, then checked in the completed archive. See [archive settings and limits](archives.md).

The spreadsheet adapter reads XLS, XLSX, CSV, and TSV. It writes XLSX, CSV, TSV, and JSON records. JSON and simple XML tables can become delimited text. Checks compare converted cells before saving. Settings select the sheet, CSV delimiter, XML header row, and table type inference. See [spreadsheet behavior and limits](spreadsheets.md).

The engine connects implemented converters when a table or configuration file needs intermediate formats. For example, XLS-to-DOCX uses TSV, and YAML-to-DOCX uses JSON and TSV. Direct conversions take priority. Each stage writes and validates a private temporary file. Only the final output is published. A failed stage leaves the original intact and removes intermediate files. Automatic conversion uses the same route and retains one original for Undo. A route does not guarantee that every possible input structure can be represented by its destination.

## Build and run

Use an Apple Silicon Mac with macOS 14 or later and Xcode installed.

```sh
swift test
swift run allomer convert input.png output.jpg
swift run allomer formats
```

The destination must not already exist. The command does not rename, replace, watch, or delete the source. Image processing uses local macOS frameworks and bundled codecs.

For the document adapter:

```sh
python3 tools/setup-rust.py
python3 tools/build-rust.py carta
swift run allomer convert document.md document.docx
```

The build verifies the official carta 0.0.10 source archive. A retained patch decodes local resource URLs and prevents silent image loss in container output. Network fetching is disabled at build time. Relative document resources resolve from the source folder. The source is preserved. The process has a time limit and an error-log limit.

The default development tool directory is `.tools/bin` under the current working directory. `ALLOMER_TOOLS_DIR` can point to another absolute directory. No tools are fetched automatically during conversion.

The command chooses one tool directory at startup and refuses to run when it is incomplete, rather than trying the next one. A command inside the app reads only that app's `Contents/Helpers` and ignores `ALLOMER_TOOLS_DIR`, complete or not, so a damaged install reports missing tools instead of borrowing a complete directory from elsewhere on the machine. `ALLOMER_TOOLS_DIR` and the development directory apply only to a command outside an app bundle, and each is refused by name when it is incomplete.

The media source build has passed all 30 output tests. Build it with Python 3.12 or later, Xcode, CMake, and pkg-config:

```sh
python3 tools/build-media.py
ln -s ../media/bin/ffmpeg .tools/bin/ffmpeg
ln -s ../media/bin/ffprobe .tools/bin/ffprobe
```

These commands assume those development links do not already exist. The build pins upstream source hashes and retains source archives, build commands, and license files under `.tools/media/`. Both executables target macOS 14 on ARM64. FFmpeg and FFprobe share bundled libraries instead of each containing the same media engine. Their dynamic dependencies resolve to those bundled libraries or macOS. Their only file protocols are `file` and `pipe`. The app includes the libraries under `Contents/Frameworks/Media`; users need no separate media installation.

Create and check the local app preview:

```sh
python3 tools/setup-rust.py
python3 tools/build-rust.py tabular
python3 tools/build-rust.py mailfile
python3 tools/build-rust.py vectortrace
python3 tools/build-ebook.py
python3 tools/build-fonts.py
python3 tools/build-models.py
python3 tools/build-postscript.py
python3 tools/build-pdftops.py
python3 tools/build-mupdf.py
python3 tools/build-webp.py
python3 tools/build-jpegxl.py
python3 tools/build-native.py
python3 tools/build-app.py
python3 tools/check-app.py
python3 tools/build-dmg.py
open dist/preview/Allomer.app
```

The preview includes the native app, a command, and 29 helper executables. It uses an ad hoc signature for local testing. Release signing, notarization, and a clean macOS 14 installation check are still required. The credential-neutral release tooling is documented in [Cutting a release](release.md). The package check runs outside the project with only the standard system command path. It checks images including JPEG XL and animated GIF and WebP, DOCX, DOC, OGG, subtitle conversion and extraction, configuration files, archives, spreadsheets, ebooks, fonts, email, models, PostScript, PDF, image text recognition, SVG, and SVGZ. It also checks bundled license notices.

The development folder is much larger than the installed app. Compiler output, dependency source, test fixtures, and documentation tools are excluded from the app bundle. Required license notices are included. Matching dependency source bundles must accompany a distributed release where their licenses require them; users do not need those sources to run conversions. See [app size](size.md) for the main costs and measurement steps.

The preview contains about 149.1 MB of app files and compresses to about 80.0 MB in an HFS+ DMG with UDZO compression. The Level 3 PostScript writer, fonts, character maps, and notices add about 19.1 MB to the app and 8.1 MB to the installer. Other changes shared media libraries and Rust notices, reduced the document tool, and removed unused font-converter code. A copied app passes conversion checks outside the project with only system commands on its path. `research/package-size.json` records the exact sizes and image hash. See [App size](size.md) for the current measurements. This preview is incomplete, so the final release size can change.

SVG and SVGZ render to PNG and PDF through macOS WebKit. Saved width, height, and scale settings apply to the artwork. Local images, stylesheets, and fonts can remain beside the source. Compression and decompression preserve the SVG bytes. See [SVG conversion](svg.md) for checks and resource limits.

The ebook adapter reads unencrypted MOBI, AZW, and AZW3 and writes EPUB. It also connects these inputs to document outputs through EPUB. See [ebook conversion](ebooks.md) for content checks and limits.

The font adapter converts TTF, OTF, WOFF, and WOFF2. Native checks compare character coverage, names, spacing, and outline bounds. See [font conversion](fonts.md) for current content limits.

The email adapter covers EML, EMLX, MSG, and HTML, with document routes through HTML. It preserves message text, headers, and file attachments on checked inputs. See [email conversion](email.md) for the header setting, rich-text handling, and current limits.

The model adapter covers 3DS, DAE, FBX, GLB, glTF, OBJ, PLY, STL, USDA, USDC, and USDZ inputs. It writes FBX, GLB, PLY, STL, and USDZ on supported routes. Binary PLY/STL and texture settings apply to automatic and manual conversion. Separate textures stay beside the output and participate in Undo. See [3D model conversion](models.md).

The PostScript adapter converts PDF to PS/EPS and PS/EPS to PDF. Page selection, EPS crop bounds, and PDF presets apply to automatic and manual conversion. See [PDF and PostScript](postscript.md) for checks and content limits.

The PDF adapter renders one selected page to PNG or SVG. PNG connects to other image outputs. Selected pages become PowerPoint slides with one page image per slide. Selected document pages become editable DOCX or HTML, with Markdown and other document routes through HTML. Optional local OCR adds text from scanned pages. Saved page, resolution, and OCR settings apply to automatic and manual conversion. See [PDF pages and documents](pdf.md). PowerPoint input now converts to PDF through local WebKit. See [presentations](presentations.md) for its scope. Full layout fidelity for these PDF-to-document routes remains in development.

Image text recognition uses Apple's local Vision framework. It writes text or connects to document formats through HTML. Image-to-PDF conversion has an optional searchable text layer. See [image text recognition](ocr.md) for behavior, limits, and checks.

The `formats` command lists target formats and configured output backends on the current machine. An available backend does not mean every corresponding input and option has been tested.

## Current settings

The app has image quality, PNG compression levels, metadata retention, conversion to sRGB, progressive JPEG, and WebP mode and effort options. Image quality also controls image-to-PDF compression. The command accepts image settings through `--image-options FILE.json`. See [image settings](images.md) and [WebP output](webp.md) for behavior and current limits.

The app has complete-document and syntax-highlighting options. Document PDF settings select A4 or Letter paper and the Markdown template. These are not yet command-line flags either.

The media API has audio and video quality or bitrate modes, codec selection, ProRes profiles, video frame rate, VP9/AV1 speed, FLAC compression, cover-art retention, sample rate, channel count, metadata retention, a time limit, and CPU profile options. The app exposes these settings except the time limit. The command accepts `--media-options FILE.json`. See [audio settings](audio.md) and [video settings](video.md) for defaults and codec limits. CPU profiles balance concurrent automatic jobs and software work. They are not a hard limit on every library or operating-system thread.

## Current architecture

The project is a Swift package with a conversion module, a SwiftUI app, and a command. The app remains running to watch folders. It has no web UI runtime. Conversion tools run as child processes. Docusaurus builds only the documentation site.

See [Architecture](architecture.md) for the source map, conversion flow, concurrency rules, dependency boundaries, and recovery invariants. The app targets macOS 14 or later.

## Development checks

```sh
swift test
```

The Swift tests cover image, document, media, subtitle, configuration, archive, spreadsheet, ebook, font, email, and model conversion, source preservation, name collisions, invalid options, cancellation, process failure and timeout, temporary-file cleanup, and CPU-profile boundaries. They also cover external rename events, automatic replacement, Undo, and journal reconciliation. Tool-dependent tests skip if their tools are missing.

For a manual image benchmark, create an original 24-megapixel fixture:

```sh
mkdir -p .research
swift build -c release
swift tools/image-fixture.swift .research/fixture.png
/usr/bin/time -l .build/release/allomer convert .research/fixture.png .research/fixture.jpg
```

Use a fresh output path for each run. Record the macOS version, CPU, build mode, dimensions, elapsed time, and peak memory. A simple generated image is a useful baseline, not a complete workload.

For a short idle check, start the preview, leave it watching a quiet folder, and run `python3 tools/check-idle.py`. A 10-second sample on macOS 26.6.2 showed no increase in the CPU time reported by `ps`, with about 127 MiB resident memory. This is a coarse sample, not a long-term CPU or energy measurement.

## Requirements before a production release

- All reference formats and options have an implementation or a clearly documented, user-approved scope change.
- Conversion fixtures check content, pages, frames, tracks, timing, metadata, color, and attachments as applicable.
- Rename monitoring handles busy files, lost events, changed watch roots, collisions, and conversion-generated events.
- Backups, cancellation, crash recovery, and undo have failure-path tests.
- Documents and archives have resource and path constraints.
- The menu app has accessible controls and clear progress and errors.
- Builds are reproducible and contain required dependency notices.
- Apple Silicon packaging passes locally. Complete the signing, update, and clean-install work in [Cutting a release](release.md).
- A clean Mac with no development tools can use every supported format immediately after app installation.
- Memory, idle CPU, and conversion-time measurements cover realistic workloads.

## Source and licensing

The application code is original.

Original code uses the MIT license. Third-party components retain their own licenses and notices. Their official sources and exact versions must be recorded before integration or distribution. Local binary samples and decompiler output remain outside the source release.

These pages use Markdown and Docusaurus. See [Publishing the docs](publishing.md) for local preview and GitHub Pages deployment. No documentation site has been published yet.
