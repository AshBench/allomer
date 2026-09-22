# Animated GIF output

For still or animated images converted to video containers, see [images to video](image-video.md).

Animated GIF, WebP, and PNG files convert to GIF through the same automatic and manual workflows as other images. The writer keeps each animation frame, its delay, orientation, and total play count. An APNG poster is excluded from playback. Automatic conversion keeps the original for Undo. Existing destinations are never overwritten.

GIF uses a palette with at most 256 colors and binary transparency. Output colors use sRGB. Color reduction can change pixels, and partial transparency cannot be retained exactly. GIF delays round to 10-millisecond units. Positive delays shorter than 10 milliseconds become 10 milliseconds. A source delay of zero stays zero. Very short delays can play differently in different viewers. Repeat counts keep their meaning across formats: GIF stores extra repeats, while WebP and APNG store total plays. Zero means forever. Removing descriptive metadata keeps timing, repeats, and orientation.

Image-to-GIF settings include a color limit from 2 to 256 and ordered dithering. The defaults are 256 and On. One entry is reserved for transparency. Ordered dithering uses an 8 × 8 Bayer pattern. Turning it off chooses palette colors without that pattern. Alpha below 128 becomes transparent; alpha from 128 to 255 becomes opaque. Hidden colors are excluded from palette analysis. For example, `{"gifMaxColors":16,"gifDither":false}` requests a 16-entry limit without dithering through `--image-options FILE.json`.

## Implementation and limits

macOS ImageIO reads GIF and WebP frames. The shared native color buffer applies orientation and sRGB conversion. Apple's Accelerate framework removes premultiplied alpha in place. The app writes private raw RGBA frames, then runs one bundled FFmpeg encoding pass. Each frame gets its own palette and a full canvas. A streaming check restores the original delays in the generated GIF. The output is decoded again to check its frame count, dimensions, delays, and repeats before publication. GIF descriptive metadata is currently omitted even when metadata retention is on. Comment and other descriptive metadata retention remain open work.

The native GIF reader can reject valid, highly compressed images. When it cannot report frame dimensions, the app uses the bundled decoder to prepare composited PNG frames. A private PNG or APNG retains their color profile, delays, and total plays for the native image routes. Single-frame animation uses standard APNG control chunks. The original file is kept. GIF-to-video uses the bundled decoder. It first converts embedded RGB profiles to sRGB in the palettes of a private copy. Archiving preserves the original bytes.

GIF validation uses one shared block reader and a complete strict decode. The block reader also supplies timing changes for GIF output. It uses a 64 KiB buffer, source-version checks, and a 120-second time limit. ICC data is limited to 16 MiB. Native image preparation is limited to 256 million total pixels, a 1 GiB decoded-frame directory, and a 512 MiB prepared PNG/APNG. Files remain available until the native writer finishes and are then removed. Cancellation is checked between frames and streamed copies. A native encoding call cannot be interrupted within one frame. No new tool or library is needed.

