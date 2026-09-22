import CoreGraphics
import CoreVideo
import Foundation

struct MediaInfo: Decodable {
    struct Stream: Decodable {
        let index: Int
        let codec_name: String?
        let codec_type: String?
        let width: Int?
        let height: Int?
        let pix_fmt: String?
        let profile: String?
        let channels: Int?
        let sample_rate: String?
        let start_time: String?
        let duration: String?
        let color_transfer: String?
        let disposition: [String: Int]?
        let tags: [String: String]?
        var isArtwork: Bool { codec_type == "video" && disposition?["attached_pic"] == 1 }
        func tag(_ key: String) -> String? {
            tags?.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value
        }
    }
    struct Format: Decodable {
        let format_name: String
        let start_time: String?
        let duration: String?
    }
    let streams: [Stream]
    let format: Format
    var audio: [Stream] { streams.filter { $0.codec_type == "audio" } }
    var video: [Stream] { streams.filter { $0.codec_type == "video" && !$0.isArtwork } }
    var artwork: [Stream] { streams.filter(\.isArtwork) }
}

struct MediaConverter: Sendable {
    private static let gifInputOptions = ["-ignore_loop", "1", "-min_delay", "1", "-default_delay", "10"]

    private static func wmaFrameSamples(rate: Int) -> Int {
        rate <= 16000 ? 512 : rate <= 22050 ? 1024 : 2048
    }

