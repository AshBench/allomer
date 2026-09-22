import Foundation
import ImageIO

public struct SVGTracingOptions: Codable, Equatable, Sendable {
    public enum Preset: String, Codable, CaseIterable, Sendable { case photo, poster, lineArt = "line_art" }
    public enum ColorMode: String, Codable, CaseIterable, Sendable { case color, binary }
    public enum Hierarchy: String, Codable, CaseIterable, Sendable { case stacked, cutout }
    public enum PathMode: String, Codable, CaseIterable, Sendable { case spline, polygon, pixel }

    public var advanced = false
    public var preset: Preset = .photo
    public var colorMode: ColorMode = .color
    public var hierarchy: Hierarchy = .stacked
    public var pathMode: PathMode = .spline
    public var filterSpeckle = 4
    public var colorPrecision = 6
    public var layerDifference = 16
    public var cornerThreshold = 60
    public var lengthThreshold = 4.0
    public var spliceThreshold = 45
    public var maxIterations = 10

    public init() {}
    private enum CodingKeys: String, CodingKey {
        case advanced, preset, colorMode, hierarchy, pathMode, filterSpeckle, colorPrecision,
             layerDifference, cornerThreshold, lengthThreshold, spliceThreshold, maxIterations
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        advanced = try values.decodeIfPresent(Bool.self, forKey: .advanced) ?? false
        preset = try values.decodeIfPresent(Preset.self, forKey: .preset) ?? .photo
        colorMode = try values.decodeIfPresent(ColorMode.self, forKey: .colorMode) ?? .color
        hierarchy = try values.decodeIfPresent(Hierarchy.self, forKey: .hierarchy) ?? .stacked
        pathMode = try values.decodeIfPresent(PathMode.self, forKey: .pathMode) ?? .spline
        filterSpeckle = try values.decodeIfPresent(Int.self, forKey: .filterSpeckle) ?? 4
        colorPrecision = try values.decodeIfPresent(Int.self, forKey: .colorPrecision) ?? 6
        layerDifference = try values.decodeIfPresent(Int.self, forKey: .layerDifference) ?? 16
        cornerThreshold = try values.decodeIfPresent(Int.self, forKey: .cornerThreshold) ?? 60
        lengthThreshold = try values.decodeIfPresent(Double.self, forKey: .lengthThreshold) ?? 4
        spliceThreshold = try values.decodeIfPresent(Int.self, forKey: .spliceThreshold) ?? 45
        maxIterations = try values.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 10
    }

    func arguments() throws -> [String] {
        guard (0...256).contains(filterSpeckle), (1...12).contains(colorPrecision),
              (1...128).contains(layerDifference), (0...180).contains(cornerThreshold),
              lengthThreshold.isFinite, (0...100).contains(lengthThreshold),
              (0...180).contains(spliceThreshold), (1...100).contains(maxIterations) else {
            throw ConversionError.message("A tracing setting is outside its allowed range.")
        }
        return [String(advanced), preset.rawValue, colorMode.rawValue, hierarchy.rawValue, pathMode.rawValue,
                String(filterSpeckle), String(colorPrecision), String(layerDifference), String(cornerThreshold),
                String(lengthThreshold), String(spliceThreshold), String(maxIterations)]
    }
}

enum SVGTracingConverter {
    static func convert(_ input: URL, to output: URL, options: SVGTracingOptions, tool: URL) throws {
        let arguments = try options.arguments()
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= 512 * 1024 * 1024 else {
            throw ConversionError.message("Tracing needs a still image up to 512 MiB.")
        }
        let work = output.deletingLastPathComponent()
        let prepared = work.appendingPathComponent("tracing-\(UUID().uuidString).rgba")
        defer { try? FileManager.default.removeItem(at: prepared) }
        let size = try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let type = CGImageSourceGetType(source) as String? else {
                throw ConversionError.message("The tracing source could not be read.")
            }
            let properties = try ImageConverter.properties(source, 0)
            try ImageConverter.requireStillImage(source, type: type, properties: properties)
            let dimensions = try ImageConverter.dimensions(properties)
            defer { CGImageSourceRemoveCacheAtIndex(source, 0) }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  image.width == dimensions.width, image.height == dimensions.height else {
                throw ConversionError.message("The tracing source could not be decoded completely.")
            }
            let rendered = try ImageConverter.renderContext(image, orientation: properties[kCGImagePropertyOrientation] as? Int ?? 1)
            guard FileManager.default.createFile(atPath: prepared.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ConversionError.message("The private tracing image could not be opened.")
            }
            let file = try FileHandle(forWritingTo: prepared)
            defer { try? file.close() }
            try ImageConverter.writeRGBA(rendered, to: file)
            try file.close()
            return (width: rendered.width, height: rendered.height)
        }
        try Task.checkCancellation()
        try ExternalTool.run(tool, arguments: [prepared.path, work.path, prepared.path, output.path,
            String(size.width), String(size.height)] + arguments, workDirectory: work, workDirectoryByteLimit: 256 * 1024 * 1024)
        guard try FileVersion(output).size <= 64 * 1024 * 1024 else {
            throw ConversionError.message("The traced SVG exceeds 64 MiB.")
        }
        let attributes = try DocumentConverter.validateXML(output, root: "svg", namespace: "http://www.w3.org/2000/svg")
        guard attributes["width"] == String(size.width), attributes["height"] == String(size.height),
              attributes["viewBox"] == "0 0 \(size.width) \(size.height)" else {
            throw ConversionError.message("The traced SVG changed the canvas dimensions.")
        }
        guard try FileVersion(input) == version else { throw ConversionError.message("The source changed during tracing.") }
    }
}
