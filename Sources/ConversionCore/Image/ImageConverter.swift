import CoreGraphics
import Foundation
import ImageIO

public enum ImageConverter {
    static let inputTypes = Set(CGImageSourceCopyTypeIdentifiers() as! [String])
    public static let outputTypes = Set(CGImageDestinationCopyTypeIdentifiers() as! [String])
    static let rawTypes = [
        ("com.nikon.raw-image", "nef"), ("com.sony.arw-raw-image", "arw"),
        ("com.pentax.raw-image", "pef"), ("com.adobe.raw-image", "dng"),
        ("com.canon.cr2-raw-image", "cr2"), ("com.fuji.raw-image", "raf"),
        ("com.olympus.or-raw-image", "orf"), ("com.panasonic.rw2-raw-image", "rw2"),
        ("com.panasonic.raw-image", "rw2")
    ]

    public static func supports(sourceType: String, frames: Int, outputType: String) -> Bool {
        outputTypes.contains(outputType) && (frames == 1
            || (frames > 1 && sourceType == "public.tiff" && ["public.tiff", "com.adobe.pdf"].contains(outputType))
            || (frames > 1 && AnimationFrames.keys(sourceType) != nil && outputType == "com.compuserve.gif"))
    }

    public static func detectedType(at url: URL) -> String? {
        inspect(url)?.type
    }

