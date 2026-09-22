# Icon Composer artwork

Rename an `.icon` project to `.png`, `.jpg`, `.tiff`, `.bmp`, `.gif`, `.webp`, `.heic`, or `.avif` in a watched folder. The app exports its artwork layers. Manual conversion uses the same engine. Other available image and document routes connect through PNG.

An Icon Composer project is a package: a directory containing `icon.json` and an `Assets` directory. The app includes a package type declaration so Finder can recognize the format without Xcode. App users need no Icon Composer installation or additional renderer download.

## Artwork behavior

The output uses a transparent 1024 × 1024 canvas. Groups and layers draw from back to front; the first entry in each array is frontmost. Assets keep their intrinsic pixel dimensions and are centered on the canvas. Scale and translation move them around that center. Positive x moves right; positive y moves down. Raster orientation metadata is included when calculating displayed dimensions.

Hidden layers and groups are omitted. Layer and group opacity apply to their combined artwork. Default or light opacity specializations override the base opacity. Dark-only overrides do not change this default artwork export. Missing and automatic opacity values use the base opacity, or full opacity if no base value exists. Layers without an image name have no artwork to draw.

SVG assets use the existing local SVG renderer. Still bitmap assets use the normal image conversion engine, including its input validation. Each distinct asset is prepared once and reused in the composition. Native resampling can soften edges and create a one-pixel fringe when an image is scaled. SVG assets are rasterized at their intrinsic dimensions before composition; enlargement can reduce edge sharpness.

This exports the underlying artwork. It does not reproduce Icon Composer's Liquid Glass materials, background fills, enclosure masks, lighting, shadows, blur, refraction, or other appearance styling. Embedded image metadata is not combined into output metadata. Prepared pixels use 8-bit sRGB. These are visible limits, not a claim that the result matches Icon Composer's styled preview.

## Source protection and limits

Automatic conversion retains the whole original package. Undo restores its filenames, contents, and original directory inode. A package snapshot includes every file and directory, including unused assets and empty directories. Changes to a nested file are detected even when the package root's metadata stays unchanged. Recovery journals can reconcile a package-to-file replacement after interruption.

The reader rejects symbolic links, special files, missing assets, unsafe asset paths, malformed JSON, and timed images. Bounds are 1 MiB for `icon.json`, 4,096 package entries, 16 folder levels, 128 MiB per file, and 512 MiB in total. The composition permits 128 top-level groups, 1,024 nodes, and 16 nested layer levels. Prepared images are limited to 32 million pixels and the composition to 64 MiB. Scale must be finite and within ±10,000; each translation must be finite and within ±1,000,000 points. Opacity must be between 0 and 1.

Packages are read through directory descriptors without following links. The converter clones a private snapshot before rendering. Existing destinations are never replaced by manual conversion. Automatic publication reuses the file exchange and recovery journal. Output from a package does not inherit directory permissions or Finder package attributes. Archive wrapping of project directories is not offered.

## Checks

```sh
swift test --filter SourcePackageTests
python3 tools/check-icon-project.py
```

The Python check needs Pillow on the development machine. It reads output pixels independently for all eight raster targets, geometry, layer order, orientation, and opacity. HEIC is converted back to PNG through the app before the pixel read. It also checks invalid input, source preservation, collision refusal, and cleanup. Use `--command` and `--tools` to select a packaged app.

The Swift checks cover complete-package snapshots, changed members, links and limits, all eight raster outputs, an actual external folder rename, recovery journal reconciliation, and exact Undo. Runtime testing on the minimum supported macOS release remains part of release qualification.

## Measured cost

Three complete packaged conversions per original workload on an M2 Max with macOS 26.6.2 gave these medians:

| Visible artwork | Time | Reported peak RSS |
| --- | ---: | ---: |
| One 1024-square bitmap | 0.34 s | 75.2 MiB |
| Four 256-square SVG assets | 1.28 s | 77.4 MiB |
| 128 layers sharing one bitmap | 1.50 s | 168.2 MiB |
| One 1024-square noise bitmap | 1.21 s | 148.2 MiB |

Each run includes package checks, asset preparation, rendering, and output publication. The fixtures share a package that also contains unused assets. Pixel reads and collision checks are outside the timing. RSS may include a child helper's peak. It is not the combined memory of simultaneous processes and can omit separate WebKit services. GUI memory is excluded. Repeated assets are prepared once, but drawing more layers still has a cost.

Run `python3 tools/check-icon-project.py --benchmark-only --command PATH --tools PATH` to repeat the measurement. The report at `research/icon-project-performance.json` records inputs, all runs, binary hashes, and pixel error for the noise fixture. This feature adds no new bundled helper or dependency.