The fallback keeps embedded RGB profiles, including the checked Display P3 profile. Other GIF application metadata is not mapped to PNG. GIF plain-text rendering is rejected with the source intact. The [video profile path](image-video.md#playback-and-appearance) changes palette colors without decoding or recompressing GIF frame data.

The palette generator retains exact source colors when a palette entry needs no color averaging. A local codec patch permits two colors and excludes hidden pixels from analysis. Frames with at most 65,536 distinct colors use the original 8-bit color histogram. Larger histograms are rebuilt with 6-bit color channels, which permits at most 262,144 opaque entries. This bounds palette analysis and adds a small color approximation before palette reduction. Final palette mapping uses the original 8-bit pixels. The option applies only to per-frame palette generation. It is off in the upstream filter's default behavior. The build retains the original upstream source and the patch.

Palette lookup caches at most 32 colors in each of 32,768 buckets. Further colors use the same nearest-color search without extending the cache. This limits cache entries to 1,048,576 and does not change color selection. The cache limit is also off by default in the upstream filter.

When the palette generator reports no color reduction, the writer skips dithering for that frame. This avoids changing colors that already fit in the palette. Frames that need reduction use the selected dither setting.

The native APNG reader can change the first animation frame when a separate poster is present. The bundled FFmpeg decoder produces private PNG frames for this route. It writes the shared color profile only on the first private frame. The app loads that profile before selecting frames, then restores it on later frames before converting them to sRGB. It checks the frame count and removes the private directory on success or failure. This adds temporary disk use and decoding work. It needs no new installed tool or library.

GIF inputs receive a strict decoder check before image, PDF, OCR, or media conversion. The original four-line FFmpeg patch rejects incomplete pixel rows and a missing or incomplete block stream in strict mode. Default FFmpeg decoding remains unchanged. Archiving preserves bytes without requiring a decodable image. These checks detect the tested corruption cases; they do not prove every malformed image is rejected.

Input and output files are limited to 512 MiB. There can be at most 10,000 frames, with 32 million pixels per frame and 256 million pixels in total for GIF writing. Each GIF edge must fit in 65,535 pixels. A frame delay cannot exceed 655.35 seconds. Finite playback is limited to 65,536 total plays. Larger values fail with the source intact. External work uses one codec thread, the existing time and cancellation controls, and a 256 MiB limit per allocation. These are not total process-memory quotas. The raw GIF directory has a 2 GiB limit, including the private encoded output. The APNG decoder has a separate 1 GiB directory limit. Limits are checked during external work and after it ends. They can briefly be exceeded between checks. Nested directories or unreadable generated files fail the check. Success, failure, and cancellation remove private frames.

## Animated image input

Animated GIF, WebP, and PNG sources keep their own timing by default. Each output frame carries the delay recorded in the source, and the output repeat count matches the source.

| Image setting | Default | Behavior |
| --- | ---: | --- |
| Animation frame rate | Preserve source | Preserve source keeps every original delay. A fixed rate of 10, 12, 15, 20, or 25 frames per second resamples the animation to equal delays. |
| Total plays | Preserve source | Preserve source keeps the source repeat count. Zero repeats forever. Values 1–65,535 set total plays. |
| Animation maximum width | 0 | Range 0–65,535. Zero keeps the displayed width. A positive value scales every frame down to fit that width, keeping proportions. Frames are never enlarged. |

Resampling walks the source timeline in equal steps and picks the frame visible at each step, so a slower rate drops frames and a faster rate repeats them. The output frame count is the source duration divided by the step, rounded to the nearest whole frame. A result above the 10,000-frame limit is refused instead of being shortened. GIF delays use 10-millisecond units and WebP uses milliseconds, so a requested rate is stored at that precision. Colors and dithering for animated GIF output use the same GIF palette settings as still images.

```json
{"animationFrameRate":20,"animationPlays":4}
```

## Video input

Video files convert to GIF or WebP through manual conversion and automatic extension changes. Automatic conversion keeps the original video for exact Undo. The app uses one video track and omits audio, subtitles, cover art, and descriptive container metadata. Files with more than one video track need a track selector and are currently refused.

| Video setting | Default | Behavior |
| --- | ---: | --- |
| Preserve source frame timing | Off | Keeps every decoded frame and its own duration instead of resampling. GIF stores delays in hundredths of a second and WebP in milliseconds, so a source rate that does not divide evenly into those units is stored at the nearest step. |
| Frames per second | 15 | Range 1–100. Frames are sampled or duplicated to reach this rate. Ignored when source timing is preserved. |
| Maximum width | 0 | Zero keeps the displayed width. A positive value scales down without enlarging the video. |
| Total plays | 0 | Zero repeats forever. Values 1–65,535 set total plays. |
| GIF colors | 256 | Range 2–256, including a slot for transparency. |
| Ordered GIF dithering | On | Adds a fixed pattern to reduce color banding. The pattern does not change between frames, so it does not crawl across an animation. Image-to-GIF output uses the same method. |

WebP also uses the shared quality, lossy/lossless mode, and effort settings. Video output uses 8-bit sRGB and square pixels. Rotation and non-square source pixels are applied before writing. GIF keeps binary transparency; WebP keeps alpha. HDR video is refused until tone-mapping controls are available. When source timing is not preserved, variable-rate timing is replaced by the requested sampling rate and duration can change by up to one output frame. GIF timing uses 10-millisecond units and WebP uses milliseconds. Timing follows rounded frame boundaries to avoid accumulating a rounding error across the clip.

The existing FFmpeg scale and palette filters prepare the frames. GIF output uses a new palette for each frame and writes directly to a private file. WebP output uses private PNG frames and the existing bounded WebP writer. One preview frame determines the displayed canvas before a complete decode starts. No new executable or dependency is needed. See the upstream [scale](https://ffmpeg.org/ffmpeg-filters.html#scale), [palette generation](https://ffmpeg.org/ffmpeg-filters.html#palettegen), and [palette application](https://ffmpeg.org/ffmpeg-filters.html#paletteuse) documentation.

Video input is limited to 512 MiB, 32 million pixels per decoded frame, 10,000 output frames, and 256 million output pixels in total. Generated PNG frames have a 1 GiB directory limit. GIF and WebP outputs are limited to 512 MiB. Directory limits are checked during external work and after it ends; they can briefly be exceeded between checks. External stages use one thread and a 120-second timeout each. Cancellation and failure remove private files. The app decodes output frames to check dimensions and timing before publication. Duration is compared with the source video when its track duration is available. These bounds are not a total process-memory quota.

The following settings file requests 15 frames per second, a maximum width of 640 pixels, and three total plays:

```json
{"videoFrameRate":15,"videoMaxWidth":640,"videoLoopCount":3,"videoGIFColors":256,"videoGIFDither":true,"webpMode":"lossless"}
```

```sh
swift run allomer convert clip.mov animation.webp --image-options image-options.json
```

## Development checks

Run `swift test --filter testAnimatedGIFTimingLoopsAndAutomaticUndo` for automatic APNG-to-GIF conversion, frame delays, repeat counts, metadata removal, overwrite refusal, exact Undo, and damaged GIF source preservation.

Run `python3 tools/check-animation.py` with Pillow for independent original GIF, WebP, and APNG fixtures. It covers finite and infinite playback, the largest GIF repeat count, disposal modes, posters, transparency, all eight orientations in still PNG and animated PNG/WebP, Display P3 color, malformed GIF blocks and pixel rows, misleading extensions, refusal to flatten animation, and cleanup. `--command` and `--tools` select a packaged build. `--benchmark` records three complete conversions per workload. The fixture tools are not bundled in the app.

Run `python3 tools/check-gif-palette.py` with Pillow 12.3 or later for color limits, deterministic ordered dithering, alpha thresholds, blank frames, large color histograms, maximum delays, invalid settings, source preservation, overwrite refusal, and paths with spaces, accents, commas, and percent signs. `--benchmark-only` measures three complete 24-megapixel noise-image conversions and decoded color error. `--report` selects the report file. The Swift delay-parser test also rejects truncated, duplicate, missing, and trailing blocks.

Run `swift test --filter testMediaOutputsWithInstalledTool` for video-to-GIF and video-to-WebP conversion from all thirteen generated video containers, automatic conversion, and exact Undo. Run `python3 tools/check-video-animation.py` with Pillow for independent pixels, alpha, frame rates, repeats, palettes, dithering, scaling, rotation, pixel aspect ratio, short clips, linear-color input, malformed video, excessive frame counts, source preservation, and cleanup. Add `--benchmark` to record three complete conversions for each workload. `--command` and `--tools` can select the packaged app.

## Measured performance

These are three-run medians for original 640 × 360 animations on macOS 26.6.2. Timing includes the complete packaged command conversion. Reported peak RSS can include a child helper's peak. It is not aggregate simultaneous process memory, and it excludes the GUI. MB means one million bytes.

| Input | Frames | Time | Peak RSS | GIF output |
| --- | ---: | ---: | ---: | ---: |
| GIF | 30 | 0.16 s | 53.7 MB | 109,167 bytes |
| GIF | 120 | 0.45 s | 56.1 MB | 434,572 bytes |
| WebP | 120 | 1.17 s | 58.0 MB | 434,572 bytes |
| APNG | 120 | 0.92 s | 53.7 MB | 434,572 bytes |

The previous native writer took the same 0.45 seconds for the 120-frame GIF. Its reported peak RSS was 60.8 MB and its output was 424,199 bytes. The new writer adds palette and dither controls, reduces this measured peak by about 8%, and increases output size by about 2.4%. Both writers preserve the fixture pixels exactly. Other artwork can have different memory, size, and color results.

`research/animation-performance.json` records the samples, workload hashes, and packaged command and media library hashes. `research/animation-before-gif-palette.json` retains the previous native result. These measurements are not a general memory bound.

A separate 24-megapixel RGB noise image took 8.86 seconds and 482.1 MB peak RSS with the new writer. The previous native writer took 0.80 seconds and 487.4 MB. Output sizes were 32,868,958 and 32,988,513 bytes. The new controls have a substantial CPU cost on this many-color input. Red, green, and blue RMS errors were about (18.38, 11.10, 18.12), compared with (12.94, 12.70, 13.61) for the native writer. No general quality improvement is claimed. `research/gif-palette-performance.json` and `research/gif-palette-before.json` retain all three runs, source hashes, settings, and executable hashes.

A later 24-megapixel flat-color fixture exposed a native GIF reader limit. Independent Pillow and FFmpeg decoders read the file. The app now validates GIF pixels with the bundled decoder and prepares native input when needed. macOS viewers that use the same native reader can still fail to display that GIF. See [images to video](image-video.md#measured-cost) for the earlier failed benchmark and updated measurements.

Run `swift test --filter GIFPreparationTests` for large-image conversion, native color checks, single-frame animation, ICC data, automatic conversion, exact Undo, oversized input, and cleanup. Run `python3 tools/check-gif-reader.py` with Pillow for eight still-image/document routes, GIF/WebP animation pixels, alpha, disposal, delays, repeats, an independent Display P3 comparison, archive passthrough, malformed input, collisions, and source preservation. It reads the installed macOS Display P3 profile for a development fixture. The profile and fixtures are not shipped.

The packaged video benchmark uses original lossless FFV1 clips at 640 × 360 pixels and 15 frames per second. The artwork has flat colors and a moving rectangle. These are three-run medians for the complete command, including the preview, decode, encoding, and output checks. WebP uses quality 85 and effort 4. GIF uses 256 palette slots and dithering.

| Video frames | Output | Time | Reported peak RSS | Output size |
| ---: | --- | ---: | ---: | ---: |
| 30 | GIF | 0.13 s | 25.0 MB | 6,073 bytes |
| 30 | Lossless WebP | 0.24 s | 22.1 MB | 3,554 bytes |
| 30 | Lossy WebP | 0.47 s | 22.1 MB | 23,096 bytes |
| 120 | GIF | 0.33 s | 24.6 MB | 19,628 bytes |
| 120 | Lossless WebP | 0.72 s | 22.0 MB | 14,122 bytes |
| 120 | Lossy WebP | 1.67 s | 22.1 MB | 92,328 bytes |

These small flat-color clips favor lossless WebP. Photographic video can behave differently. The memory figures can include a child helper's peak; they do not measure aggregate simultaneous process memory and exclude the GUI. `research/video-animation-performance.json` records all runs, workload hashes, and matching packaged command and codec hashes.

[Animated WebP output](webp.md) uses the same image frame reader. Complete descriptive metadata retention, HDR video, track selection, and delays beyond one GIF frame remain in development. Full format and option parity is not complete.
