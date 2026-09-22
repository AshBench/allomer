# Subtitles

Rename a file in a watched folder to extract or convert subtitles. Manual conversion uses the same engine. Automatic conversion keeps the source for exact Undo. The bundled media tools work offline.

## Embedded tracks

Video files offer SRT, WebVTT, ASS, SSA, SBV, and MicroDVD output. The app extracts one subtitle track. It omits video and audio from the result. This path does not transcode video or audio.

The default is the first subtitle track in file order. A container's default-track flag does not override that choice. Manual conversion lists track numbers with their available language, title, and codec. Settings can select a fixed track number from 1 to 256 for automatic conversion. A missing selected track stops conversion. It does not silently select another language. A file without subtitle tracks also stops with an error.

The text-track checks cover these containers and codecs:

| Container | Checked embedded text |
| --- | --- |
| MP4, MOV, 3GP | MOV timed text |
| Matroska | SubRip and ASS |
| WebM | WebVTT |

Each fixture contains video, audio, and two subtitle tracks. Checks cover all six output formats, explicit selection, Unicode, multiple lines, overlapping cues where the source supports them, collisions, source preservation, and cleanup. A separate check covers a five-second container start offset and exact Undo. Extracted cue times are relative to the container's start.

MOV timed-text samples cannot overlap. The fixture muxer shortens an earlier sample when the next one starts. The extraction check reads the actual encoded packet times and text before comparison. It does not assume the original SRT still matches the embedded track.

Closed captions carried inside video frames need another extraction path. Other video containers, timed-text modes, and automatic track prompts still need work. A listed route is not proof that every embedded codec can be read.

## Picture tracks

PGS, DVD, DVB, and XSUB tracks use the existing media libraries to decode subtitle pictures. Apple Vision reads their text locally. The resulting cues use the same six subtitle writers. The **Text recognition** language setting also applies to picture subtitles. It defaults to Automatic. Check recognized text for reading errors. Picture fonts and styling are not recovered.

Original fixtures check PGS in Matroska, DVD in Matroska, DVB in MPEG-TS, and XSUB in AVI. Decoder checks compare rendered caption pixels and times. Packaged conversion checks cover all 24 codec/output pairs. Another 18 checks cover dark text, cropped PGS objects, and their combination across all six outputs. PGS also covers a selected second track, two picture rectangles, a clear gap, a container start offset, invalid input, and exact Undo.

Clear events end the previous picture. A later display can shorten a declared timeout, as DVB requires. A final picture with no known end stops conversion. An unreadable visible picture also stops conversion. The app does not silently omit it. DVD and XSUB checks use the actual encoded times; the fixture encoder shortens the two cue ends by 11 and 9 milliseconds.

The decoder scans container packets and decodes the selected subtitle track. Bounded probing may inspect initial frames of other streams. It does not decode the full video timeline. This path adds no codec library, OCR engine, or model download. The native helper shares the media libraries already in the app.

PGS crops select the stored picture region and retain its display position. Invalid crop bounds stop conversion. Recognition uses a light or dark background chosen from the visible caption pixels. This keeps black letters on transparency readable without allocating a second picture. The crop check includes unwanted text outside the selected region and a second object that checks placement. An independent pixel comparison also checks every rendered byte.

DVD files can lack the external palette needed for correct appearance. Broader palette, fragment, damaged-file, and codec-mode checks remain open. These fixtures do not establish complete picture-subtitle fidelity.

## Text files and formatting

The text converter supports SRT, WebVTT, ASS, SSA, SBV, and MicroDVD. Original fixtures cover all 36 text-file input/output pairs. The app checks cue text and timing before publication. SRT and WebVTT use millisecond times. ASS and SSA use hundredths of a second. MicroDVD uses frames, so times can move by one output frame.

With formatting removal off, supported text outputs convert directly from the source. Same-format stream copy retains the checked ASS font, size, position, and italic overrides. The SRT intermediate is used for text and timing checks. Full style, karaoke, cue-setting, and font-attachment fidelity remains incomplete across different formats.

SBV and MicroDVD need plain cue text. Enable **Remove subtitle formatting** when the source has markup. MicroDVD also needs the source frame rate when its header does not supply one. Its output frame rate defaults to 25. Supported output rates are 4–99, and explicit source rates are 1–240.

