import CoreGraphics
import Foundation
import ImageIO

final class AnimationFrames {
    let source: CGImageSource
    let type: String
    let count: Int
    let loopCount: Int
    let delays: [Double]
    private var directory: URL?
    private var files: [URL] = []
    private var colorSpace: CGColorSpace?

    static func keys(_ type: String) -> (dictionary: CFString, delay: CFString, unclamped: CFString, loop: CFString)? {
        switch type {
        case "com.compuserve.gif": (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFDelayTime,
                                   kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFLoopCount)
        case "org.webmproject.webp": (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPDelayTime,
                                     kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPLoopCount)
        case "public.png": (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGDelayTime,
                            kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGLoopCount)
        default: nil
        }
    }

    init?(source: CGImageSource, type: String) throws {
        guard let keys = Self.keys(type) else { return nil }
        let count = CGImageSourceGetCount(source)
        let global = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let properties = global[keys.dictionary] as? [CFString: Any] ?? [:]
        if count == 1, type != "com.compuserve.gif" {
            if type == "org.webmproject.webp" {
                // ImageIO supplies a default global repeat count even for a still WebP.
                if try ImageConverter.properties(source, 0)[keys.dictionary] == nil { return nil }
            } else if properties[keys.loop] == nil { return nil }
        }
        guard (1...10_000).contains(count) else { throw ConversionError.message("Animations are limited to 10,000 frames.") }
        self.source = source
        self.type = type
        self.count = count
        loopCount = properties[keys.loop] as? Int ?? 1
        delays = try (0..<count).map { index in
            try autoreleasepool {
                try Task.checkCancellation()
                let frame = try ImageConverter.properties(source, index)[keys.dictionary] as? [CFString: Any] ?? [:]
                return frame[keys.unclamped] as? Double ?? frame[keys.delay] as? Double ?? 0.1
            }
        }
    }

    deinit {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // Sample a variable-delay timeline at one rate. Returns the source frame to show for each
    // output frame and the equal delay each one carries.
    static func resampled(delays: [Double], rate: Double, limit: Int = 10_000) throws -> (indices: [Int], delays: [Double]) {
        guard rate.isFinite, (1...100).contains(rate), !delays.isEmpty else {
            throw ConversionError.message("An animation frame rate must be between 1 and 100 frames per second.")
        }
        let step = 1 / rate
        var starts: [Double] = []
        var total = 0.0
        for delay in delays {
            starts.append(total)
            total += max(0, delay)
        }
        // Frames without recorded timing keep one output frame each.
        guard total > 0 else { return (Array(delays.indices), delays.map { _ in step }) }
        let count = max(1, Int((total / step).rounded()))
        guard count <= limit else {
            throw ConversionError.message("The resampled animation exceeds the frame limit.")
        }
        var indices: [Int] = []
        indices.reserveCapacity(count)
        var cursor = 0
        for frame in 0..<count {
            let time = (Double(frame) + 0.5) * step
            while cursor + 1 < starts.count, starts[cursor + 1] <= time { cursor += 1 }
            indices.append(cursor)
        }
        return (indices, Array(repeating: step, count: count))
    }

    func prepare(input: URL, work: URL, decoder: URL?) throws {
        guard type == "public.png" else { return }
        // ImageIO can composite the first APNG frame incorrectly when a poster is present.
        guard let decoder else { throw ConversionError.message("The bundled animation decoder is missing.") }
        let folder = work.appendingPathComponent("animation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        directory = folder
        try ExternalTool.run(decoder, arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-xerror", "-max_alloc", "268435456", "-cpucount", "1",
            "-threads", "1", "-filter_threads", "1", "-err_detect", "explode", "-max_pixels", "32000000",
            "-f", "apng", "-ignore_loop", "1", "-noautorotate", "-i", input.path, "-map", "0:v:0",
            "-an", "-sn", "-dn", "-fps_mode", "passthrough", "-frames:v", String(count + 1),
            "-c:v", "png", "-threads", "1", "-compression_level", "1", "-f", "image2",
            "frame-%06d.png"
        ], workDirectory: folder, workDirectoryByteLimit: 1_073_741_824)
        files = (1...count).map { folder.appendingPathComponent(String(format: "frame-%06d.png", $0)) }
        guard try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).count == count,
              files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ConversionError.message("The PNG animation decoder returned an incorrect frame count.")
        }
        guard let first = CGImageSourceCreateWithURL(files[0] as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(first, 0, nil),
              CGImageSourceGetStatusAtIndex(first, 0) == .statusComplete,
              let colorSpace = image.colorSpace else {
            throw ConversionError.message("The animation color profile could not be restored.")
        }
        self.colorSpace = colorSpace
    }

    func image(at index: Int) throws -> CGImage {
        defer { CGImageSourceRemoveCacheAtIndex(source, index) }
        let size = try ImageConverter.dimensions(ImageConverter.properties(source, index))
        let decoder: CGImageSource
        if files.isEmpty {
            decoder = source
        } else {
            guard let decoded = CGImageSourceCreateWithURL(files[index] as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw ConversionError.message("An animation frame could not be opened.")
            }
            decoder = decoded
        }
        let decoderIndex = files.isEmpty ? index : 0
        guard let image = CGImageSourceCreateImageAtIndex(decoder, decoderIndex, nil),
              CGImageSourceGetStatusAtIndex(decoder, decoderIndex) == .statusComplete,
              image.width == size.width, image.height == size.height else {
            throw ConversionError.message("An animation frame could not be decoded at its declared size.")
        }
        if files.isEmpty { return image }
        // The decoder writes APNG's shared color profile only on the first private PNG.
        guard let colorSpace, let restored = image.copy(colorSpace: colorSpace) else {
            throw ConversionError.message("The animation color profile could not be restored.")
        }
        return restored
    }
}
