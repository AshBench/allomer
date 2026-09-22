# WebP images

Still images and GIF, WebP, and PNG animations convert to WebP with the bundled libwebp encoder. For still images, the app uses a private PNG when it must change color, remove metadata, or read another image format. A PNG that needs none of these changes goes directly to the encoder. Conversion works after an extension change and from the manual tab. Automatic conversion keeps the original for Undo.

| Setting | Default | Behavior |
| --- | --- | --- |
| Quality | 85% | Controls lossy quality. In lossless mode, it controls compression work. |
| WebP compression | Lossy | Choose lossy or lossless. |
| WebP effort | 4 | Range 0–6. Higher values spend more time on compression. |
| Keep image metadata | On | Keeps supported EXIF, XMP, and ICC data. |
| Convert color to sRGB | Off | Uses native color conversion when enabled. |

WebP stores 8-bit color. Lossless mode preserves the pixels supplied to the encoder, including RGB values under full transparency. A source with higher color depth still needs conversion to 8-bit pixels. Native color conversion can also change pixel values. Alpha remains lossless in both compression modes.

Turning metadata retention off removes descriptive metadata. Orientation and color information still control appearance. A standard sRGB image can use WebP's implicit color space without an ICC chunk. Other color spaces need the matching profile.

The private PNG uses its ICC profile without a separate gamma instruction. This prevents the encoder from changing the pixel gamma and then retaining a profile that describes the original pixels. Original tests check this with linear RGB and an independent color transform. The source file stays unchanged.

Still-image input is limited to 512 MiB and 32 million pixels. WebP limits each edge to 16,383 pixels. The encoder uses one thread, existing process time limits, and a 512 MiB file limit. Individual libwebp allocations are capped at 512 MiB. These limits do not form a total process-memory quota. Output must decode at the expected size before the app publishes it. Existing destinations are never overwritten.

Lossy conversion uses the encoder's built-in low-memory mode. This keeps the selected quality and effort but can take longer and produce different compressed bytes. The option does not reduce lossless memory. See the [encoder options](https://developers.google.com/speed/webp/docs/cwebp). Further lossless memory work remains open.

The packaged build measured these three-run medians on original random RGB inputs at quality 85 and effort 4:

| Input | Compression | Time | Reported peak RSS |
| --- | --- | --- | --- |
| 1 megapixel | Lossy | 0.24 s | 19.9 MB |
| 1 megapixel | Lossless | 0.15 s | 53.7 MB |
| 24 megapixels | Lossy | 9.25 s | 233.5 MB |
| 24 megapixels | Lossless | 2.85 s | 1,098.0 MB |

Before the low-memory option, the same 24-megapixel lossy input took 5.33 seconds and 597.3 MB. The change saves about 61% of peak RSS at a measured time cost of about 74%. Random pixels are a stress input; other images can behave differently. The reports are `research/webp-performance.json` and `research/webp-performance-before-low-memory.json`. RSS can include a child helper's peak. It is not aggregate simultaneous process memory. The GUI is excluded.

## Animation

