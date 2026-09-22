import Foundation
import ImageIO

struct MediaArtwork {
    private static let byteLimit = 8 * 1024 * 1024
    private static let pixelLimit = 32_000_000
    private static let codecs = ["png": ("png", "image/png", "public.png"),
                                 "mjpeg": ("jpg", "image/jpeg", "public.jpeg"),
                                 "bmp": ("bmp", "image/bmp", "com.microsoft.bmp")]
    private static let pictureTypes = ["Other", "32x32 pixels 'file icon'", "Other file icon",
        "Cover (front)", "Cover (back)", "Leaflet page", "Media (e.g. label side of CD)",
        "Lead artist/lead performer/soloist", "Artist/performer", "Conductor", "Band/Orchestra",
        "Composer", "Lyricist/text writer", "Recording Location", "During recording",
        "During performance", "Movie/video screen capture", "A bright coloured fish",
        "Illustration", "Band/artist logotype", "Publisher/Studio logotype"]
    private static let pictureKeys = ["METADATA_BLOCK_PICTURE", "COVERART", "COVERARTMIME",
        "WM/Picture", "Cover Art (Front)", "Cover Art (Back)", "APIC", "PIC", "covr"]
    private static let toolOptions = ["-hide_banner", "-v", "error", "-nostdin", "-xerror",
        "-max_alloc", "268435456", "-cpucount", "1", "-threads", "1", "-filter_threads", "1",
        "-err_detect", "explode", "-max_pixels", "32000000", "-protocol_whitelist", "file,pipe"]

    private struct Picture {
        let codec: String
        let width: Int
        let height: Int
        let bytes: Data
    }

    var inputArguments: [String] = []
    var metadataArguments: [String] = []
    var outputArguments: [String] = []
    private var pictures: [Picture] = []
    private var files: [URL] = []

