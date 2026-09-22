import Foundation

public struct DocumentOptions: Codable, Equatable, Sendable {
    public enum MarkdownFlavor: String, Codable, CaseIterable, Sendable {
        case gfm, commonmark
        case commonmarkExtended = "commonmark_x", pandoc = "markdown", multiMarkdown = "markdown_mmd"
        case phpMarkdownExtra = "markdown_phpextra", strict = "markdown_strict"

        public var title: String {
            switch self {
            case .gfm: "GitHub"
            case .commonmark: "CommonMark"
            case .commonmarkExtended: "CommonMark with extensions"
            case .pandoc: "Pandoc Markdown"
            case .multiMarkdown: "MultiMarkdown"
            case .phpMarkdownExtra: "PHP Markdown Extra"
            case .strict: "Original Markdown"
            }
        }
    }

    public var markdownFlavor = MarkdownFlavor.gfm
    public var standalone = true
    public var syntaxHighlighting = true
    public var pdfPageSize = "a4"
    public var pdfTemplate = "github"
    public init() {}

    private enum CodingKeys: String, CodingKey { case markdownFlavor, standalone, syntaxHighlighting, pdfPageSize, pdfTemplate }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        markdownFlavor = try values.decodeIfPresent(MarkdownFlavor.self, forKey: .markdownFlavor) ?? .gfm
        standalone = try values.decodeIfPresent(Bool.self, forKey: .standalone) ?? true
        syntaxHighlighting = try values.decodeIfPresent(Bool.self, forKey: .syntaxHighlighting) ?? true
        pdfPageSize = try values.decodeIfPresent(String.self, forKey: .pdfPageSize) ?? "a4"
        pdfTemplate = try values.decodeIfPresent(String.self, forKey: .pdfTemplate) ?? "github"
    }
}

enum DocumentConverter {
    static let nativeRoutes: [String: Set<String>] = [
        "txt": ["rtf", "doc"], "rtf": ["doc"], "doc": ["html", "rtf", "txt"]
    ]
    static let nativeOutputs: Set<String> = ["html", "rtf", "txt", "doc"]
    static let inputFormats: Set<String> = [
        "csv", "docx", "epub", "html", "ipynb", "latex", "man", "markdown",
        "mediawiki", "odt", "opml", "org", "rst", "rtf", "tsv"
    ]
    static let outputFormats: Set<String> = [
        "asciidoc", "docx", "epub", "html", "ipynb", "latex", "man", "markdown",
        "mediawiki", "odt", "opml", "org", "rst", "rtf", "txt", "typst"
    ]

    static func convertNative(_ input: URL, to output: URL, from source: FileFormat,
                              to target: FileFormat, tool: URL) throws {
        let version = try FileVersion(input)
        guard nativeRoutes[source.id]?.contains(target.id) == true, version.size > 0, version.size <= 64 * 1024 * 1024 else {
            throw ConversionError.message("The native document route needs a supported input up to 64 MiB.")
        }
        let work = output.deletingLastPathComponent()
        try ExternalTool.run(tool, arguments: [input.path, work.path, "document", input.path, output.lastPathComponent,
            source.id, target.id], workDirectory: work, workDirectoryByteLimit: 512 * 1024 * 1024)
        guard try FileVersion(output).size > 0, try FileVersion(input) == version else {
            throw ConversionError.message("The native document is empty or its source changed.")
        }
    }

