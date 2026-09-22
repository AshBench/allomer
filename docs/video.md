# Video conversion

Video conversion uses bundled media tools and works offline. Manual conversion, automatic conversion, and the command use the same settings. Automatic conversion retains the original for exact Undo.

## Current outputs

| Container | Automatic codec | Other choices |
| --- | --- | --- |
| MP4 | H.264 | HEVC, VP9, AV1 |
| MOV | H.264 | HEVC, ProRes |
| MKV | H.264 | HEVC, VP9, AV1, ProRes, FFV1, MPEG-2, MS MPEG-4 v3 |
| WebM | VP9 | AV1 |
| 3GP, FLV | H.264 | — |
| M2TS, TS | H.264 | MPEG-2 |
| AVI | MPEG-4 Part 2 | MPEG-2, MS MPEG-4 v3 |
| MXF, MPEG, VOB | MPEG-2 | MPEG-2 selected explicitly |
| WMV | Windows Media Video 2 | MS MPEG-4 v3 |

An incompatible codec stops conversion with the source intact. Select Automatic or a supported codec. H.264, HEVC, and ProRes use Apple VideoToolbox with software fallback permitted. VP9 and AV1 use bundled software encoders. HEVC in MP4 and MOV uses the `hvc1` tag. FFV1 is a lossless software encoder offered for MKV. It preserves a decoded pixel format that the encoder supports and ignores quality and bitrate. A source with an unsupported decoded pixel format is refused instead of being reduced to 8-bit 4:2:0.

