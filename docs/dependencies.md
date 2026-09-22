# Dependency updates

Use each package manager's standard files. Keep its lock file in the repository. Update one component at a time, then review the changed source, licenses, and conversion results.

| Component | Edit | Record of the resolved build |
| --- | --- | --- |
| Swift packages | `Package.swift` | `Package.resolved` |
| Native source builds and vendored headers | `tools/native-sources.json` | Verified source archives and each tool's build report under `.tools/` |
| Rust helper packages | Each helper's `Cargo.toml` | The adjacent `Cargo.lock` |
| Rust compiler | `rust-toolchain.toml` | Each helper's build report |
| Presentation and Word renderer JavaScript | `helpers/presentation/package.json` | The adjacent `package-lock.json` |
| Documentation packages | `website/package.json` | The adjacent `package-lock.json` |

SwiftPM reads package requirements from `Package.swift` and records the selected revisions in `Package.resolved`. See the [SwiftPM manifest documentation](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html#package-dependency). The app currently uses an exact Yams version. Edit that requirement when upgrading, then run `swift package resolve` and `swift test`. Review and retain both changed files. Do not edit `Package.resolved` by hand.

For a Rust helper, edit its dependency requirement and use `cargo update -p PACKAGE` in that helper's directory. Use the local compiler installed by `tools/setup-rust.py`. Set `RUSTUP_HOME` to this project's `.tools/rustup` and `CARGO_HOME` to `.tools/cargo`. Use `.tools/cargo/bin/cargo` from the project root as the executable. The normal helper build uses `--locked` and will fail if the manifest needs a different lock file.

The tracing helper uses one patched Rust crate. Its `visioncortex` requirement must match the original archive pin in `tools/native-sources.json`; the dependency check enforces this. The builder verifies and stages that archive, then applies `tools/visioncortex-color-sum.patch` with no fuzzy matching. Cargo's local path override uses the staged source. Preserve the archive, patch, and build report with a release. On upgrade, check whether upstream fixes the large-region color overflow before retaining the patch. Run the helper's Rust test and `tools/check-tracing.py`, which includes a 24-megapixel color regression.

For npm packages, edit the applicable `package.json`, then run `npm install --package-lock-only` in that directory. Review the lock changes and run `npm ci` plus the relevant build. The presentation build uses `npm ci --ignore-scripts`. Its retained MTX source version must also match `tools/native-sources.json`.

That lock file's esbuild pin builds both browser renderers. The presentation renderer resolves through the lock file itself and uses Apache-2.0; `tools/check-presentation-reader.py` exercises it. The Word renderer, docx-preview 0.4.0, also uses Apache-2.0 and is pinned as a source archive in `tools/native-sources.json` rather than in the lock file; `tools/check-word-pdf.py` exercises it. Rebuild and check both after changing the shared esbuild pin.

## Native source builds

The native manifest contains release versions or immutable commits, official download URLs, and SHA-256 checksums. Builders read it directly. It does not replace SwiftPM, Cargo, or npm. Bundled dependencies within an upstream source archive are pinned by that archive's checksum.

Some builders share a source pin. The JPEG XL build uses the Brotli entry in `fonts` and the libpng entry in `webp`. The Poppler build uses the FreeType entry in `fonts` and fonts from the `ghostscript` archive; the font build itself no longer uses FreeType, so that entry exists for Poppler alone. The TIFF build uses the libjpeg-turbo entry in `poppler`. Rebuild and check each affected converter when changing a shared entry.

The media build uses the Meson and Ninja pins in `font-build-tools` to build dav1d. It verifies and retains those build-tool archives with the media sources. These tools are not included in the app. dav1d provides software AV1 decoding when the Mac has no AV1 hardware decoder. libaom provides AVIF encoding on macOS versions whose ImageIO writer does not support AVIF. Keep their copyright, license, and patent notices with the media notices.

To update FFmpeg, edit its entry in the manifest's `media` list. Verify the new URL and checksum against the official release. Run `python3 tools/build-media.py`. The build checks the archive before extracting or patching it. It retains the source, build commands, patches, and notices. Other native tools follow the same process with their own build script. Changes to a source version may also require changes to build flags or adapters.

Rebuild the native helper after a media-library update. Its original picture-subtitle bridge uses the public FFmpeg decoder API and links the same libraries as the media commands. `tools/build-native.py` records their hashes and retains the bridge source. Run `tools/check-bitmap-subtitles.py` and the copied-app checks after either build changes.

For a vendored header, replace the file from the recorded upstream source. Update its version, URL, checksum, and notices together. Changing the manifest alone does not replace that file. `python3 tools/check-dependencies.py` verifies the checked-in bytes and checks manifest agreement without downloads.

The build records the local compiler and SDK where supported. This does not prove that every tool produces identical bytes on different Xcode releases. The minimum supported system remains macOS 14 on Apple Silicon. End users receive the built tools inside the app.

## Local source patches

A patch does not freeze a dependency at its current version. It adds work to each upgrade. The build restores the relevant upstream files before applying the patch. Patch commands run without prompts and reject missing context. A clean application of a patch is only a source check; conversion tests must still pass.

| Patch | Purpose | Relevant checks |
| --- | --- | --- |
| `visioncortex-color-sum.patch` | Prevent color-total overflow in large tracing regions | Rust helper test and `tools/check-tracing.py` |
| `ffmpeg-jpeg-validation.patch` | Reject missing JPEG end markers in strict decoding | `tools/check-jpeg.py`, media tests in `swift test` |
| `ffmpeg-gif-validation.patch` | Reject incomplete GIF blocks and pixel rows in strict decoding | `tools/check-animation.py`, animation and media tests in `swift test` |
| `ffmpeg-gif-palette.patch` | Support two colors, hidden-pixel exclusion, exact unsplit colors, and bounded per-frame histograms | `tools/check-gif-palette.py`, `tools/check-animation.py`, `tools/check-video-animation.py` |
| `ffmpeg-vorbis-timing.patch` | Preserve short Ogg audio by accounting for the first packet before sample zero | `tools/check-audio-timing.py` |
| `ffmpeg-vorbis-chains.patch` | Load each Vorbis link's headers, preserve its samples and timing, and reject incomplete headers | `tools/check-audio-timing.py` |
| `mupdf-docx.patch` | Correct PDF document export and include OCR text | `tools/check-pdf.py`, `tools/check-ocr.py` |
| `mupdf-overlay.patch` | Register the original PDF overlay and JPEG validator commands | `tools/check-ocr.py`, `tools/check-jpeg.py` |
| `carta-resources.patch` | Read bounded local resources and report missing images | Document tests in `swift test`, `tools/check-document-pdf.py` |
| `assimp-ply.patch` | Correct PLY color and UV declarations | `tools/check-models.py` |
| `presentation-rendering.patch` | Render SVG charts, propagate failures, and normalize package paths | `tools/check-presentation-reader.py` |
| `poppler-local-resources.patch` | Load bundled fonts and character maps; fail on conversion errors | `tools/check-postscript.py` |
| `poppler-gradients.patch` | Emit native Level 3 shading for exponential and stitched gradients | `tools/check-postscript.py` |
| `tiff-metadata.patch` and `helpers/tiff/metadata.h` | Retain TIFF XMP, EXIF, and GPS metadata without changing compressed image data | `tools/check-tiff.py`, TIFF tests in `swift test` |

Check whether an upstream release fixes the problem. If so, remove the patch and its build step, then run the same regression checks. Otherwise, adapt the patch to the new source and retain its license and change notice. Never skip a failed patch to make a build pass.

After an upgrade, rebuild the app and run `tools/check-app.py` against the packaged tools. Packaging checks the source metadata and uses SwiftPM's `--force-resolved-versions` option. It fails if Swift dependencies require a changed lock file. Check affected formats, failure behavior, source preservation, memory, and output quality. Refresh `THIRD_PARTY.md` and the matching source bundle before a release. The current release license audit and minimum-system checks remain incomplete.
