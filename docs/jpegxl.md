# JPEG XL images

Still images convert to JPEG XL through automatic extension changes and the manual tab. The app uses the official libjxl encoder. macOS ImageIO prepares supported source images and checks the encoded result. Automatic conversion keeps the source for exact Undo. Existing destinations are never overwritten.

JPEG XL has separate Lossy and Lossless choices. New settings default to Lossy, quality 85%, and effort 7. Quality controls lossy output. At 100%, the app requests the highest value below the codec's automatic lossless switch. The codec maps this to a visual distance of about 0.1. Choose Lossless for exact encoded pixels. Lossless ignores quality and preserves the pixels supplied to the codec. Input decoding, color conversion, and reducing higher precision can still change pixels before encoding. Alpha stays lossless in both modes. Automatic downsampling is disabled because it can otherwise change alpha at low quality, even when lossless alpha is requested.

Effort ranges from 1 to 10 in both modes. Higher effort can reduce file size but takes longer. Lossy color error can also vary with effort. Lossless output keeps the same decoded pixels. Both modes use one CPU thread. Effort 4 remains available for faster lossless conversion; the measurements below show why it can be useful for large inputs.

Old settings without an explicit JPEG XL mode retain their previous behavior. Quality 100% selects Lossless and keeps the old `jpegXLLosslessEffort` value, or 4 when absent. Other old quality values select Lossy at effort 7. New saved settings write `jpegXLMode` and `jpegXLEffort`. An explicit mode takes precedence over the legacy quality rule. For example, `{"quality":1,"jpegXLMode":"lossy","jpegXLEffort":7}` requests maximum-quality lossy output.

Supported EXIF and XMP metadata are retained when requested. Color and orientation still control appearance when descriptive metadata is removed. A source Display P3 profile is retained exactly on the direct PNG path. Native preparation can replace it with an equivalent profile when metadata is removed. Linear PNG gamma is retained through the matching color encoding. The sRGB setting performs the requested color conversion before JPEG XL encoding.

The current writer accepts one still image. Animated PNG and WebP, timed GIF frames, and multipage input are refused. Animation encoding, complete RAW and icon-variant selection, and exhaustive JPEG XL input coverage remain in development. A file format appearing in the catalog does not prove every variant is supported.

## Implementation and limits

A PNG that needs no metadata or color changes goes directly to the encoder. Other supported sources use one private PNG. The converter reuses the native image preparation and sandbox launcher. The launcher denies network access, restricts reads and writes, and applies CPU and file-size limits.

