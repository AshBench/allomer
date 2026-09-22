# Images to video

Still images and GIF, WebP, and PNG animations can become video through automatic or manual conversion. Available video outputs are MP4, MOV, MKV, WebM, AVI, 3GP, MXF, MPEG, M2TS, VOB, WMV, FLV, and TS. Existing destinations are preserved. Automatic conversion keeps the original file for Undo.

The route uses a private GIF intermediate when needed. It uses the selected GIF color limit and dithering settings. This also connects supported camera RAW files, rasterized SVG artwork, and icon images to video. Multipage TIFF files are excluded from this route because pages do not define animation timing.

## Playback and appearance

A still image becomes a 0.1-second silent clip. An animation plays its frame sequence once. An APNG poster is excluded. The source repeat count does not extend the clip. Positive delays use the GIF writer's 10-millisecond grid. Zero or absent delays use the decoder's 100-millisecond default.

With Preserve source selected, the app selects the lowest whole frame rate that preserves every delay. Most containers use 1–100 frames per second. MXF uses 25, 50, or 100. WMV needs at least two timestamped frames and can use 200 fps for a 10-millisecond clip. A normal still MP4 needs one encoded frame. Longer or uneven delays can still require repeated frames. A selected fixed frame rate can add or drop frames and change the end by up to one frame interval. See [video settings](video.md) for codecs, quality, bitrate, and frame rates.

H.264 output carries timing data for playback through transport streams. The app decodes the finished video and checks its complete timeline on a 10-millisecond grid. This avoids relying on a container's estimate of the last frame's duration. The check uses one decoder thread and a 120-second timeout. Its pixel limit allows the one-pixel padding described below.

Short transport-stream input is recognized from its packet framing. Generated TS files contain at least twelve standard packets so common format probes can recognize them. Padding uses null packets and does not add pictures or change timing.

Transparent pixels become black except with ProRes 4444 and 4444 XQ, which can retain the intermediate's binary alpha. H.264, HEVC, AV1, and WMV2 output pad an odd width or height by one black pixel at the right or bottom edge. Orientation is applied before encoding. The image is not cropped to meet the codec's dimension rule.

GIF preparation uses 8-bit sRGB colors and a palette with at most 256 entries. It can reduce color precision and partial transparency. Descriptive metadata is omitted by that intermediate. Video compression and chroma subsampling can change pixels further. This route is not an archival copy of an image or RAW file.

The video step converts sRGB component values to the native video transfer curve. It creates a small lookup table through the system [CoreVideo color-space API](https://developer.apple.com/documentation/corevideo/cvimagebuffercreatecolorspacefromattachments(_:)). The table is removed after conversion. Output has explicit color tags. MPEG-4 Part 2 and WMV2 use their legacy color matrix; other outputs use the BT.709 matrix. Development checks compare MP4 and MOV playback frames through AVFoundation in sRGB. No color profile, helper, or library was added to the package.

For a directly supplied GIF with an embedded RGB ICC profile, the app converts each global and local palette to sRGB through CoreGraphics. A private copy keeps the compressed frame data, controls, timing, and transparency indices. The old profile block is removed from that copy. Each palette contains at most 768 bytes. Removing the profile shifts bytes through a 64 KiB buffer. Preparation has a 120-second limit and uses the shared GIF input bounds. Invalid or non-RGB profiles fail with the source intact. Read-only sources are supported.

The [GIF preparation limits](animation.md#implementation-and-limits) and existing media timeout apply. Codec support also depends on dimensions and the installed macOS video encoder. H.264 uses VideoToolbox with its software fallback enabled. Minimum-release qualification and broader codec limits remain open work.

On macOS 26.6.2, the native GIF reader rejects the tested 6000 × 4000 flat-color GIF. Both Pillow and FFmpeg decode it. The app uses strict bundled decoding for GIF validation, which lets that PNG-to-video workload reach video encoding. Native image routes use a [bounded preparation step](animation.md#implementation-and-limits). Native macOS viewers can still reject the GIF itself.

## Development checks

```sh
swift test --filter ImageVideoTests
swiftc -O tools/check-image-video-native.swift -o .tools/check-image-video-native
python3 tools/check-image-video.py \
  --command dist/preview/Allomer.app/Contents/MacOS/allomer \
  --tools dist/preview/Allomer.app/Contents/Helpers \
  --native-decoder .tools/check-image-video-native
```

The Python check needs Pillow. Its original fixtures cover 201 image/video cases across all 13 containers. It decodes the complete playback timeline and checks colors, black transparency, padding, timing, source preservation, collisions, invalid input, and cleanup. Timing cases include zero, positive, and mixed delays, all nine common frame rates, and 10-millisecond clips. A short transport-stream input is checked through MP4, GIF, and WebP conversion. Profiled GIF tests use LittleCMS for independent expected colors. They cover local palettes, transparency, profile placement before and after frames, read-only input, and invalid profiles. The optional native decoder adds 34 playback-color checks. Swift checks cover available routes, orientation, native playback color, automatic conversion, exact Undo, multipage refusal, odd-sized ordinary video, and unchanged compressed GIF frame bytes during profile conversion.

Use `--benchmark-only` to measure three complete conversions for each original workload: three PNGs and one profiled GIF, all to MP4. `--report` selects the JSON file. Run benchmarks without other build or conversion jobs. Measurements include GIF preparation, video encoding, validation, and publication. Input integrity checks warm the file cache. Python work, external frame checks, and GUI memory are excluded. RSS is a process high-water reading. It does not sum memory across simultaneous processes or native video services.

## Measured cost

Three packaged runs at the earlier bitrate-default checkpoint on an M2 Max with macOS 26.6.2 gave these medians. They do not measure the new quality-100 default:

| Original image workload | Time | Peak RSS | MP4 bytes |
| --- | ---: | ---: | ---: |
| 512 × 512 PNG artwork with transparency | 0.27 s | 40.8 MiB | 1,018 |
| 1024 × 1024 RGB noise PNG | 1.01 s | 58.7 MiB | 573,727 |
| 6000 × 4000 flat-color PNG | 1.90 s | 453.8 MiB | 5,744 |
| 6000 × 4000 Display P3 GIF | 1.31 s | 453.9 MiB | 5,730 |

All four workloads complete. The profiled GIF also passes independent expected-color and native playback checks. `research/image-video-performance.json` records every run, source hash, and command hash. The earlier failed large-image attempts remain in `research/image-video-performance-before-gif-reader.json`. The benchmark exits with failure when any workload fails.

After the GIF reader fix, the old 100 fps path took 2.35 seconds and 901.4 MiB for the large flat image. Selecting fewer repeated frames reduces those readings to 1.90 seconds and 453.8 MiB in the current build. The noise case moves from 0.92 seconds and 83.5 MiB to 1.01 seconds and 58.7 MiB. The new path also performs the complete output timeline check. These are three-run samples, not general speed or memory guarantees. The fixed-rate baseline remains in `research/image-video-performance-fixed-rate.json`. The checkpoint before profile handling remains in `research/image-video-performance-before-gif-profile.json`.

The first native playback frame of the original noise fixture is pixel-identical between the fixed-rate and selected-rate builds. Both have an RGB root-mean-square error of 65.19 on a 0–255 scale against the source PNG. This includes palette reduction and chroma subsampling. It does not establish quality for other images. `research/image-video-quality.json` records the two command hashes and results. Reproduce the comparison with `python3 tools/measure-image-video-quality.py --before-app /path/to/previous.app` after compiling the native decoder above. Pillow and NumPy are development-only requirements for that measurement.
