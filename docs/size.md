# App size

The app includes the conversion tools it needs. Fonts, codecs, and document engines account for most of the installed size. Conversion must work offline after installation. Compiler output, source archives, test fixtures, and the documentation toolchain stay outside the app bundle.

`research/package-size.json` records the current app's regular-file bytes, helper count, largest files, DMG size, and SHA-256. It excludes symlink aliases. The installer uses HFS+ with UDZO zlib compression. Its size also depends on filesystem layout, so adding a file does not give an exact prediction of DMG growth.

## Current costs

The PDF helper contains a 24.8 MB Source Han Serif collection. This is font data. Its four faces cover about 43,000 code points each and provide regional forms. Smaller upstream fallback fonts have different character sets. Changing the fallback requires character and rendering checks; reducing the byte count alone does not prove equivalent output.

The media commands share six codec libraries. This reduced their combined installed size from about 42.6 MB to 21.6 MB while keeping the checked codec and container lists. Each library is stored once in the app. The JPEG XL encoder adds about 4.8 MB before installer compression.

The font converter is an original helper linking only the HarfBuzz subsetter, Google's WOFF2 codec, and Brotli. HarfBuzz's shapers, rasterizers, and platform integrations are not built. It replaced a headless FontForge build, and the helper with its sandbox launcher is 3,345,568 bytes smaller than that executable while converting variable and CFF2 fonts the old path could not read. These changes must retain the font-format checks and output quality.

The Level 3 PostScript command adds about 4.2 MB. Its local font and character resources add 14.6 MB, including 11.7 MB of character maps and 1.7 MB of fallback fonts. The separate writer is needed for native Level 3 output. Ghostscript remains for Level 2 output, PostScript input, and output validation. That update added 19,074,198 regular-file bytes and 8,121,727 DMG bytes.

PNG compression and image-PDF quality use system libraries. Together with their controls, they added 61,296 installed bytes and 41,290 DMG bytes. TIFF compression adds 1,030,207 installed bytes and 247,046 DMG bytes for its controls, encoder, sandbox launcher, and notices. JPEG backgrounds and the AVIF quality fix added 64,512 installed bytes and 24,547 DMG bytes, with no new helper.

The current preview is 149,160,555 bytes installed and 79,969,900 bytes compressed. It contains 29 helpers and six shared media libraries. The direct DOCX page-layout route added 458,405 installed bytes and 211,845 DMG bytes. Of that, 173,100 bytes are the pinned Word renderer bundle, 11,357 bytes its license notice, 68,976 bytes the larger web helper, and the rest the command and app binaries. It adds no helper, no shared library, and no new license class. The preceding preview was 148,702,150 bytes installed and 79,758,055 bytes compressed with the same 29 helpers. Replacing the font converter in that preview removed 3,333,801 installed bytes and 1,671,117 DMG bytes, and changed the helper count by adding a converter and its launcher in place of one executable. The preview before that was 152,035,951 bytes installed and 81,429,172 bytes compressed with 28 helpers; the clean rebuild before that was 626,896 installed bytes and 211,318 DMG bytes smaller than its own predecessor. Compiler output, code signatures, and filesystem compression affect that difference, so it is not a measurement of one feature. The audit fixes add no helper, shared library, or notice. Basic DOC input added 1,040 installed bytes and 13,883 DMG bytes at its checkpoint. It extended the existing native helper and added no helper, library, or dependency.

The preceding direct audio-only container routes and their timing fixes added 976 installed bytes. That DMG was 10,922 bytes smaller because rebuilt contents and filesystem compression affect its size.

The preceding Markdown flavor control, source-specific approval controls, and searchable-PDF image settings added 47,744 installed bytes and 85,989 DMG bytes. They reused the existing helpers and added no dependency.

