# Audio conversion

Rename an audio file in a watched folder to convert it. Manual conversion uses the same engine. The app keeps the original for exact Undo. The bundled encoders work offline.

## Quality and compression

Audio mode defaults to **Quality**, with quality set to 100%. Higher settings can produce larger files. Lossy output still loses some audio information at 100%.

MP3, AAC, M4A, and Ogg support the quality control. Their **Bitrate** mode uses the audio bitrate setting. Opus, WMA, AC3, and EAC3 use bitrate in both modes. The default is 192 kb/s and the range is 8–1536 kb/s, with the arrows moving in steps of 8. Opus uses variable bitrate, so the value is a target. Codec limits can restrict the accepted bitrate, sample rate, and channel count.

FLAC compression defaults to 8. Its range is 0–12. This changes encoding effort and file size. It does not change the decoded samples. MKA also uses this FLAC setting. Lossless and uncompressed outputs ignore the lossy quality and bitrate controls.

| Output | Audio encoding |
| --- | --- |
| MP3 | MP3 |
| AAC | AAC in an ADTS stream |
| M4A | AAC in an MP4 audio container |
| Ogg | Vorbis |
| Opus | Opus in Ogg |
| WMA | Windows Media Audio 2 |
| AC3, EAC3 | AC-3, Enhanced AC-3 |
| FLAC, MKA | Lossless FLAC |
| ALAC | Apple Lossless |
| WAV, CAF | Uncompressed 24-bit little-endian PCM |
| AIFF, AU | Uncompressed 24-bit big-endian PCM |
| TTA | Lossless True Audio |
| WV | Lossless WavPack |

Sample rate and channel count default to **Keep source**. Changing either can change the decoded samples, including in a lossless container. Converting a lossy source to a lossless output cannot recover discarded information.

Opus declares a 48 kHz playback rate even when its encoder input uses a lower rate.

Audio quality and FLAC compression settings apply to audio outputs. Audio inside a video output continues to use the audio bitrate setting.

## Audio in video containers

Audio files can also convert to AVI, M2TS, MKV, MOV, MP4, MPEG, TS, VOB, WebM, and WMV. The output contains one audio track and no picture track. Conversion uses the destination's audio codec directly. It does not need an intermediate video file.

Audio bitrate, sample rate, channel count, and metadata settings still apply. Video controls are hidden for known audio inputs. A saved video codec does not create a picture track. Cover art must be removed for these outputs. 3GP, FLV, and MXF still require video.

## Extraction and timing

Audio-only output starts at the first decoded audio sample. A video track's start time or length does not determine the extracted audio's length. This also applies to audio files with a nonzero timestamp origin.

Pauses stored in timestamps become silence. Timestamp differences above one millisecond can cause silence insertion or removal of overlapping samples. The one-millisecond threshold avoids treating ordinary clock rounding as a pause. These operations change the decoded sample count when the input timeline is discontinuous.

Standalone Ogg/Vorbis uses its decoded sample count as the clock. Vorbis block changes can produce misleading packet times even when the audio is continuous. Counting samples prevents false silence insertion at those boundaries. Decoder trimming still applies before this step.

The converter captures prepared source audio timing during encoding and fully decodes the output once. It compares sample duration and playback span. Each temporary timeline has a 64 MiB limit and is read in 64 KiB blocks. Codec padding has a separate allowance. These limits are not a total memory quota.

One FFmpeg filter graph shares the prepared audio between the encoder and timing output. This avoids stalls caused by separate graphs when an encoder needs more samples for its first packet. Only the timing branch becomes 16-bit PCM; it must not reduce the encoded audio's precision. The selected CPU profile also limits this graph's worker threads. Track names, language tags, and playback flags are copied explicitly because filtered outputs do not inherit them.

FLAC, WAV, AIFF, AU, CAF, TTA, and WV also check the source stream's declared duration when available. This rejects the checked FLAC file cut at a complete frame boundary, even though its remaining frames decode without an error. Streaming FLAC without a declared sample count can still convert. Arbitrary damaged files and all timestamp discontinuities are not yet qualified.

