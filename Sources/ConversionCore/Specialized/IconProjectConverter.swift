import Foundation
import ImageIO

enum IconProjectConverter {
    private struct Document: Decodable { let groups: [Node] }
    private struct Position: Decodable {
        let scale: Double?
        let translationInPoints: [Double]?
        enum CodingKeys: String, CodingKey { case scale, translationInPoints = "translation-in-points" }
    }
    private struct Opacity: Decodable {
        let number: Double?
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() || (try? value.decode(String.self)) == "automatic" { number = nil; return }
            let decoded = try value.decode(Double.self)
            guard decoded.isFinite, (0...1).contains(decoded) else {
                throw ConversionError.message("Icon layer opacity must be between 0 and 1.")
            }
            number = decoded
        }
    }
    private struct Specialization: Decodable {
        let appearance: String?
        let value: Opacity?
    }
    private struct Node: Decodable {
        let layers: [Node]?
        let imageName: String?
        let hidden: Bool?
        let position: Position?
        let opacity: Opacity?
        let opacitySpecializations: [Specialization]?
        enum CodingKeys: String, CodingKey {
            case layers, hidden, position, opacity
            case imageName = "image-name", opacitySpecializations = "opacity-specializations"
        }
        var defaultOpacity: Double {
            opacitySpecializations?.last(where: {
                $0.appearance == nil || ["default", "light"].contains($0.appearance!.lowercased())
            })?.value?.number ?? opacity?.number ?? 1
        }
    }

    static func matches(_ source: URL) -> Bool {
        guard (try? FileVersion(source, allowingDirectories: true).isDirectory) == true,
              let manifest = try? FileVersion(source.appendingPathComponent("icon.json")) else { return false }
        return manifest.size > 0 && manifest.size <= 1_048_576
    }

    static func convert(_ input: URL, to output: URL, engine: ConversionEngine) throws {
        let version = try SourceVersion(input)
        let catalog = engine.catalog
        guard version.isPackage, let tools = engine.toolsDirectory,
              let png = catalog.format(forExtension: "png"), let svg = catalog.format(forExtension: "svg") else {
            throw ConversionError.message("The source is not an Icon Composer package.")
        }
        let manager = FileManager.default
        let work = output.deletingLastPathComponent().appendingPathComponent("icon-\(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: work) }
        let snapshot = work.appendingPathComponent("source.icon")
        try cloneSource(input, to: snapshot)
        guard try SourceVersion(input) == version else { throw ConversionError.message("The icon project changed during preparation.") }
        let copied = try SourceVersion(snapshot)
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: snapshot.appendingPathComponent("icon.json")))
        guard document.groups.count <= 128 else { throw ConversionError.message("The icon project has too many groups.") }
        let composition = work.appendingPathComponent("artwork.svg")
        guard manager.createFile(atPath: composition.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ConversionError.message("The icon artwork could not be prepared.")
        }
        let file = try FileHandle(forWritingTo: composition)
        defer { try? file.close() }
        var bytesWritten = 0
        func write(_ text: String) throws {
            let data = Data(text.utf8)
            guard data.count <= 64 * 1024 * 1024 - bytesWritten else {
                throw ConversionError.message("The prepared icon artwork exceeds 64 MiB.")
            }
            try file.write(contentsOf: data)
            bytesWritten += data.count
        }
        var assets: [String: (id: Int, width: Int, height: Int)] = [:]
        var imageOptions = ImageOptions()
        imageOptions.preserveMetadata = false
        imageOptions.convertToSRGB = true
        func asset(_ name: String) throws -> (id: Int, width: Int, height: Int) {
            if let ready = assets[name] { return ready }
            guard !name.isEmpty, !name.contains("\\"), !name.contains("\0"),
                  name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  let member = copied.members["Assets/" + name], !member.isDirectory else {
                throw ConversionError.message("An icon layer names a missing asset or an unsafe path.")
            }
            let source = snapshot.appendingPathComponent("Assets").appendingPathComponent(name)
            let prepared = work.appendingPathComponent("asset-\(assets.count).png")
            if !["svg", "svgz"].contains(catalog.format(for: source)?.id ?? "") {
                guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let type = CGImageSourceGetType(image),
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] else {
                    throw ConversionError.message("An icon asset is not a readable still image.")
                }
                if !IconImageConverter.inputTypes.contains(type as String) {
                    try ImageConverter.requireStillImage(image, type: type as String, properties: properties)
                }
            }
            try engine.convert(source, to: prepared, settings: .init(imageOptions: imageOptions),
                resourceDirectory: snapshot)
            let preparedVersion = try FileVersion(prepared)
            guard preparedVersion.size <= 48 * 1024 * 1024,
                  let image = CGImageSourceCreateWithURL(prepared as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 32_000_000 / height else {
                throw ConversionError.message("An icon asset exceeds the prepared image limits.")
            }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            guard (1...8).contains(orientation) else { throw ConversionError.message("An icon asset has an invalid orientation.") }
            let result = (id: assets.count, width: orientation >= 5 ? height : width, height: orientation >= 5 ? width : height)
            let data = try Data(contentsOf: prepared)
            guard data.count * 4 / 3 + 1024 <= 64 * 1024 * 1024 - bytesWritten else {
                throw ConversionError.message("The prepared icon artwork exceeds 64 MiB.")
            }
            try write("<defs><image id=\"asset\(result.id)\" width=\"\(result.width)\" height=\"\(result.height)\" href=\"data:image/png;base64,\(data.base64EncodedString())\"/></defs>")
            try manager.removeItem(at: prepared)
            assets[name] = result
            return result
        }
        var count = 0
        func draw(_ node: Node, depth: Int) throws {
            try Task.checkCancellation()
            count += 1
            guard count <= 1024, depth <= 16 else { throw ConversionError.message("The icon project has too many layers.") }
            if node.hidden == true || node.defaultOpacity == 0 { return }
            let scale = node.position?.scale ?? 1
            let translation = node.position?.translationInPoints ?? [0, 0]
            guard translation.count == 2, scale.isFinite, abs(scale) <= 10_000,
                  translation.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else {
                throw ConversionError.message("An icon layer has an invalid position.")
            }
            try write("<g opacity=\"\(node.defaultOpacity)\" transform=\"translate(\(512 + translation[0]) \(512 + translation[1])) scale(\(scale)) translate(-512 -512)\">")
            if let layers = node.layers {
                guard node.imageName == nil else { throw ConversionError.message("An icon group cannot also name an image.") }
                for layer in layers.reversed() { try draw(layer, depth: depth + 1) }
            } else if let name = node.imageName {
                let image = try asset(name)
                try write("<use href=\"#asset\(image.id)\" x=\"\((1024 - Double(image.width)) / 2)\" y=\"\((1024 - Double(image.height)) / 2)\"/>")
            }
            try write("</g>")
        }
        try write("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">")
        for group in document.groups.reversed() { try draw(group, depth: 0) }
        try write("</svg>")
        try file.close()
        try SVGConverter.convert(composition, to: output, from: svg, format: png, options: imageOptions,
            tool: tools.appendingPathComponent("webguard"), resources: work, catalog: catalog)
        guard try SourceVersion(input) == version else { throw ConversionError.message("The icon project changed during conversion.") }
    }
}