Ten containers also accept audio input without a picture track. These are AVI, M2TS, MKV, MOV, MP4, MPEG, TS, VOB, WebM, and WMV. See [audio-only container output](audio.md#audio-in-video-containers) for settings and limits.

## Settings

New settings default to Automatic codec, Quality mode at 100%, and Preserve source frame rate. Saved settings from the earlier bitrate-only version retain their bitrate mode and value. Quality 100% can produce very large files and does not promise lossless conversion. Use a lower quality or bitrate mode when size matters.

| Setting | Range or choices | Default |
| --- | --- | --- |
| Mode | Quality, Bitrate | Quality |
| Quality | 0–100% | 100% |
| Video bitrate | 32–200,000 kb/s, in steps of 50; AV1 maximum 100,000 | 2500 kb/s |
| Frame rate | Preserve source; 23.976, 24, 25, 29.97, 30, 50, 59.94, 60 fps | Preserve source |
| VP9 speed | 0–8 | 1 |
| AV1 speed | 0–13 | 8 |
| ProRes profile | Proxy, LT, Standard, HQ, 4444, 4444 XQ | HQ |

The fractional rates use 24000/1001, 30000/1001, and 60000/1001. Lower speed settings take longer and can compress more efficiently. ProRes uses its profile instead of the quality or bitrate setting. FFV1 ignores both because its output is lossless. Audio inside video uses the audio bitrate setting, initially 192 kb/s where supported.

Quality maps to VideoToolbox's 1–100 quality setting, VP9 CRF 63–0, AV1 CRF 63–1, or quantizer 31–2 for the older MPEG and WMV encoders. macOS 14 rejects the VideoToolbox quality property. On that system, H.264 and HEVC use a logarithmic 32–100,000 kb/s compatibility range instead. Later macOS versions keep the native quality setting. These scales are codec-specific. They are not equivalent quality levels across codecs. VP9 at quality 100 reaches CRF 0, which keeps 8, 10, and 12-bit planes exactly; the development check compares those pixels byte for byte. AV1 avoids CRF zero because the FFmpeg wrapper does not apply that value as an explicit quality setting.

MPEG and VOB set a peak rate and matching decoder buffer. In bitrate mode, the peak is twice the target and the buffer holds at least one second at that target. The buffer cannot exceed the container limit. Quality mode uses the same bounded container buffer. Very low rates, unusual frame rates, or unsupported dimensions can still fail.

For the command, pass a JSON file with `--media-options`:

```json
{
  "videoCodec": "av1",
  "videoMode": "quality",
  "videoQuality": 80,
  "videoFrameRate": "30000/1001",
  "av1Speed": 8
}
```

## Color and transparency

H.264, MPEG, and WMV output use 8-bit 4:2:0 color. HEVC and AV1 use 10-bit output for sources above 8 bits. VP9 supports 8, 10, and 12 bits. Higher-depth sources can still lose precision when the chosen codec has a lower limit. Chroma subsampling can also discard color detail.

ProRes Proxy through HQ use 10-bit 4:2:2. ProRes 4444 and 4444 XQ use 12-bit 4:4:4 with alpha. The app verifies the output codec, bit depth, and ProRes profile. Original alpha ramps pass a decoded-alpha comparison within one 8-bit level. HDR tone mapping, mastering metadata, all source color profiles, and broader alpha fidelity still need qualification.

Image input uses the existing GIF preparation route. Its palette and binary transparency limit the result before video encoding. See [images to video](image-video.md).

## AV1 input

The bundle includes [dav1d](https://www.videolan.org/projects/dav1d.html) 1.5.4 for software AV1 decoding. It works on Apple Silicon Macs without AV1 hardware decoding. It is part of the shared media library and needs no separate installation.

Original 8-bit and 10-bit AV1 clips pass decoding in MKV, MP4, and WebM on an M2 Max. The 8-bit MKV clip passes all 13 video outputs. The other five input combinations pass MP4 output. These checks cover one-second, 720 × 576 clips at 25 frames per second, with one audio track. They do not establish all AV1 profiles, film-grain modes, HDR behavior, or 12-bit input.

## Timing and validation

Preserve source keeps source pictures and their relative timing within the codec and container clocks. AVI and MXF can add black frames to represent a track delay. MPEG-2 and MPEG-4 Part 2 can quantize times to a frame clock. ASF/WMV does not store each frame's duration, so the final-duration check allows uncertainty up to the shorter final frame duration. A fixed rate can add or drop frames and change the end by up to one selected frame interval. Incompatible timing stops conversion before publication.

The source timeline is captured during conversion. Video uses a metadata-only frame wrapper. It shares decoded frame references and does not hash pixel planes. Audio uses PCM timing records. The output picture and sound streams are fully decoded once for validation. Each temporary timeline has a 64 MiB limit and is read in 64 KiB blocks. Default image/GIF timing uses its established complete playback check. Codec and input allocations are bounded individually; these bounds are not a total process-memory quota. Video frames are limited to 32.2 million pixels.

Timing records use a short queue for sorting packets across tracks. This releases picture references sooner when one track ends early. The reader compares each track separately, so it does not need records from different tracks to be sorted together. Decoder and other pipeline buffers still consume memory.

Checks also cover the container, stream count, dimensions, audio channels, and requested sample rate. Video output uses decoded timing because WMV and transport-stream header durations can be inaccurate. Audio start and end times are checked relative to the picture stream. The check also compares total decoded audio sample duration. Allowances account for video clock precision, codec delay, and final audio padding. This does not compare the content of every audio sample or prove all internal timing behavior. Multiple tracks, subtitles within video output, and unrelated attachment selection remain open work. See [audio conversion](audio.md) for cover-art limits.

### Delayed and unequal tracks

AVI starts its tracks at zero. The app turns an audio delay or gap into silence and a video delay into black frames. It also prevents MP3 encoder preroll from inserting an extra interval into the picture timeline. AVI's MP3 audio can still have about 23 ms of codec delay. Exact sample alignment is not promised for that container.

WMV also turns audio delays and gaps into silence. WMA's encoder receives a silent prefix with adjusted timestamps to preserve opening sound. The source timing check excludes this encoder-only prefix. The shared audio gap threshold is one millisecond. See [audio timing](audio.md#extraction-and-timing) for codec limits.

MXF requires matching track spans. The app fills missing video with black and missing audio with silence. It performs one extra bounded source decode for MXF with audio to find the actual track ends before conversion. This keeps a longer track from being cut to match a shorter one. The prepass uses the selected CPU profile's decode thread count. Other containers retain their supported timestamp offsets and unequal spans.

CPU profiles balance concurrent conversions and software work. Their thread settings are not hard limits on all library or system threads. AV1 uses the encoder's two-processor scheduling policy in every profile. This avoids a crash observed with its single-processor policy in the current FFmpeg integration. It does not guarantee exactly two threads.

## Development checks

Run `python3 tools/check-video-options.py` for 95 conversions and refusals. It checks codec/container choices, quality endpoints, bitrate, six ProRes profiles, alpha, high bit depth, variable timing, fixed rates, speed endpoints, GIF input, invalid settings, source bytes, and cleanup. VP9 at quality 100 and FFV1 retain the original 10-bit and 12-bit test planes exactly. That result applies to these matching planar inputs.

Run `python3 tools/check-av1.py` for AV1 input checks. It accepts `--command` and `--tools` for a packaged app. It counts actual decoded frames, compares decoded pixels across decoder thread settings, checks audio, and verifies source preservation and failed-output cleanup. Input timelines are checked exactly. Converted timelines permit one frame of quantization. A detailed fixture also checks MPEG decoder-buffer handling. An empty decode cannot pass merely by returning exit code zero.

The AV1 checker covers 18 conversions and a truncated-input refusal. Both tools accept `--command` and `--tools` for a packaged app. These are development checks, not additional per-file checks performed by the app. `swift test` also checks saved settings, malformed timelines, automatic conversion, and exact Undo. Minimum-system runtime qualification remains open.

Run `python3 tools/check-media-sync.py` for 121 synchronization cases. Original flashes and tone bursts test all 13 containers with aligned tracks, delayed audio or video, shorter audio or video, 20/50/200 ms audio gaps, and a five-second timestamp origin. Four additional cases use 29.97 fps. The check decodes picture and sound events, verifies their relative times, counts expected frames, checks black padding, and verifies source bytes and cleanup. At 25 fps, AVI event offsets remain within one frame; the other tested containers remain within 2 ms. Fractional-rate cases allow one selected frame plus 2 ms. These short fixtures do not establish all codecs, long-recording clock drift, or malformed source timing. The tool accepts `--command` and `--tools` for a packaged app.

The same check verifies track names, languages, and default/original flags in MKV output. Each stream shares one filter graph between encoding and timing capture. Audio and video use separate graphs so one track cannot retain the other's frames. The source-timing audio branch has its own 16-bit conversion so it cannot reduce the encoder's sample precision. See [audio conversion](audio.md) for the concurrent conversion and lossless-sample checks.

## Measured cost

### Complete MXF conversion

Three isolated packaged runs per setting use a 30-second, 1280 × 720 FFV1 clip at 24 fps with aligned stereo PCM audio. The machine is an M2 Max with macOS 26.6.2. Each result has 720 decoded pictures and the checked audio sample count.

| Build and setting | Median time | Median peak process RSS | MXF bytes |
| --- | ---: | ---: | ---: |
| Before audio timing changes, 2500 kb/s target | 15.89 s | 61.70 MiB | 39,447,633 |
| Audio-timing checkpoint, 2500 kb/s target | 15.80 s | 63.64 MiB | 39,447,633 |
| Audio-timing checkpoint, quality 100 | 20.19 s | 62.16 MiB | 552,780,369 |

Separate audio/video filter graphs keep memory close to the preceding build. An intermediate build put both tracks in one graph and reached a 205.81 MiB median in an earlier run of this fixture recipe. Each stream still shares its own graph between encoding and timing capture. Quality 100 again produces a much larger file.

Run `python3 tools/measure-video-options.py --before-app /path/to/previous.app --with-audio --container mxf --report research/audio-timing-mxf-performance.json`. The report records all runs and hashes. It includes conversion, validation, and publication. Source hashing warms the cache. Fixture creation, independent output checks, and the GUI are excluded. RSS includes child-process peaks on this system, but does not sum simultaneous processes or native services. These short samples are not general speed, quality, or memory guarantees.

Earlier synchronization work added a source prepass and output validation. In that comparison, conversion time rose from 8.18 to 15.78 seconds at the same bitrate target. Those measurements remain in `research/media-sync-mxf-performance.json`. The intermediate combined-graph measurements remain in `research/audio-timing-mxf-combined-performance.json`.

### Timing helper with unequal tracks

Three isolated helper runs use a 30-second, 1280 × 720 FFV1 picture track at 24 fps and a four-second stereo PCM track. The machine is an M2 Max with macOS 26.6.2. All picture timing and size records, audio timing and checksums, and decoded sample counts match across settings.

| Timing settings | Median time | Median helper peak RSS |
| --- | ---: | ---: |
| Default sorting queue, one decode thread | 15.22 s | 662.39 MiB |
| Short sorting queue, one decode thread | 15.16 s | 481.41 MiB |
| Short sorting queue, two decode threads | 7.69 s | 490.69 MiB |

The smaller queue reduces the measured memory peak. The existing Medium CPU profile halves this prepass time in this workload. Other pipeline buffers still use substantial memory. These settings do not impose a total memory quota.

Run `python3 tools/measure-video-options.py --timing-only --report research/video-timing-performance.json` to reproduce this helper check. It includes only the timing decode, with source hashing used to warm the file cache. It excludes fixture creation, conversion, publication, and the GUI. The report keeps all runs and source/helper hashes. This is a different workload from the complete conversions below.

### Earlier video-control checkpoint

Three isolated packaged runs at the earlier video-control checkpoint on an M2 Max used the same 30-second, 1280 × 720 FFV1 clip at 24 fps. The clip repeats a detailed one-second pattern and has no audio. All outputs contain 720 decoded frames. These readings precede the audio synchronization checks.

| Build and setting | Median time | Median peak process RSS | MP4 bytes |
| --- | ---: | ---: | ---: |
| Previous build, 2500 kb/s target | 7.83 s | 76.00 MiB | 15,988,057 |
| Video-control checkpoint, 2500 kb/s target | 10.53 s | 79.03 MiB | 15,991,897 |
| Video-control checkpoint, quality 100 | 19.65 s | 112.89 MiB | 786,471,148 |

The new conversion and validation path costs 2.70 seconds more at the same bitrate setting in this workload. Quality 100 takes longer and produces a much larger file. A bitrate target is not an exact output-size or average-rate guarantee, particularly for difficult input.

Run `python3 tools/measure-video-options.py --before-app /path/to/previous.app` to reproduce the comparison. `research/video-options-performance.json` retains all runs, options, and hashes. The readings include conversion, validation, and publication. They exclude fixture creation, external output checks, and the GUI. RSS is a per-process high-water reading. It does not sum simultaneous helpers or native services. These samples do not establish general quality or performance.
