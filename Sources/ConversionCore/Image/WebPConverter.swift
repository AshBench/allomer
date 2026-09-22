import Foundation
import CoreGraphics
import ImageIO

enum WebPConverter {
    static func convert(_ input: URL, to output: URL, tool: URL, options: ImageOptions) throws {
        guard options.quality.isFinite, (0...1).contains(options.quality), (0...6).contains(options.webpEffort) else {
            throw ConversionError.message("Image quality must be between 0 and 1. WebP effort must be between 0 and 6.")
        }
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= 512 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String? else {
            throw ConversionError.message("WebP input must be a readable image up to 512 MiB.")
        }
        if let animation = try AnimationFrames(source: source, type: type) {
            try convertAnimation(input, to: output, animation: animation, tools: tool.deletingLastPathComponent(), options: options)
            guard try FileVersion(input) == version else {
                throw ConversionError.message("The source changed during WebP animation conversion.")
            }
            return
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw ConversionError.message("WebP animation needs GIF, WebP, or animated PNG input.")
        }
        let properties = try ImageConverter.properties(source, 0)
        let size = try ImageConverter.dimensions(properties)
        guard size.width <= 16_383, size.height <= 16_383 else {
            throw ConversionError.message("WebP images cannot exceed 16,383 pixels per edge.")
        }
        let work = output.deletingLastPathComponent()
        let prepared = work.appendingPathComponent("webp-input-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: prepared) }
        var png = input
        let hasGamma = (properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyPNGGamma] != nil
        if CGImageSourceGetType(source) as String? != "public.png" || hasGamma || !options.preserveMetadata || options.convertToSRGB {
            let format = FileFormat(id: "png", name: "PNG", category: "image", extensions: ["png"])
            try ImageConverter.convert(input, to: prepared, format: format, options: options, omitPNGGamma: true)
            png = prepared
        }
        var arguments = [png.path, work.path, "-quiet", "-q", String(options.quality * 100), "-m", String(options.webpEffort),
                         "-metadata", "all", "-exact", "-o", output.path]
        arguments.append(options.webpMode == .lossless ? "-lossless" : "-low_memory")
        arguments += ["--", png.path]
        try ExternalTool.run(tool, arguments: arguments, workDirectory: work)
        guard try FileVersion(output).size <= 512 * 1024 * 1024,
              let check = CGImageSourceCreateWithURL(output as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(check) as String? == "org.webmproject.webp", CGImageSourceGetCount(check) == 1,
              let image = CGImageSourceCreateImageAtIndex(check, 0, nil), image.width == size.width, image.height == size.height else {
            throw ConversionError.message("The encoded WebP failed validation.")
        }
        guard try FileVersion(input) == version else {
            throw ConversionError.message("The source image changed during WebP conversion.")
        }
    }

    private static func convertAnimation(_ input: URL, to output: URL, animation: AnimationFrames,
                                         tools: URL, options: ImageOptions) throws {
        guard (0...65_535).contains(animation.loopCount) else {
            throw ConversionError.message("The repeat count exceeds WebP's limit of 65,535 total plays.")
        }
        guard (0...65_535).contains(options.animationMaxWidth) else {
            throw ConversionError.message("Animation maximum width must be between 0 and 65,535 pixels.")
        }
        var width = 0, height = 0
        var durations: [Int] = []
        for index in 0..<animation.count {
            try autoreleasepool {
                try Task.checkCancellation()
                let properties = try ImageConverter.properties(animation.source, index)
                let size = try ImageConverter.dimensions(properties)
                let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
                let w = orientation >= 5 ? size.height : size.width
                let h = orientation >= 5 ? size.width : size.height
                if index == 0 { width = w; height = h }
                guard (1...8).contains(orientation), w <= 16_383, h <= 16_383, w == width, h == height,
                      width * height * animation.count <= 256_000_000 else {
                    throw ConversionError.message("WebP frames need one canvas up to 16,383 pixels per edge and 256 million pixels in total.")
                }
                let delay = animation.delays[index]
                guard delay.isFinite, (0...16_777.215).contains(delay) else {
                    throw ConversionError.message("A frame delay is outside WebP's range of 0–16,777.215 seconds.")
                }
                durations.append(delay > 0 ? max(1, Int((delay * 1000).rounded())) : 0)
            }
        }
        let canvas = ImageConverter.scaledCanvas(width: width, height: height, maxWidth: options.animationMaxWidth)
        var frames = Array(0..<animation.count)
        var plays = animation.loopCount
        if let rate = options.animationFrameRate {
            let sampled = try AnimationFrames.resampled(delays: animation.delays, rate: rate)
            frames = sampled.indices
            durations = sampled.delays.map { max(1, Int(($0 * 1000).rounded())) }
        }
        if let requested = options.animationPlays { plays = requested }
        guard (0...65_535).contains(plays) else {
            throw ConversionError.message("The repeat count exceeds WebP's limit of 65,535 total plays.")
        }
        let work = output.deletingLastPathComponent()
        try animation.prepare(input: input, work: work, decoder: tools.appendingPathComponent("ffmpeg"))
        let prepared = work.appendingPathComponent("webp-animation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: prepared) }
        var bytes = 0
        for (position, index) in frames.enumerated() {
            try autoreleasepool {
                try Task.checkCancellation()
                let properties = try ImageConverter.properties(animation.source, index)
                let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
                var image = try animation.image(at: index)
                if options.convertToSRGB || orientation != 1 || image.bitsPerComponent != 8
                    || image.colorSpace?.model != .rgb || canvas.width != width {
                    let colorSpace = !options.convertToSRGB && image.colorSpace?.model == .rgb ? image.colorSpace : nil
                    image = try ImageConverter.render(image, orientation: orientation, colorSpace: colorSpace,
                                                     maxWidth: options.animationMaxWidth)
                }
                let frame = prepared.appendingPathComponent(String(format: "frame-%06d.png", position + 1))
                guard let writer = CGImageDestinationCreateWithURL(frame as CFURL, "public.png" as CFString, 1, nil) else {
                    throw ConversionError.message("A private animation frame could not be opened.")
                }
                var metadata: CGMutableImageMetadata?
                if position == 0, options.preserveMetadata,
                   let original = CGImageSourceCopyMetadataAtIndex(animation.source, 0, nil) {
                    guard let copy = CGImageMetadataCreateMutableCopy(original),
                          CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyTIFFDictionary,
                            kCGImagePropertyTIFFOrientation, NSNumber(value: 1)) else {
                        throw ConversionError.message("The animation metadata could not be prepared.")
                    }
                    metadata = copy
                }
                let pngProperties: [CFString: Any] = [kCGImagePropertyOrientation: 1,
                    kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGGamma: kCFNull]]
                CGImageDestinationAddImageAndMetadata(writer, image, metadata, pngProperties as CFDictionary)
                guard CGImageDestinationFinalize(writer) else {
                    throw ConversionError.message("A private animation frame could not be written.")
                }
                let size = try FileVersion(frame).size
                guard size <= 1_073_741_824 - bytes else {
                    throw ConversionError.message("The prepared animation frames exceed 1 GiB.")
                }
                bytes += Int(size)
            }
        }
        try writeAnimation(frames: prepared, to: output, width: canvas.width, height: canvas.height,
                           durations: durations, plays: plays, tools: tools, options: options)
    }

    static func writeAnimation(frames prepared: URL, to output: URL, width: Int, height: Int,
                               durations: [Int], plays: Int, tools: URL, options: ImageOptions) throws {
        guard options.quality.isFinite, (0...1).contains(options.quality), (0...6).contains(options.webpEffort) else {
            throw ConversionError.message("Image quality must be between 0 and 1. WebP effort must be between 0 and 6.")
        }
        let manifest = prepared.appendingPathComponent("frames.txt")
        let values = ["1", String(width), String(height), String(durations.count), String(plays),
                      options.webpMode == .lossless ? "1" : "0", String(options.quality * 100), String(options.webpEffort),
                      options.preserveMetadata ? "1" : "0"] + durations.map(String.init)
        try (values.joined(separator: "\n") + "\n").write(to: manifest, atomically: false, encoding: .utf8)
        let encoded = prepared.appendingPathComponent("encoded.webp")
        try ExternalTool.run(tools.appendingPathComponent("webpanimguard"),
            arguments: [manifest.path, prepared.path, manifest.lastPathComponent, encoded.lastPathComponent],
            workDirectory: prepared, workDirectoryByteLimit: 1_610_612_736)
        guard try FileVersion(encoded).size <= 512 * 1024 * 1024,
              let check = CGImageSourceCreateWithURL(encoded as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(check) as String? == "org.webmproject.webp", CGImageSourceGetCount(check) == durations.count else {
            throw ConversionError.message("The encoded WebP has an incorrect format or frame count.")
        }
        let global = CGImageSourceCopyProperties(check, nil) as? [CFString: Any] ?? [:]
        let webp = global[kCGImagePropertyWebPDictionary] as? [CFString: Any] ?? [:]
        guard webp[kCGImagePropertyWebPLoopCount] as? Int == plays else {
            throw ConversionError.message("The encoded WebP changed the repeat count.")
        }
        for index in durations.indices {
            try autoreleasepool {
                try Task.checkCancellation()
                defer { CGImageSourceRemoveCacheAtIndex(check, index) }
                let properties = try ImageConverter.properties(check, index)
                let frame = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any] ?? [:]
                let delay = frame[kCGImagePropertyWebPUnclampedDelayTime] as? Double
                    ?? frame[kCGImagePropertyWebPDelayTime] as? Double ?? -1
                guard let image = CGImageSourceCreateImageAtIndex(check, index, nil),
                      CGImageSourceGetStatusAtIndex(check, index) == .statusComplete,
                      image.width == width, image.height == height, abs(delay * 1000 - Double(durations[index])) < 0.000_001 else {
                    throw ConversionError.message("The encoded WebP changed a frame's dimensions or delay.")
                }
            }
        }
        try FileManager.default.moveItem(at: encoded, to: output)
    }
}