    public static func inspect(_ url: URL) -> (type: String, frames: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let type = CGImageSourceGetType(source) as String? else { return nil }
        if type == "public.tiff" {
            // A changed RAW extension can make ImageIO select a TIFF preview or no image.
            for (hint, _) in rawTypes {
                guard let candidate = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceTypeIdentifierHint: hint, kCGImageSourceShouldCache: false] as CFDictionary),
                    CGImageSourceGetType(candidate) as String? == hint, CGImageSourceGetCount(candidate) == 1,
                    let properties = CGImageSourceCopyPropertiesAtIndex(candidate, 0, nil) as? [CFString: Any],
                    let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
                    let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0 else { continue }
                return (hint, 1)
            }
        }
        return (type, CGImageSourceGetCount(source))
    }

    static func prepareInput(_ input: URL, type: String?, work: URL) throws -> URL? {
        if type == "com.adobe.photoshop-image" { return try PSDCompression.prepare(input, work: work) }
        guard let type, let ext = rawTypes.first(where: { $0.0 == type })?.1,
              input.pathExtension.lowercased() != ext else { return nil }
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= 512 * 1024 * 1024 else {
            throw ConversionError.message("RAW input must be no larger than 512 MiB.")
        }
        let prepared = work.appendingPathComponent("raw-\(UUID().uuidString).\(ext)")
        do {
            try cloneSource(input, to: prepared)
            guard try FileVersion(input) == version, try FileVersion(prepared).size == version.size else {
                throw ConversionError.message("The RAW source changed during preparation.")
            }
            return prepared
        } catch {
            try? FileManager.default.removeItem(at: prepared)
            throw error
        }
    }

    static func validateJPEG(_ input: URL, tools: URL, work: URL) throws {
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= 512 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1 else {
            throw ConversionError.message("JPEG input must be one readable image up to 512 MiB.")
        }
        _ = try dimensions(properties(source, 0))
        let response = try ExternalTool.run(tools.appendingPathComponent("pdfguard"),
            arguments: [input.path, work.path, "jpegcheck", input.path], workDirectory: work,
            captureOutput: true, outputLimit: 256)
        switch String(decoding: response, as: UTF8.self) {
        case "valid\n": break
        case "unsupported\n":
            // The IJG decoder delegates lossless and higher-precision JPEG to the bundled media decoder.
            try ExternalTool.run(tools.appendingPathComponent("ffmpeg"), arguments: [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-xerror", "-max_alloc", "268435456",
                "-cpucount", "1", "-threads", "1", "-filter_threads", "1", "-err_detect", "explode",
                "-max_pixels", "32000000", "-f", "mjpeg", "-i", input.path,
                "-map", "0:v:0", "-frames:v", "1", "-f", "null", "-"], workDirectory: work)
        default: throw ConversionError.message("The JPEG validator returned an unexpected result.")
        }
        guard try FileVersion(input) == version else {
            throw ConversionError.message("The JPEG changed during validation.")
        }
    }

    @discardableResult
    static func validateGIF(_ input: URL, tools: URL, work: URL) throws -> GIFMetadata {
        let version = try FileVersion(input)
        let metadata = try GIFMetadata(input)
        try ExternalTool.run(tools.appendingPathComponent("ffmpeg"), arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-xerror", "-max_alloc", "268435456", "-cpucount", "1",
            "-threads", "1", "-filter_threads", "1", "-err_detect", "explode", "-max_pixels", "32000000",
            "-f", "gif", "-ignore_loop", "1", "-i", input.path, "-map", "0:v:0", "-fps_mode", "passthrough",
            "-f", "null", "-"
        ], workDirectory: work)
        guard try FileVersion(input) == version else {
            throw ConversionError.message("The GIF changed during validation.")
        }
        return metadata
    }

    public static func convert(_ input: URL, to output: URL, format: FileFormat,
                               options: ImageOptions = ImageOptions(), omitPNGGamma: Bool = false,
                               animationDecoder: URL? = nil, tiffEncoder: URL? = nil) throws {
        guard options.quality.isFinite, (0...1).contains(options.quality) else {
            throw ConversionError.message("Image quality must be between 0 and 1.")
        }
        guard let type = format.typeIdentifier, outputTypes.contains(type) else {
            throw ConversionError.message("macOS cannot encode \(format.name) with ImageIO.")
        }
        if IconImageConverter.outputTypes.contains(type) {
            try IconImageConverter.convert(input, to: output, format: format, options: options)
            return
        }
        // The native AVIF writer rejects exactly 1.0. Request its highest lossy value.
        let quality = type == "public.avif" && options.quality == 1 ? Double(Float(1).nextDown) : options.quality
        let jpegTIFF = type == "public.tiff" && options.tiffCompression == .jpeg
        if type == "com.compuserve.gif", !(2...256).contains(options.gifMaxColors) {
            throw ConversionError.message("GIF palettes must contain between 2 and 256 colors.")
        }
        let background = try (type == "public.jpeg" ? options.backgroundColor() : nil)
        if jpegTIFF {
            guard options.tiffJPEGQuality.isFinite, (0...1).contains(options.tiffJPEGQuality) else {
                throw ConversionError.message("TIFF JPEG quality must be between 0 and 1.")
            }
            guard let tiffEncoder, FileManager.default.isExecutableFile(atPath: tiffEncoder.path) else {
                throw ConversionError.message("The TIFF JPEG encoder is missing from this build.")
            }
        }
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= 512 * 1024 * 1024 else {
            throw ConversionError.message("Image input must be no larger than 512 MiB.")
        }
        guard let source = CGImageSourceCreateWithURL(input as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
              let sourceType = CGImageSourceGetType(source) as String? else {
            throw ConversionError.message("The source is not a readable image.")
        }
        let count = CGImageSourceGetCount(source)
        guard (1...10_000).contains(count), supports(sourceType: sourceType, frames: count, outputType: type) else {
            throw ConversionError.message("Multiple images require TIFF-to-TIFF/PDF or GIF, WebP, or animated PNG input saved as GIF. The limit is 10,000 frames.")
        }
        let animation = type == "com.compuserve.gif" ? try AnimationFrames(source: source, type: sourceType) : nil
        if animation != nil, !(0...65_535).contains(options.animationMaxWidth) {
            throw ConversionError.message("Animation maximum width must be between 0 and 65,535 pixels.")
        }
        var delays: [Double] = []
        let loopCount = animation?.loopCount ?? 1
        // Output frames map back to source frames. Resampling repeats or drops entries.
        var frames = Array(0..<count)
        var plays = loopCount
        if animation != nil {
            guard (0...65_536).contains(loopCount) else {
                throw ConversionError.message("The animation repeat count exceeds the GIF limit.")
            }
        }
        var pixels = 0
        for index in 0..<count {
            pixels += try autoreleasepool {
                try Task.checkCancellation()
                let properties = try properties(source, index)
                let size = try dimensions(properties)
                if jpegTIFF, size.width > 65_500 {
                    throw ConversionError.message("JPEG-compressed TIFF pages must be no wider than 65,500 pixels.")
                }
                if type == "com.adobe.pdf" { _ = try pageSize(properties) }
                if type == "com.compuserve.gif" {
                    guard size.width <= 65_535, size.height <= 65_535,
                          (1...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1) else {
                        throw ConversionError.message("A GIF frame has invalid dimensions or orientation.")
                    }
                }
                if let animation {
                    let delay = animation.delays[index]
                    guard delay.isFinite, (0...655.35).contains(delay) else {
                        throw ConversionError.message("A frame delay is outside the GIF range of 0–655.35 seconds.")
                    }
                    delays.append(delay > 0 ? max(0.01, (delay * 100).rounded() / 100) : 0)
                }
                return size.width * size.height
            }
            guard pixels <= 256_000_000 else {
                throw ConversionError.message("The image pages exceed 256 million pixels in total.")
            }
        }
        try animation?.prepare(input: input, work: output.deletingLastPathComponent(), decoder: animationDecoder)
        if type == "com.compuserve.gif" {
            guard let animationDecoder, FileManager.default.isExecutableFile(atPath: animationDecoder.path) else {
                throw ConversionError.message("The bundled GIF encoder is missing.")
            }
            if animation != nil {
                if let rate = options.animationFrameRate {
                    let sampled = try AnimationFrames.resampled(delays: delays, rate: rate)
                    frames = sampled.indices
                    delays = sampled.delays.map { max(0.01, ($0 * 100).rounded() / 100) }
                }
                if let requested = options.animationPlays { plays = requested }
                guard (0...65_536).contains(plays) else {
                    throw ConversionError.message("The animation repeat count exceeds the GIF limit.")
                }
            }
            try GIFEncoder.encode(source: source, animation: animation, to: output, frameIndices: frames,
                                  delays: delays, loopCount: plays, options: options, tool: animationDecoder)
        } else {
            let nativeOutput = jpegTIFF ? output.deletingLastPathComponent().appendingPathComponent("tiff-\(UUID().uuidString).tiff") : output
            defer { if jpegTIFF { try? FileManager.default.removeItem(at: nativeOutput) } }
            guard let destination = CGImageDestinationCreateWithURL(nativeOutput as CFURL, type as CFString, count, nil) else {
                throw ConversionError.message("The image output could not be opened.")
            }
            if type == "com.adobe.pdf" {
                CGImageDestinationSetProperties(destination, [kCGImageDestinationLossyCompressionQuality: options.quality] as CFDictionary)
            }
            for index in 0..<count {
                try autoreleasepool {
                    try Task.checkCancellation()
                    defer { CGImageSourceRemoveCacheAtIndex(source, index) }
                    let sourceProperties = try properties(source, index)
                    let size = try dimensions(sourceProperties)
                    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
                          CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                          image.width == size.width, image.height == size.height else {
                        throw ConversionError.message("An image page could not be decoded at its declared size.")
                    }
                    var properties = options.preserveMetadata ? sourceProperties : [:]
                    // Orientation and resolution affect appearance when descriptive metadata is removed.
                    for key in [kCGImagePropertyOrientation, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
                        properties[key] = sourceProperties[key]
                    }
                    properties[kCGImageDestinationLossyCompressionQuality] = quality
                    if let background { properties[kCGImageDestinationBackgroundColor] = background }
                    if type == "public.png", omitPNGGamma {
                        // The private WebP input keeps its ICC profile without a second gamma instruction.
                        var png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
                        png[kCGImagePropertyPNGGamma] = kCFNull
                        properties[kCGImagePropertyPNGDictionary] = png
                    }
                    if options.progressiveJPEG, type == "public.jpeg" {
                        var jfif = properties[kCGImagePropertyJFIFDictionary] as? [CFString: Any] ?? [:]
                        jfif[kCGImagePropertyJFIFIsProgressive] = true
                        properties[kCGImagePropertyJFIFDictionary] = jfif
                    }
                    if type == "public.tiff", let compression = options.tiffCompression.code {
                        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                        tiff[kCGImagePropertyTIFFCompression] = jpegTIFF ? 1 : compression
                        properties[kCGImagePropertyTIFFDictionary] = tiff
                    }
                    var rendered = image
                    // A gray JPEG needs an RGB buffer for a custom color background.
                    let colorBackground = background?.colorSpace?.model == .rgb && image.colorSpace?.model == .monochrome
                        && ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
                    if options.convertToSRGB || colorBackground {
                        rendered = try render(image, orientation: 1)
                    }
                    if jpegTIFF, rendered.bitsPerComponent != 8 || rendered.colorSpace?.model == .indexed {
                        guard let originalSpace = rendered.colorSpace,
                              let space = originalSpace.model == .indexed ? originalSpace.baseColorSpace : originalSpace,
                              [.rgb, .monochrome, .cmyk].contains(space.model) else {
                            throw ConversionError.message("Convert this image to sRGB before using TIFF JPEG compression.")
                        }
                        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(rendered.alphaInfo)
                        let alpha: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : (space.model == .rgb ? .noneSkipLast : .none)
                        rendered = try render(rendered, orientation: 1, colorSpace: space, alphaInfo: alpha)
                    }
                    if type == "public.tiff" {
                        let metadata = options.preserveMetadata ? CGImageSourceCopyMetadataAtIndex(source, index, nil) : nil
                        let copy = metadata.flatMap(CGImageMetadataCreateMutableCopy)
                        for path in ["tiff:Compression", "tiff:BitsPerSample", "tiff:SamplesPerPixel", "tiff:PhotometricInterpretation", "exif:ColorSpace"] {
                            if let copy { CGImageMetadataRemoveTagWithPath(copy, nil, path as CFString) }
                        }
                        CGImageDestinationAddImageAndMetadata(destination, rendered, copy, properties as CFDictionary)
                    } else {
                        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
                    }
                }
            }
            try Task.checkCancellation()
            guard CGImageDestinationFinalize(destination), try FileVersion(nativeOutput).size <= (jpegTIFF ? 2_147_483_648 : 536_870_912) else {
                throw ConversionError.message(jpegTIFF ? "The private TIFF preparation failed or exceeds 2 GiB." : "The image output failed or exceeds 512 MiB.")
            }
            if jpegTIFF, let tiffEncoder {
                try ExternalTool.run(tiffEncoder, arguments: [nativeOutput.path, output.deletingLastPathComponent().path,
                    "-m", "256", "-c", "jpeg:r:\(Int((options.tiffJPEGQuality * 100).rounded()))", "-r", "128", "--",
                    nativeOutput.lastPathComponent, output.lastPathComponent], workDirectory: output.deletingLastPathComponent())
                guard try FileVersion(output).size <= 536_870_912 else {
                    throw ConversionError.message("The TIFF output exceeds 512 MiB.")
                }
            }
        }
        if type == "com.compuserve.gif" {
            guard let animationDecoder else { throw ConversionError.message("The bundled GIF decoder is missing.") }
            let check = try validateGIF(output, tools: animationDecoder.deletingLastPathComponent(), work: output.deletingLastPathComponent())
            guard check.frames.count == frames.count, check.plays == plays else {
                throw ConversionError.message("The encoded GIF changed its frame or repeat count.")
            }
            for index in frames.indices {
                let original = try properties(source, frames[index])
                let size = try dimensions(original)
                let rotated = (original[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
                let canvas = scaledCanvas(width: rotated ? size.height : size.width,
                                          height: rotated ? size.width : size.height,
                                          maxWidth: animation == nil ? 0 : options.animationMaxWidth)
                guard check.width == canvas.width, check.height == canvas.height,
                      abs(check.frames[index].delay - (delays.isEmpty ? 0 : delays[index])) < 0.000_001 else {
                    throw ConversionError.message("The encoded GIF changed a frame's size or delay.")
                }
            }
        } else if type == "com.adobe.pdf" {
            // ImageIO can inspect PDFs but cannot decode their pages as raster images.
            guard let document = CGPDFDocument(output as CFURL), document.numberOfPages == count else {
                throw ConversionError.message("The image PDF has an incorrect page count.")
            }
            for index in 0..<count {
                try Task.checkCancellation()
                let expected = try pageSize(properties(source, index))
                guard let page = document.page(at: index + 1) else {
                    throw ConversionError.message("An image PDF page could not be read.")
                }
                let actual = page.getBoxRect(.mediaBox).size
                guard abs(actual.width - expected.width) < 0.01, abs(actual.height - expected.height) < 0.01 else {
                    throw ConversionError.message("The image PDF changed a page's physical size.")
                }
            }
        } else {
            guard let check = CGImageSourceCreateWithURL(output as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(check) as String? == type, CGImageSourceGetCount(check) == count else {
                throw ConversionError.message("The encoded image has an incorrect format or page count.")
            }
            for index in 0..<count {
                try autoreleasepool {
                    try Task.checkCancellation()
                    defer { CGImageSourceRemoveCacheAtIndex(check, index) }
                    let original = try properties(source, index)
                    if type == "public.tiff", let requested = options.tiffCompression.code {
                        let encoded = try properties(check, index)[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                        guard encoded[kCGImagePropertyTIFFCompression] as? Int == requested else {
                            throw ConversionError.message("The TIFF writer did not use the requested compression.")
                        }
                    }
                    let expected = try dimensions(original)
                    guard let decoded = CGImageSourceCreateImageAtIndex(check, index, nil),
                          decoded.width == expected.width, decoded.height == expected.height else {
                        throw ConversionError.message("The encoded image failed validation.")
                    }
                }
            }
        }
        guard try FileVersion(input) == version else {
            throw ConversionError.message("The source image changed during conversion.")
        }
    }

    private static func pageSize(_ properties: [CFString: Any]) throws -> CGSize {
        let size = try dimensions(properties)
        let x = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        let y = properties[kCGImagePropertyDPIHeight] as? Double ?? 72
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard x.isFinite, y.isFinite, (1...12_000).contains(x), (1...12_000).contains(y), (1...8).contains(orientation) else {
            throw ConversionError.message("An image page has invalid resolution or orientation.")
        }
        let width = Double(size.width) * 72 / x, height = Double(size.height) * 72 / y
        guard width <= 144_000, height <= 144_000 else {
            throw ConversionError.message("An image PDF page has excessive physical dimensions.")
        }
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
