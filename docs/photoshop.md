# Photoshop images

PSD conversion exports the document's saved merged image. This works through the normal image, PDF, OCR, tracing, and icon routes. Automatic conversion keeps the full original PSD for Undo.

Save a merged image in the authoring app. Adobe calls this the **Maximize Compatibility** option. The [PSD specification](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/) explains that a document saved without this composite requires its layers to be rendered. This converter uses the saved composite and does not render those layers itself.

## Native reader preparation

The app prepares PSD encodings that the native reader cannot use reliably:

- ZIP and ZIP with prediction become uncompressed merged pixel data.
- 16-bit and 32-bit PackBits data becomes uncompressed merged pixel data.
- Uncompressed or ZIP-compressed 1-bit bitmap data becomes PackBits rows.

Other compatible raw and PackBits inputs go to ImageIO directly. Preparation copies the header, color data, image resources, and layer/mask section without changing their bytes. Only the merged pixel encoding changes. ImageIO handles the final image conversion.

ZIP prediction is reversed within each row. The 16-bit path uses sample arithmetic. The 32-bit path restores byte lanes after byte prediction. Preparation preserves the decoded sample bytes. The output format and native writer determine the final precision, profile handling, and metadata. For example, the checked 32-bit RGB fixtures produce 16-bit PNG output.

No codec download or new bundled helper is needed. ZIP decoding uses system zlib. The app uses an original PackBits reader and literal-row writer for the required preparation paths.

## Bounds and source handling

Source and prepared files must each fit within 512 MiB. A compressed PSD can exceed the prepared-file limit even when its source file is smaller. Dimensions are limited to 30,000 pixels per edge and 32 million pixels in total. There can be up to 56 channels. Bit depths are 1, 8, 16, and 32. ZIP prediction is not accepted for 1-bit images. Bitmap mode uses one channel.

The reader checks section lengths before seeking. It reads through a file descriptor without following a source link. Preparation uses bounded input, row, and output buffers. High-precision PackBits also uses its bounded row-length table. The prepared file is created exclusively in the private conversion folder. Source version checks cover preparation and final publication.

Preparation refuses truncated streams, corrupt checksums, extra compressed streams, incorrect row lengths, and data beyond the declared pixel count. A failure removes the private preparation and keeps the source. Archiving bypasses image preparation and keeps the original file bytes, including a file that cannot be decoded as an image.

## Checks and remaining limits

Independent fixtures cover all four compression methods, 8/16/32-bit RGB, grayscale, indexed color, CMYK, Lab, 1-bit bitmap images, Display P3 resources, a large opaque resource block, and an original layer with binary transparency. They include compression and row boundaries, incorrect extensions, invalid input, archive passthrough, collision refusal, and cleanup. Swift checks compare complete prepared sample bytes against independent encoded fixtures and verify automatic conversion with exact Undo.

Fractional composite transparency needs more fidelity checks. Synthetic files without a layer section gave different interpretations in independent readers. Documents without saved composites, PSB large documents, and complete layer/metadata fidelity remain open. The compression checks do not establish support for every Photoshop feature or every damaged file.

```sh
swift test --filter PSDCompressionTests
python3 -m venv .tools/psd-check-venv
.tools/psd-check-venv/bin/python -m pip install -r tools/requirements-psd-check.txt
.tools/psd-check-venv/bin/python tools/check-psd.py
```

These Python packages are development dependencies only. They are not included in the app. Use `--command` and `--tools` to check the packaged app. `--oracle-path` can select a separate directory of installed test packages. `--benchmark-only` records three complete conversions per workload and compression method in `research/psd-performance.json`.

## Measured cost

Three complete packaged conversions to PNG per workload and compression method on an M2 Max with macOS 26.6.2 gave these medians:

| PSD input | Compression | Time | Peak RSS |
| --- | --- | ---: | ---: |
| 1024-square RGB8 noise | Raw | 0.17 s | 28.0 MiB |
| 1024-square RGB8 noise | PackBits | 0.17 s | 28.1 MiB |
| 1024-square RGB8 noise | ZIP | 0.18 s | 31.4 MiB |
| 1024-square RGB8 noise | ZIP prediction | 0.20 s | 31.4 MiB |
| 1024-square RGB16 gradient | Raw | 0.10 s | 35.0 MiB |
| 1024-square RGB16 gradient | PackBits | 0.11 s | 43.5 MiB |
| 1024-square RGB16 gradient | ZIP | 0.11 s | 35.4 MiB |
| 1024-square RGB16 gradient | ZIP prediction | 0.13 s | 35.4 MiB |
| 6000 × 4000 RGB8 flat image | Raw | 0.82 s | 181.4 MiB |
| 6000 × 4000 RGB8 flat image | PackBits | 0.84 s | 113.8 MiB |
| 6000 × 4000 RGB8 flat image | ZIP | 0.88 s | 181.7 MiB |
| 6000 × 4000 RGB8 flat image | ZIP prediction | 1.37 s | 181.7 MiB |

These timings include preparation when needed, native image encoding, PNG recompression, validation, and publication. Source integrity reads warm the file cache. Python fixture creation and pixel checks are outside the timing. RSS is the process's high-water memory, not combined memory across simultaneous processes. GUI memory is excluded. Input sizes and hashes, the command hash, output sizes, and all runs are in `research/psd-performance.json`. These fixtures do not establish performance for every PSD document.