WMA output prefixes one silent codec window so the encoder does not discard opening sound. It adjusts the timestamps to preserve the original sample positions. This applies to both WMA and WMV output. The checked 8, 16, 22.05, 32, 44.1, and 48 kHz outputs retain opening and closing tones. WMA output requires a sample rate at or below 48 kHz.

Raw ADTS AAC can retain about 1024 samples of codec delay. AC3 and EAC3 can retain about 256 samples. Containers with gapless-playback information can behave differently. Exact sample alignment is not promised for every lossy output.

MP2, AC3, and EAC3 receive a short silent tail so encoder delay cannot cut off the closing sound. The tail contains 481 samples for MP2 and 256 for AC3/EAC3, counted at the encoder's sample rate. The source timing check excludes this padding. The encoded result can retain final silence rounded to a codec frame.

### Short Vorbis input

The bundled decoder corrects timing when the first audio page also ends the Ogg stream. It accounts for the first packet's decoder setup time before sample zero. This follows the [Vorbis overlap and packet timing rules](https://xiph.org/vorbis/doc/Vorbis_I_spec.html). The checked 0.75-second file now retains all 36,000 samples through Ogg-to-WAV conversion. Its values match the independent libvorbisfile reader within one 16-bit level. No silence is added to replace the missing tail.

The regression check compares exact sample counts and values across four sample rates, mono and stereo, four short durations, three quality levels, both decoders, ordinary reads, pipes, and seeks to zero.

### Chained Vorbis input

An Ogg chain joins several encoded streams in one file. The decoder loads each link's settings and keeps the audio timeline continuous. The checked chains retain every sample across changes in quality and codebooks. They include links shorter than one codec window.

All links must use the same sample rate and channel count. Changes to either are refused. Checks also reject corrupt setup headers and audio before a complete header group. These failures publish no output. Source files are preserved. The checks cover opening a new input at time zero; general seeking across chains remains unqualified.

## Embedded cover art

**Keep embedded cover art** defaults to on. It works separately from **Keep media metadata**. Turning general metadata off can remove the track title while retaining its cover image.

| Output | Current cover-writing path |
| --- | --- |
| MP3, M4A, ALAC, FLAC, AIFF | Embedded picture stream |
| MKA | Embedded image attachment |
| Ogg, Opus | One embedded picture metadata block |
| AAC, WAV, WMA, CAF, AC3, EAC3, AU, TTA, WV | Cover writing is unavailable in the current converter |

If preservation is on and the output cannot keep a source picture, conversion stops with the source intact. Turn it off to omit pictures. The app does not search nearby folders, download art, or write image sidecars.

