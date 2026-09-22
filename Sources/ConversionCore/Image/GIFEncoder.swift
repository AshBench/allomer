import CoreGraphics
import Foundation
import ImageIO

enum GIFEncoder {
    static func encode(source: CGImageSource, animation: AnimationFrames?, to output: URL,
                       frameIndices: [Int], delays: [Double], loopCount: Int, options: ImageOptions, tool: URL) throws {
        let count = CGImageSourceGetCount(source)
        guard !frameIndices.isEmpty, frameIndices.allSatisfy({ (0..<max(1, count)).contains($0) }) else {
            throw ConversionError.message("The GIF frame selection is invalid.")
        }
        let manager = FileManager.default
        let work = output.deletingLastPathComponent().appendingPathComponent("gif-\(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: work) }
        let frames = work.appendingPathComponent("frames.rgba")
        guard manager.createFile(atPath: frames.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ConversionError.message("The private GIF frames could not be opened.")
        }
        let file = try FileHandle(forWritingTo: frames)
        defer { try? file.close() }
        var width = 0, height = 0
        var bytes: Int64 = 0
        for (position, index) in frameIndices.enumerated() {
            try autoreleasepool {
                try Task.checkCancellation()
                defer { CGImageSourceRemoveCacheAtIndex(source, index) }
                let properties = try ImageConverter.properties(source, index)
                let size = try ImageConverter.dimensions(properties)
                let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
                let image: CGImage
                if let animation {
                    image = try animation.image(at: index)
                } else {
                    guard let decoded = CGImageSourceCreateImageAtIndex(source, index, nil),
                          CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else {
                        throw ConversionError.message("The GIF source image could not be decoded.")
                    }
                    image = decoded
                }
                guard image.width == size.width, image.height == size.height else {
                    throw ConversionError.message("A GIF source frame changed dimensions while decoding.")
                }
                let rendered = try ImageConverter.renderContext(image, orientation: orientation,
                    maxWidth: animation == nil ? 0 : options.animationMaxWidth)
                if position == 0 { width = rendered.width; height = rendered.height }
                guard rendered.width == width, rendered.height == height else {
                    throw ConversionError.message("GIF frames must have one canvas size after orientation.")
                }
                bytes += Int64(width) * Int64(height) * 4
                guard bytes <= 2_147_483_648 else {
                    throw ConversionError.message("The prepared GIF frames exceed 2 GiB.")
                }
                try ImageConverter.writeRGBA(rendered, to: file)
            }
        }
        try file.close()
        let encoded = work.appendingPathComponent("encoded.gif")
        let palette = "split[pixels][colors];[colors]palettegen=max_colors=\(options.gifMaxColors):alpha_threshold=128:bounded_histogram=1:stats_mode=single[palette];"
            + "[pixels][palette]paletteuse=new=1:cache_limit=32:dither=\(options.gifDither ? "bayer" : "none")"
        let repeats = loopCount == 1 ? -1 : max(0, loopCount - 1)
        try ExternalTool.run(tool, arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-xerror", "-max_alloc", "268435456",
            "-cpucount", "1", "-threads", "1", "-filter_complex_threads", "1", "-err_detect", "explode",
            "-f", "rawvideo", "-pixel_format", "rgba", "-video_size", "\(width)x\(height)", "-framerate", "100", "-i", frames.lastPathComponent,
            "-filter_complex", palette, "-an", "-sn", "-dn", "-map_metadata", "-1",
            "-frames:v", String(frameIndices.count), "-fps_mode", "passthrough", "-c:v", "gif", "-threads", "1",
            "-gifflags", "0", "-loop", String(repeats), "-final_delay", "1", "-f", "gif", encoded.lastPathComponent
        ], workDirectory: work, workDirectoryByteLimit: 2_147_483_648)
        guard try FileVersion(encoded).size <= 536_870_912 else {
            throw ConversionError.message("The GIF exceeds 512 MiB.")
        }
        try setDelays(encoded, delays: delays.isEmpty ? [0] : delays)
        try manager.moveItem(at: encoded, to: output)
    }

    // Replace fixed encoding timestamps with the original, validated frame delays.
    static func setDelays(_ url: URL, delays: [Double]) throws {
        let metadata = try GIFMetadata(url)
        let positions = metadata.frames.compactMap(\.controlOffset)
        guard metadata.is89a, metadata.frames.count == delays.count, positions.count == delays.count,
              delays.allSatisfy({ $0.isFinite && (0...655.35).contains($0) }) else {
            throw ConversionError.message("The GIF has an incorrect frame count or delay.")
        }
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        for (position, value) in zip(positions, delays) {
            try Task.checkCancellation()
            let delay = Int((value * 100).rounded())
            try file.seek(toOffset: position)
            try file.write(contentsOf: Data([UInt8(delay & 255), UInt8(delay >> 8)]))
        }
    }
}