The preceding [chained Vorbis fix](audio.md#chained-vorbis-input) added 280 installed notice bytes and reduced the DMG by 63,013 bytes.

The preceding short Vorbis fix added 69 installed bytes and 40,699 DMG bytes.

The preceding stage overrides and their shared editor added 227,360 installed bytes and 32,279 DMG bytes. That checkpoint kept all helper/library binaries and notices unchanged. See [automatic conversion](automatic.md) for behavior and checks.

The preceding conversion-stage records and their UI added 120,320 installed bytes and 14,069 DMG bytes.

The preceding history controls and status storage added 458,288 installed bytes and 149,284 DMG bytes. Compression and filesystem layout affect these differences.

The preceding multiple-format renames and group Undo added 377,392 installed bytes and 115,835 DMG bytes.

The preceding monitoring scope, access checks, and system/cache filtering added 84,864 installed bytes and 32,870 DMG bytes.

The preceding new-file detection and Undo path added 201,760 installed bytes and 91,513 DMG bytes. Compression and filesystem layout affect the DMG measurement.

The preceding notification and login controls added 151,184 installed bytes and 35,888 DMG bytes. They added no helper or library.

The preceding backup limits, cleanup, and interrupted-removal recovery added 239,536 installed bytes and 61,227 DMG bytes. They added no helper or library.

The preceding visible-original controls and their recovery path added 50,384 installed bytes and 28,705 DMG bytes. They added no helper or library.

The preceding format-pair rules, saved options, and YAML layout fix added 346,848 installed bytes and 74,205 DMG bytes. They added no helper or library.

The preceding automatic conversion actions and their decision UI added 163,328 installed bytes and 64,569 DMG bytes. They added no helper or library.

The preceding audio extraction timing, WMA opening-sample retention, and shared filter graphs added 27,120 installed bytes over the synchronization checkpoint. That DMG was 35,483 bytes smaller. See [audio conversion](audio.md) for measured time and memory costs.

The preceding audio/video synchronization and timing checks added 22,160 installed bytes and 32,205 DMG bytes over the video-control checkpoint. See [video conversion](video.md) for those measurements.

The preceding audio settings and cover handling added 153,520 installed bytes and 38,210 DMG bytes. They reuse the media tools and native image frameworks. No helper or codec library was added.

The preceding subtitle crop and contrast fixes added 32 installed bytes and 7,641 DMG bytes. Picture-subtitle decoding and recognition initially added 25,715 installed bytes and 13,480 DMG bytes. The native helper shares existing media libraries and uses Apple Vision. No helper, library, model weights, or source dependency was added.

The preceding embedded text-subtitle extraction and controls added 90,928 installed bytes and 25,785 DMG bytes. They use the existing media tools.

The preceding plain-text input, basic DOC output, and native Word container repair added 61,184 installed bytes and 24,567 DMG bytes. They use the existing native helper. The independent document readers remain development tools outside the app.

The preceding GIF reader, video timing, and profile work together added 132,768 installed bytes and 45,505 DMG bytes. No helper or library was added. The intermediate reader/timing DMG was 483,923 bytes smaller; the following profile checkpoint added 529,428 compressed bytes despite adding only 6,656 installed bytes. Compressed size depends on binary contents and filesystem layout. These differences do not measure one feature's compressed code size.

## How to measure a change

Build the changed tool from its pinned source, then build the app with `python3 tools/build-app.py`. Run the affected conversion checks and `python3 tools/check-app.py`. Measure performance without concurrent builds or other benchmark jobs. Use original fixtures or sources with recorded licenses and hashes.

Run `python3 tools/build-dmg.py` to create and verify the preview image. It checks signatures, mounts the image read-only, compares its files and links with the app, then detaches it. It updates the size report only after those checks pass.

Compare installed size, compressed size, conversion time, memory, and output content together. A smaller font or reduced codec list can remove capabilities. A faster codec setting can produce larger files. A valid file header alone does not prove unchanged content.

Full format coverage and release work are still in progress. The final size is not fixed. Matching source bundles and notices must accompany a distribution where the dependency licenses require them; end users do not need those source files to run conversions.
