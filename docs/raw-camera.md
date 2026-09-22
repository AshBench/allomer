# Camera RAW images

The app reads camera RAW files through macOS ImageIO. It exports the full image reported by that reader. File contents identify the format, so the source can still be read after its extension changes in a watched folder.

The catalog includes CR2, NEF, ARW, DNG, PEF, RAF, ORF, and RW2. Camera support depends on the macOS version and its RAW reader. Apple exposes the installed camera list through [`CIRAWFilter.supportedCameraModels`](https://developer.apple.com/documentation/coreimage/cirawfilter/supportedcameramodels). A file extension alone does not establish support for every camera or recording mode.

A misleading extension can make ImageIO report a TIFF preview or no usable image for a RAW file. When it reports TIFF, the app tries native RAW type hints. A hint must return the matching type, one image, and readable dimensions. Identified RAW files use a private copy with the normal extension when needed. The copy preserves the source bytes and is removed after conversion. This preparation serves all image routes, including [video output](image-video.md). Ordinary camera-tagged TIFFs remain TIFFs.

## Checked cameras

These pinned [CC0 samples from raw.pixls.us](https://raw.pixls.us/) are used for development checks. On macOS 26.6.2, ImageIO reports one primary image for each file. Its dimensions match the native RAW filter's full image size.

| Format | Camera | Full image |
| --- | --- | --- |
| CR2 | Canon EOS 7D | 5184 × 3456 |
| NEF | Nikon D90 | 4288 × 2848 |
| ARW | Sony NEX-5 | 4592 × 3056 |
| DNG | Pentax K10D | 3872 × 2592 |
| PEF | Pentax K10D | 3872 × 2592 |
| RAF | Fujifilm X-T1 | 4896 × 3264 |
| ORF | Olympus E-M5 | 4608 × 3456 |
| RW2 | Panasonic DMC-GF1 | 4000 × 3000 |

PNG and TIFF output retain 16-bit color and a color profile for these samples with the default image settings. JPEG output also passes full-size and profile checks. Native RAW processing determines the rendered appearance. The output is a developed image. It does not contain the original sensor data or editable RAW adjustments.

No RAW codec, helper, or download was added to the app. End users need only the app and a supported macOS version. The sample files and Python image reader are development dependencies. They are not shipped.

## Limits and reproduction

The shared image limits apply: 512 MiB per file, 32 million pixels per image, and 100,000 pixels per edge. This excludes some high-resolution cameras even when macOS supports their RAW encoding. Unsupported or oversized conversions keep the source. Automatic conversion retains the complete RAW file for Undo.

Camera files can contain different compression modes, crops, previews, and sensor layouts. These eight samples establish a tested starting set. Other cameras and recording modes, recent DNG features, and the minimum supported macOS release need more checks. Color and metadata retention follow the native reader and output writer.

```sh
python3 tools/check-raw.py --download
ALLOMER_RAW_FIXTURES="$PWD/.tools/raw-check" swift test --filter RawCameraTests
python3 tools/check-raw.py --sample eos-7d.cr2 --formats png jpg --runs 3 \
  --report research/raw-performance.json
```

The check needs Pillow. It uses the packaged app by default. `--command` and `--tools` can select another build. Downloads are optional and explicit. Each sample is checked against its recorded SHA-256 before use. Source URLs, licenses, expected dimensions, and hashes are in `tools/raw-samples.json`.

The Python check reads generated PNG, JPEG, and TIFF images with Pillow. It checks dimensions, profiles, bit depth, source preservation, changed extensions, collisions, invalid input, and private-folder cleanup. Each camera file is also checked after its name gains a JPG, PNG, or TIFF extension. Exported TIFF files convert back to full-size JPEG, with a reduced-image pixel check. The Swift check covers available routes, automatic conversion, and exact Undo. Its camera sample test skips when the fixture environment variable is absent. A separate test always checks ordinary TIFFs with camera metadata.

Reported command times include native RAW decoding, output encoding, validation, and publication. PNG also includes its compression-level pass. Python image checks and GUI memory are excluded. Source integrity reads warm the cache. RSS is per-process high-water memory, not aggregate memory across simultaneous processes. A single run is a functional check, not a stable performance estimate.

## Measured cost

Three complete packaged conversions of the 5184 × 3456 Canon EOS 7D sample on an M2 Max with macOS 26.6.2 gave these medians:

| Output with default settings | Time | Peak RSS | Output bytes |
| --- | ---: | ---: | ---: |
| JPEG, quality 0.85 | 0.73 s | 294.4 MiB | 3,781,578 |
| 16-bit PNG, compression level 6 | 16.88 s | 296.1 MiB | 69,123,738 |

The two outputs have different precision and compression. The PNG path keeps 16-bit color and recompresses the native writer's filtered data at the requested level. A separate profile of that pass placed about 97% of sampled work inside system zlib's compressor. Full-color camera images can therefore cost much more time than flat synthetic fixtures. The measurements do not imply that every camera or scene has the same cost.

These performance runs predate the changed-extension preparation fix. Their binary hash is in `research/raw-performance.json`. Current packaged format checks are in `research/raw-check.json`. Package sizes and earlier baselines are in `research/package-size.json`.