Formatting removal strips the supported bold, italic, underline, strikeout, font, and normalized alignment tags. Checks cover ASS alignment removal and repeated SSA conversion without duplicate dialogue fields.

## Limits and validation

Subtitle text files are limited to 16 MiB and 100,000 parsed cues. Conversion work files are limited to 80 MiB. FFmpeg allocations are individually limited to 64 MiB in the subtitle path. These are bounds, not a claim about total memory. Each external subtitle command has a 120-second timeout and supports cancellation.

Picture decoding limits the container to 512 streams, subtitle tracks to 256, and display events to 200,000. It allows up to 256 rectangles per display and 32 million decoded canvas pixels. The combined RGBA picture must also fit 64 MiB, so its effective limit is 16,777,216 pixels. Recognition retains one pending text cue and releases each picture after the synchronous request. The native launcher restricts file access to the source, work folder, bundled libraries, and required system resources.

The shared process check rejects errors logged by FFmpeg or ffprobe at an error-only log level, even when the process returns success. A truncated Matroska fixture exposed that behavior: the old path could publish just the first cue. That diagnosed error now stops publication. This does not prove detection of every possible damaged file.

## Development checks

Run `swift test --filter 'EmbeddedSubtitleTests|testSubtitleFormatsPreserveTextAndTiming'` for track selection, old saved settings, timing, ASS styles, automatic conversion, and exact Undo. Run `python3 tools/check-subtitle-extraction.py` for the container fixtures and independent Python cue comparisons. It uses the built tools in `.tools/bin` and needs only Python's standard library.

Use `--command /path/to/Allomer.app/Contents/MacOS/allomer --tools /path/to/Allomer.app/Contents/Helpers` to check a packaged app. Add `--benchmark` for three complete Matroska-to-SRT measurements. Run these without other build or conversion jobs. The synthetic benchmark has 10,000 cues over a 50-minute subtitle timeline and a short video stream. It is not a benchmark of decoding 50 minutes of video.

At the text-subtitle checkpoint, the packaged command took a median 0.48 seconds across three runs on the M2 Max with macOS 26.6.2. Median peak process memory was 65,077,248 bytes, about 62.1 MiB. The 687,625-byte input produced a 698,894-byte SRT. These figures include probing, extraction, cue validation, and publication. Source hashing warms the cache. GUI and Python work are excluded. Reported memory is a per-process peak, not the sum of simultaneous app and helper memory. All samples and file hashes are in `research/subtitle-extraction-performance.json`.

The command accepts `--subtitle-options FILE.json`. For example, `{"embeddedTrack":2}` selects the second subtitle track. Omitted fields use defaults. End users need no compiler, separate decoder installation, or tool download.

Run `tools/check-bitmap-subtitles.py` with a development Python that has Pillow. It creates its own PGS pictures and checks the complete conversion path. It accepts the same `--command`, `--tools`, and `--benchmark` options. Its OCR benchmark uses 200 original picture cues over ten minutes, with six black video frames. Use `--benchmark-input` to reuse the exact source bytes for a comparison. Set `ALLOMER_BITMAP_FIXTURE` to the original Matroska fixture to enable the Swift automatic-conversion and Undo test. `tools/make-bitmap-subtitle-fixture.py` creates the original SUP. Its `--check` mode verifies decoded pixels and timing for uncropped fixtures. The bitmap checker accepts `--decoder-probe` with a development build of the C bridge for exact cropped-pixel checks.

The packaged OCR benchmark takes a median 5.80 seconds across three runs on the M2 Max with macOS 26.6.2. Median peak process memory is 58,687,488 bytes, about 56.0 MiB. The 596,435-byte source produces a 9,092-byte SRT with all 200 expected cues. The report is `research/bitmap-subtitle-performance.json`. Before the crop and contrast fixes, the same source took a median 5.72 seconds and 54.0 MiB. The run times overlap, so these small samples do not establish a speed change. The earlier report is `research/bitmap-subtitle-performance-before-fidelity.json`.

These checks measure the full conversion, including recognition and validation. They use repeated original text and are not a general OCR accuracy or movie-performance claim. Source hashing warms the cache. GUI and Python work are excluded. Peak memory does not include the aggregate use of simultaneous app, helper, and system recognition processes.