    static func makePDF(_ input: URL, to output: URL, from source: FileFormat, tools: URL,
                        options: DocumentOptions, resources: URL, catalog: FormatCatalog) throws {
        let version = try FileVersion(input)
        guard ["html", "markdown"].contains(source.id), version.size > 0, version.size <= 64 * 1024 * 1024,
              ["a4", "letter"].contains(options.pdfPageSize),
              source.id != "markdown" || ["github", "minimal"].contains(options.pdfTemplate) else {
            throw ConversionError.message("Use HTML or Markdown up to 64 MiB with a valid PDF page size and template.")
        }
        let work = output.deletingLastPathComponent()
        let printed = work.appendingPathComponent("printed-\(UUID().uuidString).pdf")
        var html = input
        defer {
            if html != input { try? FileManager.default.removeItem(at: html) }
            try? FileManager.default.removeItem(at: printed)
        }
        if source.id == "markdown" {
            guard let htmlFormat = catalog.format(forExtension: "html") else {
                throw ConversionError.message("The HTML format is missing from the catalog.")
            }
            html = work.appendingPathComponent("document-\(UUID().uuidString).html")
            var prepared = options
            prepared.standalone = true
            try convert(input, to: html, from: source, to: htmlFormat, tool: tools.appendingPathComponent("carta"),
                options: prepared, resourceDirectory: resources)
        }
        try ExternalTool.run(tools.appendingPathComponent("webguard"), arguments: [html.path, work.path, resources.path,
            "html", html.path, printed.lastPathComponent, "pdf", options.pdfPageSize,
            source.id == "markdown" ? options.pdfTemplate : "none"], workDirectory: work)
        // Quartz can leave unused objects marked active. Rebuild the index without changing page content.
        try ExternalTool.run(tools.appendingPathComponent("pdfguard"), arguments: [printed.path, work.path,
            "clean", "-g", printed.path, output.lastPathComponent], workDirectory: work)
        let size = try FileVersion(output).size
        guard size > 0, size <= 512 * 1024 * 1024 else { throw ConversionError.message("The printed PDF is empty or exceeds 512 MiB.") }
        let pages = try PostScriptConverter.pageSizes(output)
        let paper = options.pdfPageSize == "a4" ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 612, height: 792)
        guard pages.allSatisfy({ abs($0.width - paper.width) <= 1 && abs($0.height - paper.height) <= 1 }) else {
            throw ConversionError.message("The printed PDF has an unexpected page size.")
        }
        guard try FileVersion(input) == version else { throw ConversionError.message("The document changed during conversion.") }
    }

    static func convert(_ input: URL, to output: URL, from source: FileFormat,
                        to target: FileFormat, tool: URL,
                        options: DocumentOptions, resourceDirectory: URL? = nil) throws {
        guard inputFormats.contains(source.id), outputFormats.contains(target.id) else {
            throw ConversionError.message("This document conversion is not implemented.")
        }
        func toolFormat(_ format: FileFormat) -> String {
            switch format.id {
            case "markdown": return options.markdownFlavor.rawValue
            case "txt": return "plain"
            default: return format.id
            }
        }
        var arguments = ["--sandbox", "-f", toolFormat(source), "-t", toolFormat(target),
                         "-o", output.path]
        if options.standalone { arguments.append("--standalone") }
        if !options.syntaxHighlighting { arguments.append("--no-highlight") }
        if target.id == "html", ["docx", "odt", "epub", "rtf"].contains(source.id) {
            arguments.append("--embed-resources")
        }
        arguments += ["--", input.path]
        try ExternalTool.run(tool, arguments: arguments, workDirectory: output.deletingLastPathComponent(),
                             currentDirectory: resourceDirectory ?? input.deletingLastPathComponent())
        let attributes = try output.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 0 else {
            throw ConversionError.message("The document converter produced no output.")
        }
        try validate(output, format: target.id)
    }

    static func validate(_ output: URL, format: String) throws {
        let work = output.deletingLastPathComponent()
        let containers: [String: (entry: String, root: String, namespace: String)] = [
            "docx": ("word/document.xml", "document", "http://schemas.openxmlformats.org/wordprocessingml/2006/main"),
            "odt": ("content.xml", "document-content", "urn:oasis:names:tc:opendocument:xmlns:office:1.0"),
            "epub": ("META-INF/container.xml", "container", "urn:oasis:names:tc:opendocument:xmlns:container")
        ]
        if let container = containers[format] {
            let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
            try ExternalTool.run(unzip, arguments: ["-tqq", output.path], workDirectory: work)
            let xml = work.appendingPathComponent("validation-\(UUID().uuidString).xml")
            defer { try? FileManager.default.removeItem(at: xml) }
            try ExternalTool.run(unzip, arguments: ["-p", output.path, container.entry], workDirectory: work,
                                 outputFile: xml, outputLimit: 512 * 1024 * 1024)
            try validateXML(xml, root: container.root, namespace: container.namespace)
        } else if format == "opml" {
            try validateXML(output, root: "opml", namespace: "")
        } else {
            guard let text = String(data: try Data(contentsOf: output, options: .mappedIfSafe), encoding: .utf8),
                  !text.isEmpty, !text.contains("\0") else {
                throw ConversionError.message("The document output is not valid UTF-8 text.")
            }
            if format == "ipynb" {
                guard let notebook = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      notebook["cells"] is [Any], notebook["nbformat"] as? Int == 4 else {
                    throw ConversionError.message("The output is not a valid notebook.")
                }
            } else if format == "rtf", !text.hasPrefix("{\\rtf") {
                throw ConversionError.message("The output is not an RTF document.")
            } else if format == "html", !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                throw ConversionError.message("The output is not an HTML document.")
            }
        }
    }

    @discardableResult
    static func validateXML(_ url: URL, root: String, namespace: String) throws -> [String: String] {
        guard let parser = XMLParser(contentsOf: url) else {
            throw ConversionError.message("The document XML could not be read.")
        }
        let check = DocumentXMLCheck()
        parser.delegate = check
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), check.root == root, check.namespace == namespace else {
            throw ConversionError.message("The document container has invalid XML content.")
        }
        return check.attributes
    }
}

private final class DocumentXMLCheck: NSObject, XMLParserDelegate {
    var root: String?
    var namespace = ""
    var attributes: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if root == nil { root = elementName; namespace = namespaceURI ?? ""; attributes = attributeDict }
    }
}