GIF, WebP, and APNG input keeps its frame count, delays, total plays, and displayed orientation by default. An [animation frame rate and total plays](animation.md#animated-image-input) can replace that timing and those repeats instead. APNG posters are excluded from playback. Delays round to milliseconds. A positive delay shorter than one millisecond becomes one millisecond. Zero stays zero. One-frame animations keep their timing and repeat fields. WebP stores total plays, while GIF stores extra repeats. Zero means forever.

The shared frame reader includes the [APNG poster and color fixes](animation.md). Native ImageIO prepares each full frame as PNG. The existing color buffer applies orientation when needed. The first frame supplies supported EXIF, XMP, and color metadata. Tests compare Display P3 appearance with an independent color transform, with metadata and sRGB conversion on and off. Native decoding and color conversion can change hidden RGB values under transparency before lossless encoding.

An original small writer uses libwebp to encode each prepared frame. It writes the public WebP container in order and releases each encoded frame after writing. It does not keep the complete encoded animation in memory. Each frame replaces the full canvas. This keeps every input frame and handles one-frame animations without converting them to still images. It can produce larger files than an encoder that merges frames or stores only changed rectangles. The format is defined by the [WebP container specification](https://developers.google.com/speed/webp/docs/riff_container). No third-party source patch is needed.

Animation limits are 10,000 frames, 32 million pixels per frame, and 256 million pixels in total. Every frame must use the same canvas after orientation. Finite playback is limited to 65,535 total plays, and one frame can last at most 16,777.215 seconds. Larger values fail with the source intact. Prepared PNG files are limited to 1 GiB. APNG decoding can use another private directory up to 1 GiB. These files are removed on success or failure. The encoded file is limited to 512 MiB. Every output frame is decoded to check its dimensions and delay. The app also checks the frame count, repeat count, and source version before publication.

Video also converts to WebP with sampling, scaling, and playback settings. See [video animation](animation.md#video-input) for behavior and limits. Animated WebP input can also convert to [animated GIF](animation.md). The still-image path refuses to flatten an animation. Full metadata fidelity across every input format and strict damaged-source validation for every image codec remain open.

The packaged animation benchmark has these three-run medians on original 640 × 360 inputs at quality 85 and effort 4:

| Input | Frames | Mode | Time | Reported peak RSS | WebP output |
| --- | ---: | --- | ---: | ---: | ---: |
| GIF | 30 | Lossless | 0.28 s | 28.2 MB | 8,634 bytes |
| GIF | 30 | Lossy | 0.49 s | 28.2 MB | 91,594 bytes |
| GIF | 120 | Lossless | 0.92 s | 28.8 MB | 33,474 bytes |
| GIF | 120 | Lossy | 1.76 s | 29.0 MB | 362,060 bytes |
| WebP | 120 | Lossless | 1.61 s | 30.1 MB | 33,474 bytes |
| WebP | 120 | Lossy | 2.43 s | 30.7 MB | 362,060 bytes |
| APNG | 120 | Lossless | 1.92 s | 25.1 MB | 33,474 bytes |
| APNG | 120 | Lossy | 2.76 s | 25.4 MB | 362,060 bytes |

These inputs contain colored shapes and irregular frame delays. Lossless output preserves their pixels exactly and is both faster and smaller on this workload. Lossy output changes colors. These results do not predict photographic input. Timing includes frame preparation, encoding, and output validation. `research/webp-animation-performance.json` and `research/webp-animation-lossy-performance.json` record the samples and workload and binary hashes. MB means one million bytes. RSS can include a child helper's peak. It is not aggregate simultaneous process memory and excludes the GUI. Large-frame lossless memory remains open.

## Development

Run `python3 tools/build-webp.py` on an Apple Silicon Mac with Xcode, CMake, and Python 3.12 or later. The source manifest pins libwebp 1.6.0 and libpng 1.6.58. The build disables viewers and unused conversion tools. It links only to macOS libraries and retains source archives, build commands, checksums, and notices. End users need no development tools or extra installation.

The command also accepts an image-options JSON file:

```json
{"webpMode":"lossless","webpEffort":4,"preserveMetadata":true}
```

```sh
swift run allomer convert input.png output.webp --image-options image-options.json
```

The options file is limited to 64 KiB. Missing fields use their defaults. Invalid values stop conversion.

Run `swift test --filter testWebPOptionsConversionAndAutomaticUndo` for settings, metadata removal, source preservation, overwrite refusal, extension changes, and Undo. Run `python3 tools/check-webp.py` with Pillow for independent pixels, alpha, eight orientation values, EXIF, XMP, ICC data, linear and Display P3 color, 16-bit input, source-format detection, and failure checks. Use `--command` and `--tools` to check a packaged build. `--benchmark` records three complete conversions per image size and compression mode. These fixture tools are not bundled in the app.

Run `python3 tools/check-animation.py --format webp` for the complete animation path. It checks timing, repeats, disposal modes, posters, all eight orientations, metadata, color, limits, source preservation, and cleanup. `--benchmark` records complete lossless conversions. Add `--benchmark-webp-mode lossy` to measure lossy encoding. Run `python3 tools/check-webpanim.py` for direct writer checks, including single frames, zero delays, maximum delays, transparency, metadata, invalid manifests, and symlink refusal. The automatic animation and exact Undo check is part of `testAnimatedGIFTimingLoopsAndAutomaticUndo`.