The encoder writes output incrementally and uses seek-based streaming internally. It retains compatibility with the established JPEG XL container ordering. Input buffering uses the upstream lower-threshold mode. These settings reduce avoidable buffering; they are not total memory quotas. The maximum lossy quality uses the next Float value below 100, because the command parses quality as Float and switches 100 to lossless. See the official [encoder source and options](https://github.com/libjxl/libjxl/blob/v0.12.0/tools/cjxl_main.cc), [quality mapping](https://github.com/libjxl/libjxl/blob/v0.12.0/lib/jxl/encode.cc), and [release notes](https://github.com/libjxl/libjxl/releases/tag/v0.12.0).

Input and output are limited to 512 MiB, with 32 million source pixels. The external stage has a 120-second timeout. Every output must decode through macOS at the expected displayed dimensions before publication. Cancellation and failures remove private files. The source version is checked again after conversion.

The source build uses libjxl 0.12.0, its pinned Highway and skcms dependencies, and the project's existing Brotli 1.2.0 and libpng 1.6.58 pins. macOS supplies zlib. ARM64 NEON instructions provide CPU acceleration. Optional viewers, Java bindings, and unrelated input libraries are disabled. No third-party source patch is applied. Sources, notices, original build files, and hashes are retained. The app bundles the encoder and its original sandbox launcher. The independent decoder is a development tool and is excluded from the app.

## Build and checks

```sh
python3 tools/build-jpegxl.py
swift test --filter testJPEGXLOutputAndAutomaticUndo
```

The following options file selects lossless encoding while keeping metadata:

```json
{"jpegXLMode":"lossless","jpegXLEffort":4,"preserveMetadata":true,"convertToSRGB":false}
```

```sh
swift run allomer convert image.png image.jxl --image-options image-options.json
```

Run `python3 tools/check-jpegxl.py` with Pillow for independent lossless pixels, lossy quality, hidden RGB, alpha, all eight orientations, EXIF, XMP, Display P3 appearance, linear gamma, 16-bit grayscale, native round trips, source preservation, failure cleanup, and overwrite refusal. Fixtures include PNG, JPEG, BMP, TIFF, WebP, GIF, PSD, and a single-size ICO. Animation and oversized-input checks verify refusal. JPEG checks distinguish platform decoding from small IJG inverse-transform differences.

`--command` and `--tools` select the packaged app. `--decoder` selects the independent upstream decoder. `--benchmark` records three complete conversions per workload, including source and command hashes. `--benchmark-only` runs just those measurements, and `--report` selects the report file. `--lossy-effort` selects the lossy benchmark effort. `--lossless-effort` selects the effort for the lossless benchmark and general lossless fixtures. Separate checks exercise all ten efforts in both modes, maximum lossy quality, lossless quality independence, invalid modes, and out-of-range values. The fixture tools are not bundled in the app.

## Measured performance

These are three-run medians from the packaged command on an Apple M2 Max with 32 GiB of RAM and macOS 26.6.2. Inputs are original seeded random RGB PNG files. Times include native output validation. MB uses decimal units.

| Input | Quality | Effort | Time | Reported peak RSS | Output |
| --- | --- | --- | --- | --- | --- |
| 1 megapixel | 85% | 7 | 0.42 s | 116.0 MB | 1.03 MB |
| 1 megapixel | 85% | 1 | 0.09 s | 79.3 MB | 1.16 MB |
| 1 megapixel | Lossless | 4 | 0.25 s | 69.5 MB | 3.27 MB |
| 24 megapixels | 85% | 7 | 9.13 s | 657.2 MB | 24.62 MB |
| 24 megapixels | 85% | 1 | 0.95 s | 501.0 MB | 27.00 MB |
| 24 megapixels | Lossless | 4 | 4.90 s | 505.9 MB | 78.50 MB |

At lossy quality 85%, effort 1 takes about 90% less time on the large sample. Its output is about 10% larger. Independent decoding gives red, green, and blue RMS errors of 26.50, 13.68, and 48.00 out of 255, versus 26.55, 14.23, and 38.74 at effort 7. Faster encoding changes color error as well as size. Noise is a stress sample, not a prediction for photos or artwork.

Lossless effort 7 took 44.58 seconds on the same large source in an earlier measurement. Effort 4 reduces that time by about 89%. Output grows about 0.4%, from 78,171,388 to 78,496,140 bytes. Both outputs preserve every source pixel. Reported peak RSS varies between runs; these results do not establish a memory improvement. The shared effort default is now 7; older saved lossless settings retain their previous effort.

Compression depends on the image. A separate 1-megapixel gradient takes 0.18 seconds at effort 4 and produces 121,678 bytes. Effort 7 takes 0.34 seconds and produces 36,088 bytes. Those are direct encoder measurements, without the app's validation. Higher effort can be useful for compressible artwork. Random data can produce a JPEG XL larger than its source PNG.

`research/jpegxl-performance.json` records the packaged results and hashes. `research/jpegxl-fast-lossy-performance.json` records effort 1. The saved baseline in `research/jpegxl-before-explicit-options.json` took 9.09 seconds for the large lossy case and 4.89 seconds for lossless at effort 4. The new controls do not establish a speed change at the same settings. `research/jpegxl-effort7-performance.json` retains the earlier lossless effort-7 measurement. `research/jpegxl-effort-comparison.json` records the direct encoder comparison and fixture formulas. RSS can include a child helper's peak. It is not aggregate simultaneous process memory and excludes the GUI. Large-image memory use remains a release concern.
