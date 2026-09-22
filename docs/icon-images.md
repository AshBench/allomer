# ICO and ICNS images

Rename a still image to `.ico` or `.icns` in a watched folder. The same conversion is available in the file picker. The app keeps the original for Undo.

ICO output contains seven square images: 16, 24, 32, 48, 64, 128, and 256 pixels. ICNS output contains the standard 16, 32, 128, 256, and 512-point images at both 1× and 2× resolution. Its largest image is 1024 pixels square.

The artwork keeps its aspect ratio and is centered inside each square. Unused space is transparent. Small source images are enlarged for larger icon sizes. Scaling can soften edges. Orientation is applied before scaling. The output uses 8-bit color and alpha. There is no lossy quality setting for these outputs.

## Reading an icon

An ICO or ICNS file can contain several sizes of the same artwork. Conversion selects the image with the largest pixel area. Greater bit depth breaks a tie; otherwise the first image reported by the native reader wins. Only that image is exported. Other sizes are not treated as animation frames or document pages.

The selected image connects through PNG to the existing image, PDF, tracing, and document conversions. PDF output embeds the artwork directly. OCR is used when selected. File contents determine the input format, so conversion also works after the extension has changed. Icon Composer package assets can use ICO and ICNS images through this same selection rule.

Converting one icon container into another generates a new size set from the selected image. It does not keep hand-edited artwork from smaller representations. Keep the source icon when those variants matter. Automatic conversion retains that complete source for Undo.

## Encoding and color

ICNS encoding uses macOS ImageIO with the size and DPI for each representation. ICO encoding uses native PNG images and a small original container writer. Its images use 8-bit RGBA PNG data. The [ICO directory layout](https://devblogs.microsoft.com/oldnewthing/20101018-00/?p=12513) and [PNG payload format](https://devblogs.microsoft.com/oldnewthing/20101022-00/?p=12473) are described by Microsoft. PNG-compressed ICO images require a reader with support for that format; Windows added it in Vista.

RGB profiles are retained where the native writers support them, unless sRGB conversion is selected. Other color models are rendered into sRGB. Native ICNS encoding can change the stored profile for smaller legacy representations. Independent checks compare their displayed colors after profile conversion. Metadata retention uses fields supported by the native writer. It does not preserve every source field or the original icon container metadata. No converter download, Xcode installation, or new bundled codec is needed.

## Bounds and checks

Input and output files are limited to 512 MiB. Inputs can contain at most 256 images and 256 million pixels in total. Each image uses the shared limit of 32 million pixels and 100,000 pixels per edge. Only the selected image is decoded. Icon output preparation requests a native thumbnail no larger than the largest target size. Each output size is rendered in turn. The app decodes every generated image and checks its dimensions before publication.

Timed images are refused. Manual conversion refuses existing destinations and symbolic-link sources. Source version checks and the existing rename transaction protect automatic conversion and Undo.

```sh
swift test --filter IconImageTests
python3 tools/check-icon-images.py
```

The Python check needs Pillow on the development machine. It reads ICO directory fields and every generated representation with independent readers. It checks size selection, transparency, all eight orientations, Display P3 color, SVG input, icon assets inside a project, invalid input, source preservation, collision refusal, cleanup, and rendered PDF pixels. Use `--command` and `--tools` to select the packaged app. Add `--benchmark-only` to record three complete conversions per workload and output type.

The Swift check covers conversion routes, every generated size, image and PDF outputs, timed-image refusal, automatic conversion, and exact Undo. Tests on the minimum supported macOS release remain part of release qualification.

## Measured cost

Three complete packaged conversions per original workload and output type on an M2 Max with macOS 26.6.2 gave these medians:

| PNG input | Output | Time | Peak RSS |
| --- | --- | ---: | ---: |
| 256-square artwork | ICO | 0.04 s | 22.4 MiB |
| 256-square artwork | ICNS | 0.06 s | 30.7 MiB |
| 1024-square noise | ICO | 0.06 s | 27.5 MiB |
| 1024-square noise | ICNS | 0.21 s | 57.8 MiB |
| 6000 × 4000 flat image | ICO | 0.10 s | 29.2 MiB |
| 6000 × 4000 flat image | ICNS | 0.13 s | 46.2 MiB |

These timings include thumbnail preparation, every output size, native decode validation, and publication. Python fixture creation and independent pixel reads are outside the timing. RSS is the process's high-water memory, not combined memory across simultaneous processes. GUI memory is excluded. Inputs, binary hash, output sizes, and all runs are recorded in `research/icon-image-performance.json`. These fixtures do not establish performance for every image codec or metadata payload.
