import CoreGraphics
import Foundation
import ImageIO
import zlib

enum GIFPreparation {
    // Change only palettes and the old profile. Compressed frame data and timing stay intact.
    static func prepareVideo(_ input: URL, metadata: GIFMetadata, work: URL) throws -> URL? {
        guard let profile = metadata.profile else { return nil }
        let version = metadata.version
        guard try FileVersion(input) == version else { throw ConversionError.message("The GIF changed before color preparation.") }
        guard let sourceSpace = CGColorSpace(iccData: profile as CFData), sourceSpace.model == .rgb,
              sourceSpace.numberOfComponents == 3, let targetSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let removed = metadata.profileRange else {
            throw ConversionError.message("The GIF color profile is not a readable RGB profile.")
        }
        let manager = FileManager.default
        let prepared = work.appendingPathComponent("gif-video-\(UUID().uuidString).gif")
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        func checkTime() throws {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ConversionError.message("GIF color preparation exceeded 120 seconds.") }
        }
        do {
            try cloneSource(input, to: prepared)
            guard try FileVersion(prepared).size == version.size, try FileVersion(input) == version else {
                throw ConversionError.message("The GIF changed while its private copy was made.")
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prepared.path)
            let file = try FileHandle(forUpdating: prepared)
            defer { try? file.close() }
            for range in metadata.paletteRanges {
                try checkTime()
                try file.seek(toOffset: range.lowerBound)
                let count = Int(range.upperBound - range.lowerBound)
                guard var bytes = try file.read(upToCount: count), bytes.count == count else {
                    throw ConversionError.message("The GIF palette is incomplete.")
                }
                for index in stride(from: 0, to: count, by: 3) {
                    let rgb = (0..<3).map { CGFloat(bytes[index + $0]) / 255 } + [1]
                    guard let color = CGColor(colorSpace: sourceSpace, components: rgb)?.converted(to: targetSpace,
                        intent: .relativeColorimetric, options: nil)?.components,
                          color.count == 4, color.allSatisfy(\.isFinite) else {
                        throw ConversionError.message("The GIF palette could not be converted to sRGB.")
                    }
                    for channel in 0..<3 { bytes[index + channel] = UInt8((min(1, max(0, color[channel])) * 255).rounded()) }
                }
                try file.seek(toOffset: range.lowerBound)
                try file.write(contentsOf: bytes)
            }
            let removedBytes = removed.upperBound - removed.lowerBound
            var offset = removed.upperBound
            while offset < UInt64(version.size) {
                try checkTime()
                try file.seek(toOffset: offset)
                let count = Int(min(65_536, UInt64(version.size) - offset))
                guard let bytes = try file.read(upToCount: count), bytes.count == count else {
                    throw ConversionError.message("The GIF changed during color preparation.")
                }
                try file.seek(toOffset: offset - removedBytes)
                try file.write(contentsOf: bytes)
                offset += UInt64(count)
            }
            try file.truncate(atOffset: UInt64(version.size) - removedBytes)
            let check = try GIFMetadata(prepared)
            guard check.profile == nil, check.width == metadata.width, check.height == metadata.height,
                  check.plays == metadata.plays, check.frames.map(\.delay) == metadata.frames.map(\.delay),
                  try FileVersion(input) == version else {
                throw ConversionError.message("GIF color preparation changed the animation or its source.")
            }
            return prepared
        } catch {
            try? manager.removeItem(at: prepared)
            throw error
        }
    }

    static func prepare(_ input: URL, tools: URL, work: URL) throws -> URL? {
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= 536_870_912 else {
            throw ConversionError.message("GIF input must be up to 512 MiB.")
        }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "com.compuserve.gif" else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count <= 10_000 else { throw ConversionError.message("GIF input exceeds 10,000 frames.") }
        let unreadable = (0..<count).contains { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return properties?[kCGImagePropertyPixelWidth] == nil || properties?[kCGImagePropertyPixelHeight] == nil
        }
        guard count == 0 || unreadable else { return nil }
        let metadata = try GIFMetadata(input)
        guard metadata.frames.count <= 256_000_000 / (metadata.width * metadata.height) else {
            throw ConversionError.message("GIF image preparation exceeds 256 million total pixels.")
        }
        let manager = FileManager.default
        let folder = work.appendingPathComponent("gif-reader-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }
        let prepared = work.appendingPathComponent("gif-input-\(UUID().uuidString).png")
        do {
            try ExternalTool.run(tools.appendingPathComponent("ffmpeg"), arguments: [
                "-hide_banner", "-v", "error", "-nostdin", "-n", "-xerror", "-max_alloc", "268435456",
                "-cpucount", "1", "-threads", "1", "-filter_threads", "1", "-err_detect", "explode",
                "-max_pixels", "32000000", "-protocol_whitelist", "file,pipe", "-f", "gif", "-ignore_loop", "1",
                "-i", input.path, "-map", "0:v:0", "-an", "-sn", "-dn", "-fps_mode", "passthrough",
                "-frames:v", String(metadata.frames.count + 1), "-c:v", "png", "-pix_fmt", "rgba", "-threads", "1",
                "-compression_level", "1", "-f", "image2", "frame-%06d.png"
            ], workDirectory: folder, workDirectoryByteLimit: 1_073_741_824)
            guard try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).count == metadata.frames.count else {
                throw ConversionError.message("The GIF decoder returned an incorrect frame count.")
            }
            let space = metadata.profile.flatMap { CGColorSpace(iccData: $0 as CFData) }
                ?? (metadata.profile == nil ? CGColorSpace(name: CGColorSpace.sRGB) : nil)
            guard let space, space.model == .rgb, space.numberOfComponents == 3 else {
                throw ConversionError.message("The GIF color profile is not a readable RGB profile.")
            }
            let native = folder.appendingPathComponent("native.png")
            guard let writer = CGImageDestinationCreateWithURL(native as CFURL, "public.png" as CFString, metadata.frames.count, nil) else {
                throw ConversionError.message("The private GIF image could not be opened.")
            }
            CGImageDestinationSetProperties(writer, [kCGImagePropertyPNGDictionary:
                [kCGImagePropertyAPNGLoopCount: metadata.plays]] as CFDictionary)
            for index in metadata.frames.indices {
                try autoreleasepool {
                    try Task.checkCancellation()
                    let file = folder.appendingPathComponent(String(format: "frame-%06d.png", index + 1))
                    guard let decoded = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          CGImageSourceGetCount(decoded) == 1,
                          let image = CGImageSourceCreateImageAtIndex(decoded, 0, nil),
                          CGImageSourceGetStatusAtIndex(decoded, 0) == .statusComplete,
                          image.width == metadata.width, image.height == metadata.height,
                          let tagged = image.copy(colorSpace: space) else {
                        throw ConversionError.message("The GIF decoder changed a frame's dimensions or color layout.")
                    }
                    let delay = metadata.frames[index].delay
                    CGImageDestinationAddImage(writer, tagged, [kCGImagePropertyPNGDictionary:
                        [kCGImagePropertyAPNGDelayTime: delay, kCGImagePropertyAPNGUnclampedDelayTime: delay]] as CFDictionary)
                }
            }
            guard CGImageDestinationFinalize(writer), try FileVersion(native).size <= 536_870_912 else {
                throw ConversionError.message("The prepared GIF image failed or exceeds 512 MiB.")
            }
            let singleAnimation = metadata.frames.count == 1 && (metadata.plays != 1 || metadata.frames[0].delay > 0)
            if singleAnimation { try addSingleFrameControl(native, to: prepared, metadata: metadata) }
            else { try manager.moveItem(at: native, to: prepared) }
            guard let check = CGImageSourceCreateWithURL(prepared as CFURL, nil),
                  CGImageSourceGetType(check) as String? == "public.png", CGImageSourceGetCount(check) == metadata.frames.count else {
                throw ConversionError.message("The prepared GIF image changed its frame count.")
            }
            if singleAnimation || metadata.frames.count > 1 {
                guard let animation = try AnimationFrames(source: check, type: "public.png"),
                      animation.loopCount == metadata.plays,
                      zip(animation.delays, metadata.frames).allSatisfy({ abs($0 - $1.delay) < 0.000_001 }) else {
                    throw ConversionError.message("The prepared GIF image changed its timing or repeats.")
                }
            }
            guard try FileVersion(input) == version else { throw ConversionError.message("The GIF changed during preparation.") }
            return prepared
        } catch {
            try? manager.removeItem(at: prepared)
            throw error
        }
    }

    // ImageIO writes a plain PNG for one frame. Retain meaningful GIF timing with standard APNG controls.
    private static func addSingleFrameControl(_ input: URL, to output: URL, metadata: GIFMetadata) throws {
        let version = try FileVersion(input)
        guard version.size >= 33, version.size + 58 <= 536_870_912 else {
            throw ConversionError.message("The prepared GIF image exceeds 512 MiB or has an incomplete header.")
        }
        let file = try FileHandle(forReadingFrom: input)
        defer { try? file.close() }
        guard let header = try file.read(upToCount: 33), header.count == 33,
              header.prefix(16) == Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]) else {
            throw ConversionError.message("The native PNG header is invalid.")
        }
        func word(_ value: UInt32) -> Data {
            var big = value.bigEndian
            return Data(bytes: &big, count: 4)
        }
        func chunk(_ name: String, _ payload: Data) -> Data {
            let data = Data(name.utf8) + payload
            let checksum = data.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            return word(UInt32(payload.count)) + data + word(UInt32(checksum))
        }
        let plays = chunk("acTL", word(1) + word(UInt32(metadata.plays)))
        let delay = UInt16((metadata.frames[0].delay * 100).rounded())
        let frame = word(0) + word(UInt32(metadata.width)) + word(UInt32(metadata.height)) + word(0) + word(0)
            + Data([UInt8(delay >> 8), UInt8(delay & 255), 0, 100, 0, 0])
        try (header + plays + chunk("fcTL", frame)).write(to: output, options: .withoutOverwriting)
        let destination = try FileHandle(forWritingTo: output)
        defer { try? destination.close() }
        try destination.seekToEnd()
        var copied: Int64 = 33
        while let bytes = try file.read(upToCount: 65_536), !bytes.isEmpty {
            try Task.checkCancellation()
            copied += Int64(bytes.count)
            guard copied <= version.size else { throw ConversionError.message("The native PNG changed during preparation.") }
            try destination.write(contentsOf: bytes)
        }
        guard copied == version.size, try FileVersion(input) == version else {
            throw ConversionError.message("The native PNG changed during preparation.")
        }
    }
}
