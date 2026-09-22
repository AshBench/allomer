import Foundation
import ImageIO

enum PresentationConverter {
    static func resources(tools: URL) -> URL {
        tools.appendingPathComponent("webguard").resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Presentation")
    }

    static func convert(_ input: URL, to output: URL, tools: URL) throws {
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= 64 * 1024 * 1024 else {
            throw ConversionError.message("Use a PowerPoint presentation up to 64 MiB.")
        }
        let manager = FileManager.default
        let work = output.deletingLastPathComponent()
        let prepared = work.appendingPathComponent("presentation-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: prepared, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: prepared) }
        var parts = Set<String>()
        var documentParts: [String: URL] = [:]
        var media: [String: String] = [:]
        var mediaBytes = 0
        var pages = 0
        var targets = Set<String>()
        var pixels: Int64 = 0
        try ArchiveConverter.inspectZIP(input) { name, data in
            parts.insert(name)
            if name.hasSuffix(".xml") || name.hasSuffix(".rels") || name.hasSuffix(".svg") {
                let check = PresentationXMLCheck(presentation: name == "ppt/presentation.xml")
                let parser = XMLParser(data: data)
                parser.shouldProcessNamespaces = true
                parser.shouldResolveExternalEntities = false
                parser.delegate = check
                guard parser.parse(), check.nodes > 0 else {
                    throw ConversionError.message("A presentation XML part is invalid or exceeds its limits.")
                }
                if name == "ppt/presentation.xml" { pages = check.slides }
                if name.hasSuffix(".rels") {
                    let owner = name == "_rels/.rels" ? "" : name.replacingOccurrences(of: "/_rels/", with: "/").dropLast(5).description
                    let base = URL(string: "https://package.invalid/")!.appendingPathComponent(owner)
                    for target in check.targets {
                        guard let url = URL(string: target, relativeTo: base)?.absoluteURL.standardized,
                              url.scheme == "https", url.host == "package.invalid", url.query == nil,
                              !url.path.contains("\0"), targets.count < 100_000 else {
                            throw ConversionError.message("A presentation relationship target is invalid.")
                        }
                        targets.insert(String(url.path.dropFirst()))
                    }
                }
            } else if name.hasPrefix("ppt/media/"),
                      let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
                guard CGImageSourceGetCount(image) <= 10_000 else {
                    throw ConversionError.message("A presentation image has too many frames.")
                }
                for index in 0..<CGImageSourceGetCount(image) {
                    guard let properties = CGImageSourceCopyPropertiesAtIndex(image, index, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 100_000, height <= 100_000,
                          Int64(width) * Int64(height) <= 32_000_000 else {
                        throw ConversionError.message("A presentation image exceeds 32 million pixels or has invalid dimensions.")
                    }
                    pixels += Int64(width) * Int64(height)
                    guard pixels <= 128_000_000 else {
                        throw ConversionError.message("The presentation images exceed 128 million pixels in total.")
                    }
                }
            }
            // Use generated names on disk. Archive paths remain keys in the private manifest.
            let label = String(parts.count)
            let file = prepared.appendingPathComponent(label)
            try data.write(to: file, options: .withoutOverwriting)
            if name.hasPrefix("ppt/media/") {
                mediaBytes += data.count
                guard mediaBytes <= 192 * 1024 * 1024 else {
                    throw ConversionError.message("The presentation media exceed 192 MiB.")
                }
                media[name.precomposedStringWithCanonicalMapping] = label
            } else { documentParts[name] = file }
        }
        guard parts.isSuperset(of: targets),
              parts.isSuperset(of: ["[Content_Types].xml", "_rels/.rels", "ppt/presentation.xml", "ppt/_rels/presentation.xml.rels"]),
              (1...10_000).contains(pages) else {
            throw ConversionError.message("The presentation is incomplete, empty, or exceeds 10,000 slides.")
        }
        let document = prepared.appendingPathComponent("input.pptx")
        try ArchiveConverter.makeZIP(to: document, paths: documentParts.keys.sorted()) { name, part in
            try manager.moveItem(at: documentParts[name]!, to: part)
        }
        try JSONSerialization.data(withJSONObject: media, options: .sortedKeys)
            .write(to: prepared.appendingPathComponent("media.json"), options: .withoutOverwriting)
        let printed = work.appendingPathComponent("slides-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: printed) }
        try ExternalTool.run(tools.appendingPathComponent("webguard"), arguments: [document.path, work.path,
            resources(tools: tools).path, "pptx", document.path, printed.lastPathComponent, String(pages)], workDirectory: work)
        try ExternalTool.run(tools.appendingPathComponent("pdfguard"), arguments: [printed.path, work.path,
            "clean", "-g", printed.path, output.lastPathComponent], workDirectory: work)
        let size = try FileVersion(output).size
        guard size > 0, size <= 512 * 1024 * 1024,
              try PostScriptConverter.pageSizes(output).count == pages,
              try FileVersion(input) == version else {
            throw ConversionError.message("The presentation output is invalid, or the source changed during conversion.")
        }
    }
}

private final class PresentationXMLCheck: NSObject, XMLParserDelegate {
    let presentation: Bool
    var nodes = 0, slides = 0
    var targets: [String] = []
    private var path: [String] = []
    init(presentation: Bool) { self.presentation = presentation }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        nodes += 1
        if nodes > 100_000 || path.count >= 256 { parser.abortParsing(); return }
        if presentation, path.isEmpty,
           name != "presentation" || !["http://schemas.openxmlformats.org/presentationml/2006/main",
               "http://purl.oclc.org/ooxml/presentationml/main"].contains(namespaceURI ?? "") {
            parser.abortParsing(); return
        }
        if presentation, path == ["presentation", "sldIdLst"], name == "sldId" { slides += 1 }
        if path == ["Relationships"], name == "Relationship", attributes["TargetMode"] != "External" {
            guard let target = attributes["Target"], !target.isEmpty else { parser.abortParsing(); return }
            targets.append(target)
        }
        path.append(name)
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) {
        if !path.isEmpty { path.removeLast() }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?, systemID: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundElementDeclarationWithName: String, model: String) { parser.abortParsing() }
}
