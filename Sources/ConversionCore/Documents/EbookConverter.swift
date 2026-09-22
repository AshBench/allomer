import Foundation

enum EbookConverter {
    static let inputFormats: Set<String> = ["mobi", "azw", "azw3"]

    static func convert(_ input: URL, to output: URL, tool: URL) throws {
        try checkInput(input)
        let work = output.deletingLastPathComponent()
        let folder = work.appendingPathComponent("ebook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("book.mobi")
        try FileManager.default.copyItem(at: input, to: copy)
        try ExternalTool.run(tool, arguments: ["-e", "-o", folder.path, "--", copy.path],
                             workDirectory: folder, captureOutput: true)
        let raw = folder.appendingPathComponent("book.epub")
        guard FileManager.default.fileExists(atPath: raw.path) else {
            throw ConversionError.message("This ebook could not be exported as EPUB. Print Replica books are not supported.")
        }
        try normalize(raw, to: output)
    }

    static func checkInput(_ source: URL) throws {
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard (94...64 * 1024 * 1024).contains(size) else {
            throw ConversionError.message("Ebook inputs must be between 94 bytes and 64 MiB.")
        }
        try file.seek(toOffset: 0)
        let header = try file.read(upToCount: 78) ?? Data()
        guard header.count == 78, [Data("BOOKMOBI".utf8), Data("TEXtREAd".utf8)].contains(header.subdata(in: 60..<68)) else {
            throw ConversionError.message("The file is not a supported MOBI ebook.")
        }
        func number(_ data: Data, _ offset: Int, _ length: Int) -> UInt64 {
            data[offset..<(offset + length)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        let count = Int(number(header, 76, 2))
        guard count >= 2, UInt64(78 + count * 8) < size else {
            throw ConversionError.message("The ebook record table is invalid.")
        }
        let records = try file.read(upToCount: count * 8) ?? Data()
        guard records.count == count * 8 else { throw ConversionError.message("The ebook record table is truncated.") }
        let offsets = (0..<count).map { number(records, $0 * 8, 4) } + [size]
        var previousBoundary = false
        for index in 0..<count {
            try Task.checkCancellation()
            guard offsets[index] >= UInt64(78 + count * 8), offsets[index] < offsets[index + 1] else {
                throw ConversionError.message("The ebook record offsets are invalid.")
            }
            try file.seek(toOffset: offsets[index])
            let length = offsets[index + 1] - offsets[index]
            let bytes = try file.read(upToCount: Int(min(40, length))) ?? Data()
            let mobiHeader = bytes.count >= 20 && bytes.subdata(in: 16..<20) == Data("MOBI".utf8)
            if index == 0 || (previousBoundary && mobiHeader) {
                guard bytes.count >= 16, [1, 2, 17480].contains(number(bytes, 0, 2)),
                      number(bytes, 4, 4) <= 256 * 1024 * 1024,
                      number(bytes, 8, 2) * max(8192, number(bytes, 10, 2)) <= 256 * 1024 * 1024,
                      number(bytes, 8, 2) < UInt64(count - index) else {
                    throw ConversionError.message("The ebook text header is invalid or exceeds 256 MiB.")
                }
                guard number(bytes, 12, 2) == 0 else {
                    throw ConversionError.message("Encrypted ebooks are not supported.")
                }
            }
            previousBoundary = bytes == Data("BOUNDARY".utf8)
        }
    }

    static func normalize(_ source: URL, to output: URL) throws {
        let entries = try ArchiveConverter.manifest(source, format: "zip")
        let names = Set(entries.map(\.path))
        guard entries.first?.path == "mimetype", entries.count <= 10_000,
              entries.reduce(Int64(0), { $0 + $1.size }) <= 256 * 1024 * 1024 else {
            throw ConversionError.message("The ebook archive structure or size is invalid.")
        }
        let metadata: Set<String> = ["mimetype", "META-INF/container.xml", "OEBPS/content.opf"]
        guard metadata.isSubset(of: names) else { throw ConversionError.message("The ebook package is incomplete.") }
        let text = Set(names.filter { $0.hasSuffix(".html") || $0.hasSuffix(".xhtml") || $0.hasSuffix(".ncx") })
        try ArchiveConverter.rewriteZIP(source, to: output, replacing: metadata.union(text)) { path, data in
            try autoreleasepool {
                if path == "mimetype" {
                    guard data == Data("application/epub+zip".utf8) else { throw invalidMarkup() }
                    return data
                }
                if path.hasSuffix(".html") || path.hasSuffix(".xhtml") { return try xhtml(data) }
                let document = try xml(data)
                if path == "META-INF/container.xml" {
                    guard document.rootElement()?.localName == "container",
                          document.rootElement()?.uri == "urn:oasis:names:tc:opendocument:xmlns:container",
                          try document.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").map(\.stringValue) == ["OEBPS/content.opf"] else {
                        throw invalidMarkup()
                    }
                } else if path == "OEBPS/content.opf" {
                    guard document.rootElement()?.localName == "package", document.rootElement()?.uri == "http://www.idpf.org/2007/opf" else {
                        throw invalidMarkup()
                    }
                    var identifiers = Set<String>()
                    for node in try document.nodes(forXPath: "/*[local-name()='package']/*[local-name()='manifest']/*[local-name()='item']") {
                        guard let element = node as? XMLElement, let id = element.attribute(forName: "id")?.stringValue,
                              identifiers.insert(id).inserted, let path = element.attribute(forName: "href")?.stringValue,
                              names.contains("OEBPS/" + path) else { throw invalidMarkup() }
                    }
                    let spine = try document.nodes(forXPath: "/*[local-name()='package']/*[local-name()='spine']/*[local-name()='itemref']/@idref")
                    guard !spine.isEmpty, spine.allSatisfy({ $0.stringValue.map(identifiers.contains) == true }) else { throw invalidMarkup() }
                } else if path.hasSuffix(".ncx"), document.rootElement()?.localName != "ncx" { throw invalidMarkup() }
                return data
            }
        }
        try EPUBZipNormalizer.removeMimetypeExtraField(at: output)
    }

    private static func xml(_ data: Data) throws -> XMLDocument {
        guard !data.contains(Data("<!DOCTYPE".utf8)), !data.contains(Data("<!ENTITY".utf8)) else { throw invalidMarkup() }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw invalidMarkup() }
        return try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }

    private static func xhtml(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { throw invalidMarkup() }
        let document = try XMLDocument(xmlString: text, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement(), root.localName == "html" else { throw invalidMarkup() }
        let content = root.stringValue
        document.documentContentKind = .xml
        document.dtd = nil
        document.characterEncoding = "UTF-8"
        root.addNamespace(XMLNode.namespace(withName: "", stringValue: "http://www.w3.org/1999/xhtml") as! XMLNode)
        for node in try document.nodes(forXPath: "//*[local-name()='meta']/@charset") { node.stringValue = "utf-8" }
        let output = document.xmlData
        // The stream reader preserves whitespace that XMLDocument's XHTML reader can discard.
        let check = EbookTextCheck()
        let parser = XMLParser(data: output)
        parser.delegate = check
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), check.namespace == "http://www.w3.org/1999/xhtml", check.text == content else {
            throw invalidMarkup()
        }
        return output
    }

    private static func invalidMarkup() -> ConversionError { .message("The ebook contains invalid or unsupported markup or package references.") }
}

private final class EbookTextCheck: NSObject, XMLParserDelegate {
    var namespace: String?
    var text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if namespace == nil { namespace = namespaceURI ?? "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }
}
