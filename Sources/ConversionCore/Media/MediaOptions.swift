import Foundation

public enum MediaEncodingMode: String, Codable, CaseIterable, Sendable {
    case quality, bitrate
}

public typealias AudioEncodingMode = MediaEncodingMode

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case automatic, h264, hevc, vp9, av1, prores, ffv1, mpeg2video, msmpeg4

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .vp9: "VP9"
        case .av1: "AV1"
        case .prores: "ProRes"
        case .ffv1: "FFV1"
        case .mpeg2video: "MPEG-2"
        case .msmpeg4: "MS MPEG-4 v3"
        }
    }

    public static func choices(for container: String) -> [Self] {
        switch container {
        case "mp4": [.automatic, .h264, .hevc, .vp9, .av1]
        case "mov": [.automatic, .h264, .hevc, .prores]
        case "mkv": allCases
        case "webm": [.automatic, .vp9, .av1]
        case "3gp", "flv": [.automatic, .h264]
        case "m2ts", "ts": [.automatic, .h264, .mpeg2video]
        case "avi": [.automatic, .mpeg2video, .msmpeg4]
        case "mxf", "mpeg", "vob": [.automatic, .mpeg2video]
        case "wmv": [.automatic, .msmpeg4]
        default: [.automatic]
        }
    }

    var encoder: String? {
        switch self {
        case .automatic: nil
        case .h264: "h264_videotoolbox"
        case .hevc: "hevc_videotoolbox"
        case .vp9: "libvpx-vp9"
        case .av1: "libsvtav1"
        case .prores: "prores_videotoolbox"
        case .ffv1: "ffv1"
        case .mpeg2video: "mpeg2video"
        case .msmpeg4: "msmpeg4"
        }
    }
}

public enum VideoFrameRate: String, Codable, CaseIterable, Sendable {
    case preserveSource = "preserve_source"
    case fps23_976 = "24000/1001", fps24 = "24", fps25 = "25", fps29_97 = "30000/1001"
    case fps30 = "30", fps50 = "50", fps59_94 = "60000/1001", fps60 = "60"

    public var title: String {
        switch self {
        case .preserveSource: "Preserve source"
        case .fps23_976: "23.976 fps"
        case .fps29_97: "29.97 fps"
        case .fps59_94: "59.94 fps"
        default: "\(rawValue) fps"
        }
    }

    var value: Double? {
        let parts = rawValue.split(separator: "/")
        guard let numerator = parts.first.flatMap({ Double($0) }) else { return nil }
        return numerator / (parts.count == 2 ? Double(parts[1])! : 1)
    }
}

public enum ProResProfile: Int, Codable, CaseIterable, Sendable {
    case proxy, lt, standard, hq, rgba4444, xq

    public var title: String {
        switch self {
        case .proxy: "Proxy"
        case .lt: "LT"
        case .standard: "Standard"
        case .hq: "HQ"
        case .rgba4444: "4444"
        case .xq: "4444 XQ"
        }
    }
}

public struct MediaOptions: Codable, Equatable, Sendable {
    public var audioMode: AudioEncodingMode = .quality
    public var audioQuality: Double = 100
    public var audioBitrateKbps = 192
    public var flacCompressionLevel = 8
    public var preserveCoverArt = true
    public var videoCodec = VideoCodec.automatic
    public var videoMode = MediaEncodingMode.quality
    public var videoQuality: Double = 100
    public var videoBitrateKbps = 2500
    public var videoFrameRate = VideoFrameRate.preserveSource
    public var vp9Speed = 1
    public var av1Speed = 8
    public var proResProfile = ProResProfile.hq
    public var sampleRate: Int?
    public var channels: Int?
    public var preserveMetadata = true
    public var cpuProfile = CPUProfile.medium
    public var timeout: TimeInterval = 3600
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case audioMode, audioQuality, audioBitrateKbps, flacCompressionLevel, preserveCoverArt
        case videoCodec, videoMode, videoQuality, videoFrameRate, vp9Speed, av1Speed, proResProfile
        case videoBitrateKbps, sampleRate, channels, preserveMetadata, cpuProfile, timeout
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        audioMode = try values.decodeIfPresent(AudioEncodingMode.self, forKey: .audioMode) ?? .quality
        audioQuality = try values.decodeIfPresent(Double.self, forKey: .audioQuality) ?? 100
        audioBitrateKbps = try values.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? 192
        flacCompressionLevel = try values.decodeIfPresent(Int.self, forKey: .flacCompressionLevel) ?? 8
        preserveCoverArt = try values.decodeIfPresent(Bool.self, forKey: .preserveCoverArt) ?? true
        videoCodec = try values.decodeIfPresent(VideoCodec.self, forKey: .videoCodec) ?? .automatic
        // Older saved video settings used bitrate without a mode field.
        videoMode = try values.decodeIfPresent(MediaEncodingMode.self, forKey: .videoMode)
            ?? (values.contains(.videoBitrateKbps) ? .bitrate : .quality)
        videoQuality = try values.decodeIfPresent(Double.self, forKey: .videoQuality) ?? 100
        videoBitrateKbps = try values.decodeIfPresent(Int.self, forKey: .videoBitrateKbps) ?? 2500
        videoFrameRate = try values.decodeIfPresent(VideoFrameRate.self, forKey: .videoFrameRate) ?? .preserveSource
        vp9Speed = try values.decodeIfPresent(Int.self, forKey: .vp9Speed) ?? 1
        av1Speed = try values.decodeIfPresent(Int.self, forKey: .av1Speed) ?? 8
        proResProfile = try values.decodeIfPresent(ProResProfile.self, forKey: .proResProfile) ?? .hq
        sampleRate = try values.decodeIfPresent(Int.self, forKey: .sampleRate)
        channels = try values.decodeIfPresent(Int.self, forKey: .channels)
        preserveMetadata = try values.decodeIfPresent(Bool.self, forKey: .preserveMetadata) ?? true
        cpuProfile = try values.decodeIfPresent(CPUProfile.self, forKey: .cpuProfile) ?? .medium
        timeout = try values.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 3600
    }
}
