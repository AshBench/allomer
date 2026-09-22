import Foundation
import ImageIO

/// Page geometry declared by `w:sectPr`, in points. Word records these in twentieths of a point.
struct WordPageGeometry: Hashable {
    var width = 0.0, height = 0.0
    var top = 0.0, right = 0.0, bottom = 0.0, left = 0.0
    var header = 0.0, footer = 0.0

    /// Eight comma-separated point values, the order the renderer reads them in.
    var arguments: String {
        [width, height, top, right, bottom, left, header, footer]
            .map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    var isUsable: Bool {
        [width, height].allSatisfy { $0 >= 36 && $0 <= 14_400 }
            && [top, right, bottom, left, header, footer].allSatisfy { $0 >= 0 && $0 <= 14_400 }
            && width - left - right >= 36 && height - top - bottom >= 36
    }
}

/// Convert a Word document to PDF at its own page size, without passing through HTML.
/// Page geometry is read here; everything inside the page is laid out by the bundled renderer.
enum WordLayoutConverter {
    static func resources(tools: URL) -> URL {
        tools.appendingPathComponent("webguard").resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Word")
    }

    static func convert(_ input: URL, to output: URL, tools: URL) throws {
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= 64 * 1024 * 1024 else {
            throw ConversionError.message("Use a Word document up to 64 MiB.")
        }
        let manager = FileManager.default
        let work = output.deletingLastPathComponent()
        let prepared = work.appendingPathComponent("word-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: prepared, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: prepared) }

        var parts: [String: URL] = [:]
        var names = Set<String>()
        var documentTargets: [String: String] = [:]
        var mainPart: String?
        var targets: Set<String> = []
        var externalTargets: [(type: String, target: String)] = []
        var partFields: Set<String> = []
        var partContent: Set<String> = []
        var partLinks: Set<String> = []
        var document: WordDocumentCheck?
        var mediaBytes = 0
        var pixels: Int64 = 0
        try ArchiveConverter.inspectZIP(input) { name, data in
            guard names.insert(name).inserted else {
                throw ConversionError.message("The document repeats a part name.")
            }
            if name.hasSuffix(".xml") || name.hasSuffix(".rels") {
                let check = WordXMLCheck(document: name == "word/document.xml")
                let parser = XMLParser(data: data)
                parser.shouldProcessNamespaces = true
                parser.shouldResolveExternalEntities = false
                parser.delegate = check
                guard parser.parse(), check.nodes > 0 else {
                    throw ConversionError.message("A Word document part is invalid or exceeds its limits.")
                }
                if name == "word/document.xml" { document = check.document }
                // Judged later, once the relationships say which parts are headers and footers.
                if check.fields { partFields.insert(name) }
                if check.hasContent { partContent.insert(name) }
                // Every part can declare relationships, not just the document. A header's own
                // .rels is where its pictures live, so all of them are resolved and checked.
                if name.hasSuffix(".rels") {
                    let owner = name == "_rels/.rels" ? ""
                        : String(name.replacingOccurrences(of: "/_rels/", with: "/").dropLast(5))
                    for relationship in check.relationships {
                        if relationship.type.hasSuffix("/hyperlink") { partLinks.insert(owner) }
                        if relationship.external {
                            guard externalTargets.count < 100_000 else {
                                throw ConversionError.message("The document declares too many relationships.")
                            }
                            externalTargets.append((relationship.type, relationship.target))
                        } else {
                            guard let resolved = resolve(relationship.target, from: owner), targets.count < 100_000 else {
                                throw ConversionError.message("A Word relationship target is invalid.")
                            }
                            targets.insert(resolved)
                            if name == "word/_rels/document.xml.rels" { documentTargets[relationship.id] = resolved }
                            if name == "_rels/.rels", relationship.type.hasSuffix("/officeDocument") { mainPart = resolved }
                        }
                    }
                }
            } else if name.hasPrefix("word/media/") {
                guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetCount(image) <= 10_000 else {
                    throw ConversionError.message("A document image is unreadable or has too many frames.")
                }
                for index in 0..<CGImageSourceGetCount(image) {
                    guard let properties = CGImageSourceCopyPropertiesAtIndex(image, index, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 100_000, height <= 100_000,
                          Int64(width) * Int64(height) <= 32_000_000 else {
                        throw ConversionError.message("A document image exceeds 32 million pixels or has invalid dimensions.")
                    }
                    pixels += Int64(width) * Int64(height)
                    guard pixels <= 128_000_000 else {
                        throw ConversionError.message("The document images exceed 128 million pixels in total.")
                    }
                }
                mediaBytes += data.count
                guard mediaBytes <= 192 * 1024 * 1024 else {
                    throw ConversionError.message("The document media exceed 192 MiB.")
                }
            }
            let file = prepared.appendingPathComponent(String(names.count))
            try data.write(to: file, options: .withoutOverwriting)
            parts[name] = file
        }
        guard names.isSuperset(of: ["[Content_Types].xml", "_rels/.rels", "word/document.xml"]),
              let document else {
            throw ConversionError.message("The Word document is incomplete.")
        }
        // Everything below is read from word/document.xml. A package that points somewhere else
        // would be scanned for a page setup and for unsupported layout it does not contain.
        guard mainPart == "word/document.xml" else {
            throw ConversionError.message("This document stores its text in an unusual place, which this conversion does not read. Save it again from Word and convert it.")
        }
        guard names.isSuperset(of: targets) else {
            throw ConversionError.message("A part this document refers to is missing from it. Repair the file and convert it again.")
        }
        try refuseUnsupported(document, externalTargets: externalTargets, fields: partFields,
                              content: partContent, links: partLinks, targets: documentTargets)
        guard let geometry = document.geometry, geometry.isUsable else {
            throw ConversionError.message("This document declares no usable page size, so it cannot be laid out. Set a page size in Word and convert it again.")
        }
        try Task.checkCancellation()

        let sanitized = prepared.appendingPathComponent("input.docx")
        try ArchiveConverter.makeZIP(to: sanitized, paths: parts.keys.sorted()) { name, part in
            try manager.moveItem(at: parts[name]!, to: part)
        }
        let printed = work.appendingPathComponent("word-\(UUID().uuidString).pdf")
        defer { try? manager.removeItem(at: printed) }
        let expected = ["header", "footer"].map { kind in
            document.runningReferences.contains { reference in
                reference.kind == kind && documentTargets[reference.id].map(partContent.contains) == true
            } ? "1" : "0"
        }
        try ExternalTool.run(tools.appendingPathComponent("webguard"), arguments: [sanitized.path, work.path,
            resources(tools: tools).path, "docx", sanitized.path, printed.lastPathComponent,
            geometry.arguments + "," + expected.joined(separator: ",")], workDirectory: work)
        try ExternalTool.run(tools.appendingPathComponent("pdfguard"), arguments: [printed.path, work.path,
            "clean", "-g", printed.path, output.lastPathComponent], workDirectory: work)
        let size = try FileVersion(output).size
        let sizes = try PostScriptConverter.pageSizes(output)
        guard size > 0, size <= 512 * 1024 * 1024, !sizes.isEmpty, sizes.count <= 10_000,
              sizes.allSatisfy({ abs($0.width - geometry.width) <= 1 && abs($0.height - geometry.height) <= 1 }),
              try FileVersion(input) == version else {
            throw ConversionError.message("The document output does not match the document's own page size, or the source changed during conversion.")
        }
    }

    /// Refuse what this path cannot place correctly, before anything is rendered.
    private static func refuseUnsupported(_ document: WordDocumentCheck,
                                          externalTargets: [(type: String, target: String)],
                                          fields: Set<String>, content: Set<String>, links: Set<String>,
                                          targets: [String: String]) throws {
        // A header or footer is whatever the section points at, whatever the part is called.
        let running = document.runningReferences.compactMap { reference in
            targets[reference.id].map { (part: $0, kind: reference.kind, type: reference.type) }
        }
        if document.geometries.count > 1 {
            throw ConversionError.message("This document mixes page sizes or margins between sections, which this conversion cannot reproduce. Give every section the same page setup and convert it again.")
        }
        if document.columns {
            throw ConversionError.message("This document uses multiple text columns, which this conversion cannot reproduce.")
        }
        if document.textBoxes {
            throw ConversionError.message("This document uses text boxes, which this conversion cannot place on the page.")
        }
        if document.floatingDrawings {
            throw ConversionError.message("This document uses floating images or shapes, which this conversion cannot place on the page. Set them to be in line with text and convert it again.")
        }
        if document.altChunks {
            throw ConversionError.message("This document embeds another document, which this conversion cannot lay out.")
        }
        if running.contains(where: { fields.contains($0.part) }) {
            throw ConversionError.message("This document uses fields such as page numbers in a header or footer, which this conversion cannot update per page.")
        }
        // The renderer leaves a running block's own hyperlink with an empty target, so the link
        // would print as ordinary text with nothing behind it.
        if running.contains(where: { links.contains($0.part) }) {
            throw ConversionError.message("This document has a link in a header or footer, which this conversion cannot carry into the PDF.")
        }
        if document.titlePage {
            throw ConversionError.message("This document uses a different first-page header or footer, which this conversion cannot reproduce.")
        }
        if running.contains(where: { $0.type != "default" && content.contains($0.part) }) {
            throw ConversionError.message("This document uses a different header or footer on some pages, which this conversion cannot reproduce.")
        }
        // One header and one footer can repeat on every page. Several cannot be told apart per page,
        // and that includes a section that points at an empty one while another points at a filled one.
        for kind in ["header", "footer"] {
            let used = Set(running.filter { $0.kind == kind }.map(\.part))
            if used.count > 1 {
                throw ConversionError.message("This document uses more than one \(kind), which this conversion cannot place per page. Give every section the same \(kind) and convert it again.")
            }
        }
        for relationship in externalTargets {
            if relationship.type.hasSuffix("/image") {
                throw ConversionError.message("This document links an image from another location. Conversion stays offline, so embed the image and convert it again.")
            }
            if relationship.type.hasSuffix("/hyperlink"),
               !["http", "https", "mailto"].contains(URL(string: relationship.target)?.scheme?.lowercased() ?? "") {
                throw ConversionError.message("This document contains a link this conversion does not carry into a PDF.")
            }
        }
    }

    /// Resolve a package-relative relationship target against the part that declared it.
    private static func resolve(_ target: String, from owner: String) -> String? {
        if target.hasPrefix("/") { return nil }
        let base = URL(string: "https://package.invalid/")!.appendingPathComponent(owner)
        guard !target.isEmpty, !target.contains("\0"),
              let url = URL(string: target, relativeTo: base)?.absoluteURL.standardized,
              url.scheme == "https", url.host == "package.invalid", url.query == nil else { return nil }
        return String(url.path.dropFirst())
    }
}

/// What the whole-document scan records. Kept separate so the parser class stays a plain reader.
final class WordDocumentCheck {
    var geometries: Set<WordPageGeometry> = []
    var geometry: WordPageGeometry?
    var columns = false, textBoxes = false, floatingDrawings = false, altChunks = false, titlePage = false
    var runningReferences: [(id: String, kind: String, type: String)] = []
}


private final class WordXMLCheck: NSObject, XMLParserDelegate {
    struct Relationship { let id: String, type: String, target: String, external: Bool }

    let isDocument: Bool
    var nodes = 0
    /// A field's result cannot be recomputed per page, and any of these can carry content that a
    /// running block must keep. Both are recorded for every part; only referenced parts are judged.
    var fields = false, hasContent = false
    var relationships: [Relationship] = []
    let document = WordDocumentCheck()
    private var path: [String] = []
    private var section: WordPageGeometry?
    private var sections = 0, changes = 0, columns = 0
    private var text = ""

    init(document: Bool) { isDocument = document }

    /// Element names lose their prefix when namespaces are processed. Attribute names do not, and
    /// a dictionary has no order, so the WordprocessingML prefix wins and any other is taken in a
    /// fixed order rather than whichever the hash happened to yield.
    private func attribute(_ name: String, _ attributes: [String: String]) -> String? {
        if let exact = attributes[name] ?? attributes["w:" + name] { return exact }
        let matches = attributes.keys.filter { $0.split(separator: ":").last.map(String.init) == name }
        return matches.sorted().first.flatMap { attributes[$0] }
    }

    /// WordprocessingML writes booleans as 1/0, true/false, or on/off, and defaults to true.
    private func flag(_ value: String?) -> Bool {
        guard let value else { return true }
        return !["0", "false", "off"].contains(value.lowercased())
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        nodes += 1
        if nodes > 100_000 || path.count >= 256 { parser.abortParsing(); return }
        // A tracked-change record holds the values a revision replaced. They are not the document.
        if name.hasSuffix("Change") { changes += 1 }
        defer { path.append(name) }
        guard changes == 0 else { return }
        if path == ["Relationships"], name == "Relationship" {
            guard let id = attribute("Id", attributes), let type = attribute("Type", attributes),
                  let target = attribute("Target", attributes),
                  !id.isEmpty, !target.isEmpty, relationships.count < 100_000 else { parser.abortParsing(); return }
            relationships.append(Relationship(id: id, type: type, target: target,
                                              external: attribute("TargetMode", attributes) == "External"))
        }
        if ["fldSimple", "instrText", "fldChar"].contains(name) { fields = true }
        if ["drawing", "pict", "object", "tbl", "pBdr"].contains(name) { hasContent = true }
        if isDocument {
            switch name {
            // Word's own defaults for a section that leaves them out: US Letter, one-inch margins.
            case "sectPr":
                sections += 1
                if sections == 1 {
                    section = WordPageGeometry(width: 612, height: 792, top: 72, right: 72,
                                               bottom: 72, left: 72, header: 36, footer: 36)
                }
            case "pgSz" where sections == 1:
                section?.width = points(attribute("w", attributes)) ?? 612
                section?.height = points(attribute("h", attributes)) ?? 792
            case "pgMar" where sections == 1:
                section?.top = points(attribute("top", attributes)) ?? 72
                section?.right = points(attribute("right", attributes)) ?? 72
                section?.bottom = points(attribute("bottom", attributes)) ?? 72
                section?.left = points(attribute("left", attributes)) ?? 72
                section?.header = points(attribute("header", attributes)) ?? 36
                section?.footer = points(attribute("footer", attributes)) ?? 36
                // Word adds the binding gutter to the inside edge, which is the left one here.
                section?.left += max(0, points(attribute("gutter", attributes)) ?? 0)
            case "cols" where sections == 1:
                columns = 0
                if (Int(attribute("num", attributes) ?? "1") ?? 1) > 1 { document.columns = true }
            case "col" where path.last == "cols":
                columns += 1
                if columns > 1 { document.columns = true }
            case "titlePg" where sections == 1: document.titlePage = flag(attribute("val", attributes))
            case "headerReference", "footerReference":
                if let id = attribute("id", attributes), document.runningReferences.count < 10_000 {
                    document.runningReferences.append((id, name == "headerReference" ? "header" : "footer",
                                                       attribute("type", attributes) ?? "default"))
                }
            case "txbxContent", "textbox": document.textBoxes = true
            case "anchor": if namespaceURI?.hasSuffix("/wordprocessingDrawing") == true { document.floatingDrawings = true }
            case "altChunk": document.altChunks = true
            default: break
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard changes == 0, !hasContent, path.last == "t" else { return }
        text += string
        if text.count > 4096 || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasContent = true }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if !path.isEmpty { path.removeLast() }
        if name.hasSuffix("Change") { changes = max(0, changes - 1); return }
        guard changes == 0, isDocument, name == "sectPr" else { return }
        sections -= 1
        guard sections == 0, let section else { return }
        document.geometries.insert(section)
        document.geometry = section
        self.section = nil
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?, systemID: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundElementDeclarationWithName: String, model: String) { parser.abortParsing() }

    /// A missing measurement takes the caller's default. One that is present but unreadable does not.
    private func points(_ value: String?) -> Double? {
        guard let value else { return nil }
        guard let twips = Double(value), twips.isFinite else { return 0 }
        return twips / 20
    }
}
