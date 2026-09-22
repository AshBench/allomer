import CoreGraphics
import Foundation

public enum ImageCompressionMode: String, Codable, CaseIterable, Sendable {
    case lossy, lossless
}

public enum ImageAlphaHandling: String, Codable, CaseIterable, Sendable {
    case preserve, white, black, custom
}

public enum TIFFCompression: String, Codable, CaseIterable, Sendable {
    case automatic = "auto", none, lzw, deflate, jpeg

    var code: Int? {
        switch self {
        case .automatic: nil
        case .none: 1
        case .lzw: 5
        case .deflate: 8
        case .jpeg: 7
        }
    }
}

public struct ImageOptions: Codable, Equatable, Sendable {
    public var quality: Double = 0.85
    public var preserveMetadata = true
    public var convertToSRGB = false
    public var alphaHandling: ImageAlphaHandling = .preserve
    public var alphaCustomColor = "#FFFFFF"
    public var progressiveJPEG = false
    public var pngCompressionLevel = 6
    public var gifMaxColors = 256
    public var gifDither = true
    public var tiffCompression: TIFFCompression = .automatic
    public var tiffJPEGQuality = 0.85
    public var webpMode: ImageCompressionMode = .lossy
    public var webpEffort = 4
    public var jpegXLMode: ImageCompressionMode = .lossy
    public var jpegXLEffort = 7
    public var videoFrameRate = 15.0
    public var videoMaxWidth = 0
    public var videoLoopCount = 0
    public var videoGIFColors = 256
    public var videoGIFDither = true
    // Animated image output. Nil keeps each source frame's own delay and the source repeat count.
    public var animationFrameRate: Double?
    public var animationPlays: Int?
    public var animationMaxWidth = 0
    // Video to animation. Preserve keeps every decoded frame and its own duration.
    public var videoPreserveFrameRate = false
    public var svgWidth = 0
    public var svgHeight = 0
    public var svgScale = 1.0
    public var tracing = SVGTracingOptions()

    public init() {}
    private enum CodingKeys: String, CodingKey { case quality, preserveMetadata, convertToSRGB, alphaHandling, alphaCustomColor, progressiveJPEG, pngCompressionLevel, gifMaxColors, gifDither, tiffCompression, tiffJPEGQuality, webpMode, webpEffort, jpegXLMode, jpegXLEffort, videoFrameRate, videoMaxWidth, videoLoopCount, videoGIFColors, videoGIFDither, animationFrameRate, animationPlays, animationMaxWidth, videoPreserveFrameRate, svgWidth, svgHeight, svgScale, tracing }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        quality = try values.decodeIfPresent(Double.self, forKey: .quality) ?? 0.85
        preserveMetadata = try values.decodeIfPresent(Bool.self, forKey: .preserveMetadata) ?? true
        convertToSRGB = try values.decodeIfPresent(Bool.self, forKey: .convertToSRGB) ?? false
        alphaHandling = try values.decodeIfPresent(ImageAlphaHandling.self, forKey: .alphaHandling) ?? .preserve
        alphaCustomColor = try values.decodeIfPresent(String.self, forKey: .alphaCustomColor) ?? "#FFFFFF"
        progressiveJPEG = try values.decodeIfPresent(Bool.self, forKey: .progressiveJPEG) ?? false
        pngCompressionLevel = try values.decodeIfPresent(Int.self, forKey: .pngCompressionLevel) ?? 6
        gifMaxColors = try values.decodeIfPresent(Int.self, forKey: .gifMaxColors) ?? 256
        gifDither = try values.decodeIfPresent(Bool.self, forKey: .gifDither) ?? true
        tiffCompression = try values.decodeIfPresent(TIFFCompression.self, forKey: .tiffCompression) ?? .automatic
        tiffJPEGQuality = try values.decodeIfPresent(Double.self, forKey: .tiffJPEGQuality) ?? 0.85
        webpMode = try values.decodeIfPresent(ImageCompressionMode.self, forKey: .webpMode) ?? .lossy
        webpEffort = try values.decodeIfPresent(Int.self, forKey: .webpEffort) ?? 4
        let mode = try values.decodeIfPresent(ImageCompressionMode.self, forKey: .jpegXLMode)
        jpegXLMode = mode ?? (quality == 1 ? .lossless : .lossy)
        if let effort = try values.decodeIfPresent(Int.self, forKey: .jpegXLEffort) {
            jpegXLEffort = effort
        } else if mode == nil, jpegXLMode == .lossless {
            enum LegacyKeys: String, CodingKey { case jpegXLLosslessEffort }
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            jpegXLEffort = try legacy.decodeIfPresent(Int.self, forKey: .jpegXLLosslessEffort) ?? 4
        }
        videoFrameRate = try values.decodeIfPresent(Double.self, forKey: .videoFrameRate) ?? 15
        videoMaxWidth = try values.decodeIfPresent(Int.self, forKey: .videoMaxWidth) ?? 0
        videoLoopCount = try values.decodeIfPresent(Int.self, forKey: .videoLoopCount) ?? 0
        videoGIFColors = try values.decodeIfPresent(Int.self, forKey: .videoGIFColors) ?? 256
        videoGIFDither = try values.decodeIfPresent(Bool.self, forKey: .videoGIFDither) ?? true
        animationFrameRate = try values.decodeIfPresent(Double.self, forKey: .animationFrameRate)
        animationPlays = try values.decodeIfPresent(Int.self, forKey: .animationPlays)
        animationMaxWidth = try values.decodeIfPresent(Int.self, forKey: .animationMaxWidth) ?? 0
        videoPreserveFrameRate = try values.decodeIfPresent(Bool.self, forKey: .videoPreserveFrameRate) ?? false
        svgWidth = try values.decodeIfPresent(Int.self, forKey: .svgWidth) ?? 0
        svgHeight = try values.decodeIfPresent(Int.self, forKey: .svgHeight) ?? 0
        svgScale = try values.decodeIfPresent(Double.self, forKey: .svgScale) ?? 1
        tracing = try values.decodeIfPresent(SVGTracingOptions.self, forKey: .tracing) ?? SVGTracingOptions()
    }

    func backgroundColor() throws -> CGColor? {
        switch alphaHandling {
        case .preserve: return nil
        case .white: return CGColor(gray: 1, alpha: 1)
        case .black: return CGColor(gray: 0, alpha: 1)
        case .custom:
            let hex = alphaCustomColor.hasPrefix("#") ? String(alphaCustomColor.dropFirst()) : alphaCustomColor
            guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let value = UInt32(hex, radix: 16) else {
                throw ConversionError.message("The background color must have six hex digits, such as #FFFFFF.")
            }
            return CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}