    func cleanup() {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    static func prepare(input: URL, streams: [MediaInfo.Stream], target: String,
                        preserve: Bool, preserveMetadata: Bool, ffmpeg: URL, work: URL,
                        timeout: TimeInterval) throws -> Self {
        var result = Self()
        let keep = preserve && !streams.isEmpty
        let pictureTag = keep && ["ogg", "opus"].contains(target)
        // Picture tags must not recreate omitted or replaced artwork during metadata copying.
        for key in pictureKeys {
            if !(pictureTag && key == "METADATA_BLOCK_PICTURE") {
                result.outputArguments += ["-metadata", "\(key)="]
            }
            result.outputArguments += ["-metadata:s", "\(key)="]
        }
        guard keep else { return result }
        guard ["mp3", "m4a", "alac", "flac", "aiff", "mka", "ogg", "opus"].contains(target) else {
            throw ConversionError.message("This output cannot preserve embedded cover art. Turn off Preserve cover art or choose another format.")
        }
        guard streams.count <= 8, !pictureTag || streams.count == 1 else {
            throw ConversionError.message(pictureTag
                ? "Ogg and Opus can preserve one cover image. This source has multiple covers."
                : "At most eight embedded cover images can be preserved.")
        }
        do {
            var total = 0
            var iconTypes = Set<Int>()
            for (number, stream) in streams.enumerated() {
                try Task.checkCancellation()
                guard let codec = stream.codec_name, let details = codecs[codec],
                      let width = stream.width, let height = stream.height,
                      width > 0, height > 0, width <= pixelLimit / height else {
                    throw ConversionError.message("Cover art must be a PNG, JPEG, or BMP image with at most 32 million pixels.")
                }
                var bytes = try extract(input, stream: stream, ffmpeg: ffmpeg, work: work, timeout: timeout)
                total += bytes.count
                guard total <= 32 * 1024 * 1024 else {
                    throw ConversionError.message("The embedded cover images exceed 32 MiB in total.")
                }
                let file = work.appendingPathComponent("cover-\(UUID().uuidString).\(details.0)")
                result.files.append(file)
                try bytes.write(to: file, options: .withoutOverwriting)
                var storedFile = file
                var storedCodec = codec
                try ExternalTool.run(ffmpeg, arguments: toolOptions + ["-i", file.path,
                    "-map", "0:v:0", "-frames:v", "1", "-f", "null", "-"],
                    workDirectory: work, timeout: timeout)
                try autoreleasepool {
                    guard let imageSource = CGImageSourceCreateWithData(bytes as CFData,
                            [kCGImageSourceShouldCache: false] as CFDictionary),
                          CGImageSourceGetType(imageSource) as String? == details.2,
                          CGImageSourceGetCount(imageSource) == 1,
                          CGImageSourceGetStatus(imageSource) == .statusComplete,
                          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                          properties[kCGImagePropertyPixelWidth] as? Int == width,
                          properties[kCGImagePropertyPixelHeight] as? Int == height,
                          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                          image.width == width, image.height == height,
                          CGImageSourceGetStatusAtIndex(imageSource, 0) == .statusComplete else {
                        throw ConversionError.message("An embedded cover image is incomplete or unreadable.")
                    }
                    if target == "mka", codec == "bmp" {
                        // Matroska cover art uses PNG or JPEG. Native PNG keeps the BMP color space.
                        storedFile = file.deletingPathExtension().appendingPathExtension("png")
                        result.files.append(storedFile)
                        guard let destination = CGImageDestinationCreateWithURL(storedFile as CFURL,
                                "public.png" as CFString, 1, nil) else {
                            throw ConversionError.message("The cover image could not be prepared for Matroska.")
                        }
                        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
                        guard CGImageDestinationFinalize(destination),
                              try FileVersion(storedFile).size <= byteLimit,
                              let check = CGImageSourceCreateWithURL(storedFile as CFURL, nil),
                              let checkedImage = CGImageSourceCreateImageAtIndex(check, 0, nil),
                              checkedImage.colorSpace?.copyICCData() as Data? == image.colorSpace?.copyICCData() as Data? else {
                            throw ConversionError.message("The prepared cover image exceeds 8 MiB or changed its color data.")
                        }
                        storedCodec = "png"
                    }
                }
                if storedFile != file {
                    guard try pixelHash(file, ffmpeg: ffmpeg, work: work, timeout: timeout)
                        == pixelHash(storedFile, ffmpeg: ffmpeg, work: work, timeout: timeout) else {
                        throw ConversionError.message("The prepared cover image changed its decoded pixels.")
                    }
                    total -= bytes.count
                    bytes = try Data(contentsOf: storedFile)
                    total += bytes.count
                    guard total <= 32 * 1024 * 1024 else {
                        throw ConversionError.message("The prepared cover images exceed 32 MiB in total.")
                    }
                }
                let comment = stream.tag("comment") ?? "Other"
                let type = pictureTypes.firstIndex { $0.caseInsensitiveCompare(comment) == .orderedSame } ?? 0
                let title = preserveMetadata ? stream.tag("title") ?? "" : ""
                guard title.utf8.count <= 4096, !title.contains("\0") else {
                    throw ConversionError.message("The cover image description is invalid or too long.")
                }
                if target == "flac" {
                    guard type != 1 || (codec == "png" && width == 32 && height == 32),
                          ![1, 2].contains(type) || iconTypes.insert(type).inserted else {
                        throw ConversionError.message("FLAC requires unique icon types and a 32×32 PNG for its file icon.")
                    }
                }
                result.pictures.append(Picture(codec: storedCodec, width: width, height: height, bytes: bytes))
                if target == "mka" {
                    let storedDetails = codecs[storedCodec]!
                    let name = number == 0 ? "cover" : "cover-\(number + 1)"
                    result.outputArguments += ["-attach", storedFile.path,
                        "-metadata:s:t:\(number)", "mimetype=\(storedDetails.1)",
                        "-metadata:s:t:\(number)", "filename=\(name).\(storedDetails.0)",
                        "-metadata:s:t:\(number)", "title=\(title)"]
                } else if pictureTag {
                    var block = Data()
                    func integer(_ value: Int) {
                        var number = UInt32(value).bigEndian
                        withUnsafeBytes(of: &number) { block.append(contentsOf: $0) }
                    }
                    func field(_ value: Data) { integer(value.count); block.append(value) }
                    integer(type)
                    field(Data(details.1.utf8))
                    field(Data(title.utf8))
                    // Zero leaves color depth unspecified; native image buffers may add padding.
                    integer(width); integer(height); integer(0); integer(0)
                    field(bytes)
                    let metadata = work.appendingPathComponent("cover-\(UUID().uuidString).ffmetadata")
                    result.files.append(metadata)
                    try Data((";FFMETADATA1\nMETADATA_BLOCK_PICTURE=" + block.base64EncodedString() + "\n").utf8)
                        .write(to: metadata, options: .withoutOverwriting)
                    result.inputArguments = ["-f", "ffmetadata", "-i", metadata.path]
                    // This map precedes source metadata, so an old picture tag cannot replace it.
                    result.metadataArguments = ["-map_metadata", "1"]
                } else {
                    result.outputArguments += ["-map", "0:\(stream.index)", "-c:v:\(number)", "copy",
                        "-disposition:v:\(number)", "attached_pic",
                        "-metadata:s:v:\(number)", "comment=\(pictureTypes[type])",
                        "-metadata:s:v:\(number)", "title=\(title)"]
                }
            }
            if target == "aiff" { result.outputArguments += ["-write_id3v2", "1"] }
            return result
        } catch {
            result.cleanup()
            throw error
        }
    }

    func verify(_ streams: [MediaInfo.Stream], output: URL, ffmpeg: URL, work: URL,
                timeout: TimeInterval) throws {
        guard streams.count == pictures.count else {
            throw ConversionError.message("The encoded cover image count differs from the requested count.")
        }
        var remaining = pictures
        for stream in streams {
            try Task.checkCancellation()
            let bytes = try Self.extract(output, stream: stream, ffmpeg: ffmpeg, work: work, timeout: timeout)
            guard let match = remaining.firstIndex(where: {
                $0.codec == stream.codec_name && $0.width == stream.width
                    && $0.height == stream.height && $0.bytes == bytes
            }) else {
                throw ConversionError.message("An encoded cover image changed its codec, dimensions, or original bytes.")
            }
            remaining.remove(at: match)
        }
    }

    private static func pixelHash(_ file: URL, ffmpeg: URL, work: URL, timeout: TimeInterval) throws -> Data {
        try ExternalTool.run(ffmpeg, arguments: toolOptions + ["-i", file.path, "-map", "0:v:0",
            "-frames:v", "1", "-pix_fmt", "rgba", "-f", "hash", "-hash", "sha256", "pipe:1"],
            workDirectory: work, timeout: timeout, captureOutput: true, outputLimit: 256)
    }

    private static func extract(_ input: URL, stream: MediaInfo.Stream, ffmpeg: URL,
                                work: URL, timeout: TimeInterval) throws -> Data {
        guard stream.isArtwork, stream.index >= 0 else {
            throw ConversionError.message("The selected cover is not an attached image.")
        }
        let bytes = try ExternalTool.run(ffmpeg, arguments: toolOptions + ["-i", input.path,
            "-map", "0:\(stream.index)", "-c:v", "copy", "-frames:v", "1", "-f", "image2pipe", "pipe:1"],
            workDirectory: work, timeout: timeout, captureOutput: true, outputLimit: byteLimit)
        guard !bytes.isEmpty else { throw ConversionError.message("An embedded cover image is empty.") }
        return bytes
    }
}