The current path accepts embedded PNG, JPEG, and BMP images. It preserves their encoded bytes, except that MKA converts BMP covers to PNG. That conversion checks decoded pixels and native color data. MKA names its first picture `cover.png` or `cover.jpg`, following the [Matroska cover guidelines](https://www.matroska.org/technical/attachments.html).

The app checks the result's image count, attachment status, codec, dimensions, and extracted bytes before publication. Picture type and description fields differ between containers. Some containers cannot retain those fields even when they retain the image.

Cover handling accepts up to eight images, at most 8 MiB per image and 32 MiB combined. Each image must have at most 32 million pixels. Ogg and Opus accept one cover through the current metadata writer. Multiple covers for those outputs stop conversion. Temporary images and metadata files stay in the private conversion folder and are removed after success or failure.

The media path accepts one audio stream. Unrelated attachments and additional audio, video, or subtitle tracks still need selection controls. General media metadata retention does not promise that every tag has a matching representation in every container.

Video outputs currently require cover removal when the source has embedded art. Their settings expose the same retention toggle.

## Development checks

Run `swift test --filter AudioOptionsTests` for old saved settings, automatic cover retention, explicit removal, failed conversion, and exact Undo. Run `python3 tools/check-audio-options.py` for the original audio and picture fixtures. It accepts `--command` and `--tools` to check a packaged app outside development paths.

The packaged check passes 125 cases. These include all 17 audio outputs, quality endpoints, bitrate control, FLAC compression, exact lossless samples, metadata, PNG/JPEG/BMP art, converted BMP pixels, multiple covers, source preservation, and cleanup. Nine pictures and options files above 64 KiB are refused. These checks do not cover every malformed image or file-size limit.

Run `python3 tools/check-audio-containers.py` for the audio-only video containers. It converts all 17 audio inputs to AVI, M2TS, MPEG, TS, VOB, and WMV. It also checks six 20 ms inputs, 15 endings around MP2 and AC3 frame boundaries, six occupied destinations, and six malformed inputs. Each success must contain one audio stream and no video stream. The check verifies the codec, container, sample rate, channels, opening and closing sounds, source bytes, and temporary-file cleanup.

Run `python3 tools/check-audio-timing.py` for 1,400 checks. Original tones check nine track timing/length patterns across all 17 audio outputs. A group of 64 TTA/WMV conversions runs with four workers and a five-second converter limit to check for stalls. All nine lossless outputs must retain exact 24-bit samples. The Vorbis cases include seven Ogg-to-WAV conversions and 1,152 independent decoder comparisons. They also check changed stream parameters and bad or missing setup headers. Other cases cover WMA sample rates, truncated FLAC, unknown-length FLAC, source bytes, and cleanup. The check compiles an independent Vorbis reader from the existing media build's libraries. That reader is a development tool and is not included in the app. All three audio tools accept `--command` and `--tools` for a packaged app.

Use `--benchmark-only` for three complete M4A, Ogg, and MKA conversions with cover retention on and off. Run it without other builds or conversions. The source has 60 seconds of original stereo audio at 48 kHz and one 2048-square PNG. The report records options, artifact hashes, every run, output checks, and measurement limits in `research/audio-options-performance.json`.

The audio-timing checkpoint on an M2 Max with macOS 26.6.2 gives these medians. The report records that build's command hash:

| Output | Drop cover | Keep cover | Peak process memory, drop / keep |
| --- | --- | --- | --- |
| M4A | 1.78 s | 1.82 s | 26.8 / 36.0 MiB |
| Ogg | 0.70 s | 0.77 s | 27.2 / 37.9 MiB |
| MKA | 0.42 s | 0.48 s | 25.6 / 32.0 MiB |

Against the preceding synchronization build, the added audio timing checks cost 0.04–0.10 seconds per conversion in this workload. Median peak process memory rises by at most about 0.5 MiB. Both runs use the same source bytes and media helpers. The preceding measurements are retained in `research/audio-timing-performance-before.json`.

The source is 3,430,645 bytes, including a 1,668,525-byte cover. Measurements include probing, picture validation, audio encoding, result checks, and publication. Source hashing warms the cache. They exclude the GUI, fixture generation, and independent Python checks. Memory is a per-process peak, not the combined use of simultaneous app and helper processes. The invented signal is not a listening-quality or general music benchmark.

The command accepts `--media-options FILE.json`. Omitted keys use defaults. For example:

```json
{
  "audioMode": "quality",
  "audioQuality": 75,
  "flacCompressionLevel": 8,
  "preserveCoverArt": true
}
```

The app maps quality 0–100 to the bundled encoders as follows. These are this app's mappings. They are not a common scale of perceived sound quality.

| Encoder | Quality argument |
| --- | --- |
| LAME MP3 | `-q:a` from 9 to 0 |
| Native AAC | `-q:a` from 0.1 to 5 |
| Vorbis | `-q:a` from 0 to 10 |

AAC has no fixed published maximum for this setting. The positive 0.1–5 interval is an app choice. Vorbis's underlying encoder also supports −1, but the current FFmpeg command ignores a negative `-q:a`. This app uses the working 0–10 interval.

The source and encoder versions remain in the shared dependency catalog. This feature adds no codec library, helper executable, or model download. Full input coverage, advanced track controls, and release qualification remain in progress.