    static func videoRateArguments(codec: String, options: MediaOptions,
                                   macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> [String] {
        if options.videoMode == .bitrate {
            return ["-b:v", "\(options.videoBitrateKbps)k"]
        }
        switch codec {
        case "h264_videotoolbox", "hevc_videotoolbox":
            if macOSMajorVersion >= 15 {
                return ["-q:v", String(min(100, max(1, Int(options.videoQuality))))]
            }
            // Sonoma's VideoToolbox rejects its quality property. Use a logarithmic bitrate
            // range so the same quality control remains useful without changing later systems.
            let lower = 32.0
            let upper = 100_000.0
            let rate = Int((lower * pow(upper / lower, options.videoQuality / 100)).rounded())
            return ["-b:v", "\(rate)k"]
        case "libvpx-vp9":
            return ["-b:v", "0", "-crf", String(Int((63 * (1 - options.videoQuality / 100)).rounded()))]
        case "libsvtav1":
            return ["-b:v", "0", "-crf", String(Int((63 - 62 * options.videoQuality / 100).rounded()))]
        default:
            return ["-b:v", "0", "-q:v",
                    String(min(31, max(2, Int((1 - options.videoQuality / 100) * 29 + 2))))]
        }
    }

    private static func videoTransfer(_ work: URL) throws -> URL {
        let properties: [CFString: Any] = [kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2]
        guard let space = CVImageBufferCreateColorSpaceFromAttachments(properties as CFDictionary)?.takeRetainedValue() else {
            throw ConversionError.message("The native video color space is unavailable.")
        }
        // sRGB and this video space share primaries. Only their component curves differ.
        var table = "LUT_1D_SIZE 256\n"
        for index in 0...255 {
            try Task.checkCancellation()
            let value = CGFloat(index) / 255
            guard let components = CGColor(srgbRed: value, green: value, blue: value, alpha: 1)
                .converted(to: space, intent: .relativeColorimetric, options: nil)?.components,
                components.count == 4, components.allSatisfy(\.isFinite) else {
                throw ConversionError.message("The video color conversion could not be prepared.")
            }
            table += components.prefix(3).map { String(describing: min(1, max(0, $0))) }.joined(separator: " ") + "\n"
        }
        let file = work.appendingPathComponent("video-transfer-\(UUID().uuidString).cube")
        try Data(table.utf8).write(to: file, options: .withoutOverwriting)
        return file
    }
    struct Output: Sendable {
        let muxer: String
        let audio: String
        let video: String?
        let detectedContainer: String
    }

    static let audioOnlyVideoFormats: Set<String> = [
        "avi", "m2ts", "mkv", "mov", "mp4", "mpeg", "ts", "vob", "webm", "wmv"
    ]

    // Explicit containers also cover extensions that FFmpeg cannot infer, such as .alac.
    static let outputs: [String: Output] = [
        "mp3": .init(muxer: "mp3", audio: "libmp3lame", video: nil, detectedContainer: "mp3"),
        "aac": .init(muxer: "adts", audio: "aac", video: nil, detectedContainer: "aac"),
        "m4a": .init(muxer: "ipod", audio: "aac", video: nil, detectedContainer: "mov"),
        "wav": .init(muxer: "wav", audio: "pcm_s24le", video: nil, detectedContainer: "wav"),
        "aiff": .init(muxer: "aiff", audio: "pcm_s24be", video: nil, detectedContainer: "aiff"),
        "flac": .init(muxer: "flac", audio: "flac", video: nil, detectedContainer: "flac"),
        "alac": .init(muxer: "ipod", audio: "alac", video: nil, detectedContainer: "mov"),
        "ogg": .init(muxer: "ogg", audio: "libvorbis", video: nil, detectedContainer: "ogg"),
        "opus": .init(muxer: "opus", audio: "libopus", video: nil, detectedContainer: "ogg"),
        "wma": .init(muxer: "asf", audio: "wmav2", video: nil, detectedContainer: "asf"),
        "caf": .init(muxer: "caf", audio: "pcm_s24le", video: nil, detectedContainer: "caf"),
        "ac3": .init(muxer: "ac3", audio: "ac3", video: nil, detectedContainer: "ac3"),
        "eac3": .init(muxer: "eac3", audio: "eac3", video: nil, detectedContainer: "eac3"),
        "mka": .init(muxer: "matroska", audio: "flac", video: nil, detectedContainer: "matroska"),
        "au": .init(muxer: "au", audio: "pcm_s24be", video: nil, detectedContainer: "au"),
        "tta": .init(muxer: "tta", audio: "tta", video: nil, detectedContainer: "tta"),
        "wv": .init(muxer: "wv", audio: "wavpack", video: nil, detectedContainer: "wv"),
        "mp4": .init(muxer: "mp4", audio: "aac", video: "h264_videotoolbox", detectedContainer: "mov"),
        "mov": .init(muxer: "mov", audio: "aac", video: "h264_videotoolbox", detectedContainer: "mov"),
        "webm": .init(muxer: "webm", audio: "libopus", video: "libvpx-vp9", detectedContainer: "webm"),
        "mkv": .init(muxer: "matroska", audio: "aac", video: "h264_videotoolbox", detectedContainer: "matroska"),
        "avi": .init(muxer: "avi", audio: "libmp3lame", video: "mpeg4", detectedContainer: "avi"),
        "3gp": .init(muxer: "3gp", audio: "aac", video: "h264_videotoolbox", detectedContainer: "mov"),
        "mxf": .init(muxer: "mxf", audio: "pcm_s16le", video: "mpeg2video", detectedContainer: "mxf"),
        "mpeg": .init(muxer: "mpeg", audio: "mp2", video: "mpeg2video", detectedContainer: "mpeg"),
        "m2ts": .init(muxer: "mpegts", audio: "ac3", video: "h264_videotoolbox", detectedContainer: "mpegts"),
        "vob": .init(muxer: "vob", audio: "ac3", video: "mpeg2video", detectedContainer: "mpeg"),
        "wmv": .init(muxer: "asf", audio: "wmav2", video: "wmv2", detectedContainer: "asf"),
        "flv": .init(muxer: "flv", audio: "aac", video: "h264_videotoolbox", detectedContainer: "flv"),
        "ts": .init(muxer: "mpegts", audio: "aac", video: "h264_videotoolbox", detectedContainer: "mpegts")
    ]

    let ffmpeg: URL
    let ffprobe: URL
    let encoders: Set<String>
    let muxers: Set<String>
    let pixelDepths: [String: Int]
    let ffv1PixelFormats: Set<String>

    init(toolsDirectory: URL) throws {
        ffmpeg = toolsDirectory.appendingPathComponent("ffmpeg")
        ffprobe = toolsDirectory.appendingPathComponent("ffprobe")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        func names(_ option: String) throws -> Set<String> {
            let data = try ExternalTool.run(toolsDirectory.appendingPathComponent("ffmpeg"),
                arguments: ["-hide_banner", option], workDirectory: work, timeout: 10, captureOutput: true)
            return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").flatMap { line -> [String] in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 2, fields[0].contains("E") || fields[0].contains(".") else { return [] }
                return fields[1].split(separator: ",").map(String.init)
            })
        }
        let availableEncoders = try names("-encoders")
        encoders = availableEncoders
        muxers = try names("-muxers")
        if availableEncoders.contains("ffv1") {
            let help = try ExternalTool.run(ffmpeg, arguments: ["-hide_banner", "-h", "encoder=ffv1"],
                workDirectory: work, timeout: 10, captureOutput: true)
            let label = "Supported pixel formats:"
            guard let line = String(decoding: help, as: UTF8.self).split(separator: "\n")
                    .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix(label) }) else {
                throw ConversionError.message("The bundled FFV1 encoder did not report its pixel formats.")
            }
            ffv1PixelFormats = Set(line.dropFirst(label.count).split(whereSeparator: \.isWhitespace).map(String.init))
        } else { ffv1PixelFormats = [] }
        struct PixelFormats: Decodable {
            struct Pixel: Decodable {
                struct Component: Decodable { let bit_depth: Int }
                let name: String
                let components: [Component]?
            }
            let pixel_formats: [Pixel]
        }
        let pixels = try ExternalTool.run(ffprobe, arguments: ["-v", "error", "-show_pixel_formats",
            "-of", "json"],
            workDirectory: work, timeout: 10, captureOutput: true)
        var depths: [String: Int] = [:]
        for pixel in try JSONDecoder().decode(PixelFormats.self, from: pixels).pixel_formats {
            if let depth = pixel.components?.map(\.bit_depth).max(), (1...64).contains(depth) {
                depths[pixel.name] = depth
            }
        }
        pixelDepths = depths
    }

    func supports(_ id: String) -> Bool {
        guard let output = Self.outputs[id] else { return false }
        return muxers.contains(output.muxer) && encoders.contains(output.audio)
            && (output.video == nil || encoders.contains(output.video!))
    }

    func inspect(_ file: URL, work: URL) throws -> MediaInfo {
        let nativeType = ImageConverter.detectedType(at: file)
        var inputOptions = nativeType == "com.compuserve.gif" ? Self.gifInputOptions : []
        if nativeType == nil, try Self.isTransportStream(file) { inputOptions += ["-f", "mpegts"] }
        let data = try ExternalTool.run(ffprobe, arguments: [
            "-v", "error", "-max_alloc", "268435456", "-max_pixels", "32200000", "-threads", "1",
            "-protocol_whitelist", "file,pipe", "-show_entries",
            "format=format_name,start_time,duration:stream=index,codec_name,codec_type,width,height,pix_fmt,profile,channels,sample_rate,start_time,duration,color_transfer:stream_disposition:stream_tags=language,title,comment,mimetype,filename",
            "-of", "json"
        ] + inputOptions + ["-i", file.path], workDirectory: work, timeout: 30, captureOutput: true)
        return try JSONDecoder().decode(MediaInfo.self, from: data)
    }

    private static func isTransportStream(_ file: URL) throws -> Bool {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let bytes = try input.read(upToCount: 616) ?? Data()
        return transportPacketStride(bytes) != nil
    }

    static func transportPacketStride(_ bytes: Data) -> Int? {
        for (stride, start) in [(188, 0), (192, 4), (204, 0)] where bytes.count >= start + stride * 2 + 4 {
            if (0..<3).allSatisfy({ index in
                let offset = start + index * stride
                return bytes[offset] == 0x47 && bytes[offset + 3] & 0x30 != 0
            }) { return stride }
        }
        return nil
    }

    func convert(_ input: URL, to output: URL, format: FileFormat, options: MediaOptions) throws {
        guard supports(format.id), let target = Self.outputs[format.id] else {
            throw ConversionError.message("The installed FFmpeg cannot encode this format.")
        }
        guard (8...1536).contains(options.audioBitrateKbps),
              options.audioQuality.isFinite, (0...100).contains(options.audioQuality),
              (0...12).contains(options.flacCompressionLevel),
              options.videoQuality.isFinite, (0...100).contains(options.videoQuality),
              (0...8).contains(options.vp9Speed), (0...13).contains(options.av1Speed),
              (32...200_000).contains(options.videoBitrateKbps),
              options.sampleRate.map({ (8000...384_000).contains($0) }) ?? true,
              options.channels.map({ (1...8).contains($0) }) ?? true,
              options.timeout.isFinite, options.timeout > 0 else {
            throw ConversionError.message("A media setting is outside its allowed range.")
        }
        let work = output.deletingLastPathComponent()
        let source = try inspect(input, work: work)
        let isGIF = source.format.format_name.split(separator: ",").contains("gif")
        guard source.audio.count <= 1, source.video.count <= 1,
              source.streams.allSatisfy({ ["audio", "video"].contains($0.codec_type ?? "") }) else {
            throw ConversionError.message("Multiple audio or video tracks, subtitles, and other attachments need controls that are not implemented yet.")
        }
        let includeVideo = target.video != nil && !source.video.isEmpty
        let checkTiming = !includeVideo || !isGIF || options.videoFrameRate != .preserveSource
        let threads = String(options.cpuProfile.limits().encoderThreads)
        var leadFilter: String?
        let audioSync = "aresample=async=1:min_hard_comp=0.001:first_pts=0"
        var audioFilter = includeVideo && !source.audio.isEmpty && ["avi", "mxf", "wmv"].contains(format.id)
            ? audioSync : nil
        if !includeVideo {
            // Standalone Vorbis has continuous PCM. Block changes can give misleading packet times.
            audioFilter = source.format.format_name == "ogg" && source.video.isEmpty
                && source.audio.first?.codec_name == "vorbis"
                ? "asetpts=N/SR/TB" : "asetpts=PTS-STARTPTS,\(audioSync)"
        }
        let videoCodec = options.videoCodec.encoder ?? target.video
        if includeVideo {
            guard let width = source.video.first?.width, let height = source.video.first?.height,
                  width > 0, height > 0, width <= 32_200_000 / height else {
                throw ConversionError.message("Video conversion supports frames up to 32.2 million pixels.")
            }
            guard VideoCodec.choices(for: format.id).contains(options.videoCodec),
                  let videoCodec, encoders.contains(videoCodec) else {
                throw ConversionError.message("The selected video codec cannot be written to this container. Choose Automatic or another codec.")
            }
            guard videoCodec != "libsvtav1" || options.videoMode != .bitrate || options.videoBitrateKbps <= 100_000 else {
                throw ConversionError.message("AV1 bitrate must not exceed 100,000 kb/s.")
            }
        }
        guard !source.audio.isEmpty || includeVideo else {
            throw ConversionError.message("The source has no stream for this output format.")
        }
        guard target.video == nil || includeVideo || Self.audioOnlyVideoFormats.contains(format.id) else {
            throw ConversionError.message("This container needs a video stream.")
        }
        if format.id == "mxf", includeVideo, let video = source.video.first, let audio = source.audio.first {
            // MXF needs equal track extents. Decode the ends before adding black or silence.
            let bounds = try MediaTiming.mxfBounds(input: input, ffmpeg: ffmpeg, work: work,
                video: "0:\(video.index)", audio: "0:\(audio.index)",
                inputOptions: source.format.format_name == "mpegts" ? ["-f", "mpegts"] : [],
                threads: threads, timeout: options.timeout)
            leadFilter = "setpts=PTS-STARTPTS,tpad=start_duration=\(bounds.videoStart):stop_duration=\(max(0, bounds.end - bounds.videoEnd)):color=black"
            audioFilter = "\(audioSync),apad=whole_dur=\(bounds.end)"
        } else if format.id == "avi", includeVideo, audioFilter != nil {
            guard let videoStart = source.video.first?.start_time.flatMap(Double.init),
                  let origin = source.format.start_time.flatMap(Double.init),
                  videoStart.isFinite, origin.isFinite, (videoStart - origin).isFinite else {
                throw ConversionError.message("This container needs known audio and video starting times.")
            }
            let lead = max(0, videoStart - origin)
            if lead > 0 {
                // AVI starts both tracks at zero. Represent a picture delay as black frames.
                leadFilter = "setpts=PTS-STARTPTS,tpad=start_duration=\(lead):color=black"
            }
        }
        let artwork = try MediaArtwork.prepare(input: input, streams: source.artwork, target: format.id,
            preserve: options.preserveCoverArt, preserveMetadata: options.preserveMetadata,
            ffmpeg: ffmpeg, work: work, timeout: min(options.timeout, 30))
        defer { artwork.cleanup() }
        var arguments = ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-n",
                         "-max_alloc", "268435456", "-max_pixels", "32200000", "-err_detect", "explode",
                         "-filter_threads", threads, "-filter_complex_threads", threads, "-threads", threads,
                         "-protocol_whitelist", "file,pipe"]
        if isGIF { arguments += Self.gifInputOptions }
        else if source.format.format_name == "mpegts" { arguments += ["-f", "mpegts"] }
        arguments += ["-i", input.path] + artwork.inputArguments + artwork.metadataArguments + [
                         "-map_metadata", options.preserveMetadata ? "0" : "-1",
                         "-map_chapters", options.preserveMetadata ? "0" : "-1"]
        if !options.preserveMetadata { arguments += ["-map_metadata:s", "-1"] }
        if checkTiming {
            // Filter outputs need explicit source tags and track flags.
            for (kind, stream) in [("v", includeVideo ? source.video.first : nil), ("a", source.audio.first)] {
                guard let stream else { continue }
                let flags = (stream.disposition ?? [:]).filter { $0.value == 1 }.keys.sorted().joined(separator: "+")
                arguments += ["-disposition:\(kind):0", flags.isEmpty ? "0" : flags]
                if options.preserveMetadata {
                    arguments += ["-map_metadata:s:\(kind):0", "0:s:\(stream.index)"]
                }
            }
        }
        if includeVideo, let video = source.video.first {
            arguments += ["-map", checkTiming ? "[converted_video]" : "0:\(video.index)"]
        }
        if let audio = source.audio.first {
            arguments += ["-map", checkTiming ? "[converted_audio]" : "0:\(audio.index)"]
            arguments += ["-c:a", target.audio, "-threads:a", threads]
            var encodingFilters = checkTiming ? [] : audioFilter.map { [$0] } ?? []
            if target.audio == "wmav2" {
                guard let rate = options.sampleRate ?? source.audio.first?.sample_rate.flatMap(Int.init),
                      rate > 0, rate <= 48000 else {
                    throw ConversionError.message("WMA output needs a sample rate at or below 48 kHz.")
                }
                let padding = Self.wmaFrameSamples(rate: rate)
                // WMA drops its first window. Supply silence and keep the original sample times.
                encodingFilters.append("aresample=\(rate),adelay=\(padding)S:all=1,asetpts=PTS-\(padding)")
            }
            let tailPadding = switch target.audio {
            case "mp2": 481
            case "ac3", "eac3": 256
            default: 0
            }
            if tailPadding > 0 {
                // These encoders can lose the delayed tail. Pad at the negotiated encoder rate.
                encodingFilters.append("aresample,apad=pad_len=\(tailPadding)")
            }
            if checkTiming {
                // One graph feeds both outputs. Separate graphs can stall while an encoder fills its first frame.
                // Convert only the timing branch to 16-bit. It must not limit the encoder's precision.
                let graph = ["[0:\(audio.index)]\(audioFilter ?? "anull"),asplit=2[audio_input][timing_audio]",
                             "[timing_audio]aresample=osf=s16[source_audio]",
                             "[audio_input]\(encodingFilters.isEmpty ? "anull" : encodingFilters.joined(separator: ","))[converted_audio]"]
                arguments += ["-filter_complex", graph.joined(separator: ";")]
            } else if !encodingFilters.isEmpty {
                arguments += ["-af", encodingFilters.joined(separator: ",")]
            }
            let quality: Double? = if target.video == nil && options.audioMode == .quality {
                switch target.audio {
                case "libmp3lame": 9 - options.audioQuality * 0.09
                case "aac": 0.1 + options.audioQuality * 0.049
                case "libvorbis": options.audioQuality / 10
                default: nil
                }
            } else { nil }
            if let quality {
                arguments += ["-q:a", String(quality)]
            } else if !target.audio.hasPrefix("pcm_"), !["flac", "alac", "tta", "wavpack"].contains(target.audio) {
                arguments += ["-b:a", "\(options.audioBitrateKbps)k"]
            }
            if target.video == nil, target.audio == "flac" {
                arguments += ["-compression_level:a", String(options.flacCompressionLevel)]
            }
            if let rate = options.sampleRate { arguments += ["-ar", String(rate)] }
            if let channels = options.channels { arguments += ["-ac", String(channels)] }
        }
        var transfer: URL?
        var gifTicks: Int?
        var expectedDepth: Int?
        let sourceTiming = work.appendingPathComponent("media-source-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: sourceTiming) }
        defer { if let transfer { try? FileManager.default.removeItem(at: transfer) } }
        if includeVideo, let codec = videoCodec {
            guard let pixel = source.video.first?.pix_fmt, let depth = pixelDepths[pixel] else {
                throw ConversionError.message("The source video pixel format could not be read.")
            }
            let pixelFormat: String
            switch codec {
            case "hevc_videotoolbox":
                pixelFormat = depth > 8 ? "p010le" : "yuv420p"
                expectedDepth = depth > 8 ? 10 : 8
            case "libvpx-vp9":
                let bits = depth > 10 ? 12 : depth > 8 ? 10 : 8
                pixelFormat = bits == 8 ? "yuv420p" : "yuv420p\(bits)le"
                expectedDepth = bits
            case "libsvtav1":
                pixelFormat = depth > 8 ? "yuv420p10le" : "yuv420p"
                expectedDepth = depth > 8 ? 10 : 8
            case "prores_videotoolbox":
                pixelFormat = options.proResProfile.rawValue >= 4 ? "ayuv64le" : "p216le"
                expectedDepth = options.proResProfile.rawValue >= 4 ? 12 : 10
            case "ffv1":
                guard ffv1PixelFormats.contains(pixel) else {
                    throw ConversionError.message("FFV1 cannot preserve this source's decoded pixel format.")
                }
                pixelFormat = pixel
                expectedDepth = depth
            default:
                pixelFormat = "yuv420p"
                expectedDepth = 8
            }
            var filters = checkTiming ? [] : leadFilter.map { [$0] } ?? []
            if isGIF {
                // GIF timing uses hundredths of a second. Opaque video composites alpha on black.
                let table = try Self.videoTransfer(work)
                transfer = table
                let delays = try GIFMetadata(input).frames.map { frame in
                    let ticks = Int((frame.delay * 100).rounded())
                    return ticks == 0 ? 10 : ticks
                }
                // Keep exact GIF timing at the lowest whole frame rate permitted by the container.
                let ticks = delays.reduce(0, +)
                if options.videoFrameRate == .preserveSource { gifTicks = ticks }
                let rates = format.id == "mxf" ? [25, 50, 100]
                    : [1, 2, 4, 5, 10, 20, 25, 50, 100] + (format.id == "wmv" ? [200] : [])
                let automaticRate = rates.first { rate in
                    delays.allSatisfy { ($0 * rate) % 100 == 0 }
                        && (format.id != "wmv" || ticks * rate / 100 >= 2)
                } ?? 100
                let rate = options.videoFrameRate == .preserveSource ? String(automaticRate) : options.videoFrameRate.rawValue
                if codec == "h264_videotoolbox" {
                    // Transport streams need timing in the bitstream, including a one-frame clip.
                    arguments += ["-bsf:v", "h264_metadata=tick_rate=\(rate)*2"]
                }
                let matrix = ["mpeg4", "wmv2", "msmpeg4"].contains(codec) ? "smpte170m" : "bt709"
                filters = ["format=gbrap"]
                if codec != "prores_videotoolbox" || options.proResProfile.rawValue < 4 {
                    filters.append("premultiply=inplace=1")
                }
                filters += ["lut1d=file=\(table.lastPathComponent):interp=linear",
                            "scale=out_color_matrix=\(matrix):out_range=tv", "fps=\(rate):eof_action=pass"]
                arguments += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", matrix, "-color_range", "tv"]
            } else if options.videoFrameRate != .preserveSource {
                filters.append("fps=\(options.videoFrameRate.rawValue):eof_action=pass")
            }
            if ["h264_videotoolbox", "hevc_videotoolbox", "libsvtav1", "wmv2"].contains(codec) {
                filters.append("pad=ceil(iw/2)*2:ceil(ih/2)*2:0:0:color=black")
            }
            if checkTiming, let video = source.video.first {
                // Keep audio and video in separate graphs so one track cannot retain the other's frames.
                let graph = ["[0:\(video.index)]\(leadFilter ?? "null"),split=2[video_input][source_video]",
                             "[video_input]\(filters.isEmpty ? "null" : filters.joined(separator: ","))[converted_video]"]
                arguments += ["-filter_complex", graph.joined(separator: ";")]
            } else if !filters.isEmpty {
                arguments += ["-vf", filters.joined(separator: ",")]
            }
            arguments += ["-c:v", codec, "-threads:v", threads, "-pix_fmt", pixelFormat,
                          "-fps_mode:v", "passthrough"]
            if !isGIF, options.videoFrameRate == .preserveSource, !["mpeg4", "mpeg2video", "msmpeg4"].contains(codec) {
                arguments += ["-enc_time_base:v", "demux"]
            }
            if codec == "prores_videotoolbox" {
                arguments += ["-profile:v", String(options.proResProfile.rawValue)]
            } else if codec == "ffv1" {
                // FFV1 keeps every pixel. Quality and bitrate settings do not apply to it.
            } else {
                // VP9 reaches lossless CRF 0. SVT-AV1 stops at 1 because its wrapper treats zero as
                // an omitted value. Other codecs use their own quality or bitrate scales.
                arguments += Self.videoRateArguments(codec: codec, options: options)
            }
            if ["mpeg", "vob"].contains(format.id) {
                // Allow one second at the target rate, including 1 fps image input.
                // Stay below the program stream's 8 MiB decoder-buffer field limit.
                let bufferBits = options.videoMode == .quality ? 63 * 1024 * 1024
                    : min(max(1_835_008, options.videoBitrateKbps * 1000), 63 * 1024 * 1024)
                let peak = options.videoMode == .quality ? 100_000 : options.videoBitrateKbps * 2
                arguments += ["-maxrate:v", "\(peak)k", "-bufsize:v", String(bufferBits)]
            }
            if codec.hasSuffix("_videotoolbox") { arguments += ["-allow_sw", "1"] }
            if codec == "hevc_videotoolbox", ["mp4", "mov"].contains(format.id) { arguments += ["-tag:v", "hvc1"] }
            if codec == "libvpx-vp9" { arguments += ["-cpu-used", String(options.vp9Speed)] }
            if codec == "libsvtav1" {
                arguments += ["-preset", String(options.av1Speed), "-svtav1-params", "lp=2"]
            }
        }
        if format.id == "m2ts" { arguments += ["-mpegts_m2ts_mode", "1"] }
        // AVI cannot express the fractional video shift caused by MP3 encoder preroll.
        if format.id == "avi" { arguments += ["-avoid_negative_ts", "disabled"] }
        if ["mp4", "mov", "m4a", "alac"].contains(format.id) { arguments += ["-movflags", "+faststart"] }
        arguments += artwork.outputArguments
        arguments += ["-f", target.muxer, output.path]
        if checkTiming {
            arguments += MediaTiming.arguments(stream: includeVideo ? "[source_video]" : nil,
                audioStream: source.audio.isEmpty ? nil : "[source_audio]")
        }
        try ExternalTool.run(ffmpeg, arguments: arguments, workDirectory: work, timeout: options.timeout,
            outputFile: checkTiming ? sourceTiming : nil, outputLimit: MediaTiming.byteLimit)
        if format.id == "ts" {
            let size = try FileVersion(output).size
            guard size > 0, size % 188 == 0 else { throw ConversionError.message("The transport stream has incomplete packets.") }
            if size < 12 * 188 {
                // Standard null packets make short files large enough for common format probes.
                let file = try FileHandle(forWritingTo: output)
                defer { try? file.close() }
                try file.seekToEnd()
                let packet = Data([0x47, 0x1f, 0xff, 0x10]) + Data(repeating: 0xff, count: 184)
                for _ in Int(size / 188)..<12 { try file.write(contentsOf: packet) }
            }
        }
        let result = try inspect(output, work: work)
        guard result.format.format_name.split(separator: ",").contains(Substring(target.detectedContainer)),
              result.audio.count == source.audio.count, result.video.count == (includeVideo ? 1 : 0),
              result.streams.allSatisfy({ ["audio", "video"].contains($0.codec_type ?? "") }) else {
            throw ConversionError.message("The encoded container or stream count is wrong.")
        }
        try artwork.verify(result.artwork, output: output, ffmpeg: ffmpeg, work: work,
                           timeout: min(options.timeout, 30))
        let codecNames = ["libmp3lame": "mp3", "libopus": "opus", "libvorbis": "vorbis",
                          "h264_videotoolbox": "h264", "hevc_videotoolbox": "hevc",
                          "prores_videotoolbox": "prores", "libvpx-vp9": "vp9", "libsvtav1": "av1",
                          "msmpeg4": "msmpeg4v3"]
        if let audio = result.audio.first, audio.codec_name != (codecNames[target.audio] ?? target.audio) {
            throw ConversionError.message("The encoded audio codec is wrong.")
        }
        if let video = result.video.first, let codec = videoCodec,
           video.codec_name != (codecNames[codec] ?? codec) {
            throw ConversionError.message("The encoded video codec is wrong.")
        }
        if let video = result.video.first, let expectedDepth,
           video.pix_fmt.flatMap({ pixelDepths[$0] }) != expectedDepth {
            throw ConversionError.message("The encoded video has the wrong color bit depth.")
        }
        if videoCodec == "prores_videotoolbox", let video = result.video.first {
            let profile = options.proResProfile.rawValue
            guard video.profile == String(profile)
                || video.profile == ["Proxy", "LT", "Standard", "HQ", "4444", "XQ"][profile] else {
                throw ConversionError.message("The encoded ProRes profile differs from the selected profile.")
            }
        }
        if let video = result.video.first, let original = source.video.first {
            let even = ["h264_videotoolbox", "hevc_videotoolbox", "libsvtav1", "wmv2"].contains(videoCodec ?? "")
            let width = original.width.map { even ? $0 + $0 % 2 : $0 }
            let height = original.height.map { even ? $0 + $0 % 2 : $0 }
            guard (video.width == width && video.height == height)
                || (video.width == height && video.height == width) else {
                throw ConversionError.message("The encoded video dimensions differ from the source.")
            }
        }
        if let audio = result.audio.first, let channels = options.channels ?? source.audio.first?.channels,
           audio.channels != channels {
            throw ConversionError.message("The encoded channel count differs from the requested count.")
        }
        // Opus always declares a 48 kHz playback rate, including when its encoder input uses a lower rate.
        if let audio = result.audio.first, let rate = options.sampleRate,
           audio.sample_rate.flatMap(Int.init) != (target.audio == "libopus" ? 48000 : rate) {
            throw ConversionError.message("The encoded sample rate differs from the requested rate.")
        }
        if let gifTicks { try validateImageVideo(output, ticks: gifTicks, work: work) }
        if checkTiming {
            let inputOptions = try Self.isTransportStream(output) ? ["-f", "mpegts"] : []
            let paddingSamples: Int = switch target.audio {
            case "libmp3lame", "mp2": 1152
            case "aac": 1024
            case "libvorbis": 1024
            case "libopus": 960
            case "ac3", "eac3": 1536
            case "wmav2": 2 * Self.wmaFrameSamples(rate: result.audio.first?.sample_rate.flatMap(Int.init) ?? 48000)
            default: 0
            }
            let audioPadding: Double?
            if let audio = result.audio.first {
                guard let rate = audio.sample_rate.flatMap(Double.init), rate.isFinite, rate > 0 else {
                    throw ConversionError.message("The encoded audio sample rate could not be read.")
                }
                audioPadding = Double(paddingSamples) / rate
            } else { audioPadding = nil }
            // These audio formats can declare their sample length. Keep their truncation check.
            let sourceDuration = source.video.isEmpty
                && ["flac", "wav", "aiff", "au", "caf", "tta", "wv"].contains(source.format.format_name)
                ? source.audio.first?.duration.flatMap(Double.init) : nil
            try MediaTiming.validate(source: sourceTiming, output: output, ffmpeg: ffmpeg, work: work,
                inputOptions: inputOptions, rate: options.videoFrameRate, timeout: options.timeout,
                estimatesFinalDuration: source.format.format_name == "asf" || target.muxer == "asf",
                usesFrameClock: ["mpeg4", "mpeg2video", "msmpeg4"].contains(videoCodec ?? ""),
                audioPadding: audioPadding, includeVideo: includeVideo, sourceDuration: sourceDuration)
        }
    }

    private func validateImageVideo(_ output: URL, ticks: Int, work: URL) throws {
        // Check the decoded timeline. Some containers only estimate their final frame's duration.
        let inputOptions = try Self.isTransportStream(output) ? ["-f", "mpegts"] : []
        let progress = try ExternalTool.run(ffmpeg, arguments: [
            "-hide_banner", "-v", "error", "-nostdin", "-xerror", "-max_alloc", "268435456",
            "-threads", "1", "-filter_threads", "1", "-err_detect", "explode", "-max_pixels", "32200000",
            "-protocol_whitelist", "file,pipe"] + inputOptions + ["-i", output.path, "-map", "0:v:0", "-an", "-sn", "-dn",
            "-vf", "setpts=PTS-STARTPTS,fps=100", "-fps_mode", "passthrough", "-progress", "pipe:1", "-f", "null", "-"
        ], workDirectory: work, timeout: 120, captureOutput: true)
        let lines = String(decoding: progress, as: UTF8.self).split(separator: "\n")
        guard lines.last == "progress=end", let frame = lines.last(where: { $0.hasPrefix("frame=") }),
              Int(frame.dropFirst(6)) == ticks else {
            throw ConversionError.message("The encoded image video changed its playback duration.")
        }
    }
}
