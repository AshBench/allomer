import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

public struct PDFOptions: Codable, Equatable, Sendable {
    public var page = 1
    public var resolution = 300
    // Slides keep the two-times page scale that the slide geometry was measured against.
    public var slideResolution = 144
    public var pages = "all"
    public var imageOCR = false
    public var recognizeScans = false
    public var ocrLanguage = "auto"
    public static let ocrLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }()
    public init() {}

    private enum CodingKeys: String, CodingKey { case page, resolution, slideResolution, pages, imageOCR, recognizeScans, ocrLanguage }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        page = try values.decodeIfPresent(Int.self, forKey: .page) ?? 1
        resolution = try values.decodeIfPresent(Int.self, forKey: .resolution) ?? 300
        slideResolution = try values.decodeIfPresent(Int.self, forKey: .slideResolution) ?? 144
        pages = try values.decodeIfPresent(String.self, forKey: .pages) ?? "all"
        imageOCR = try values.decodeIfPresent(Bool.self, forKey: .imageOCR) ?? false
        recognizeScans = try values.decodeIfPresent(Bool.self, forKey: .recognizeScans) ?? false
        ocrLanguage = try values.decodeIfPresent(String.self, forKey: .ocrLanguage) ?? "auto"
    }

    func selectedPages(count: Int) throws -> [Int] {
        let value = pages.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...10_000).contains(count), value.utf8.count <= 4096 else {
            throw ConversionError.message("The PDF page selection is too large.")
        }
        if value == "all" { return Array(1...count) }
        var result: [Int] = []
        var seen: Set<Int> = []
        for part in value.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = part.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(ends.count), ends.allSatisfy({ !$0.isEmpty && $0.first != "0" && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                  let start = Int(ends[0]), let end = Int(ends.last!),
                  start >= 1, start <= end, end <= count else {
                throw ConversionError.message("Use all, a page number, or ranges such as 1-3,5. Every page must exist.")
            }
            for page in start...end where seen.insert(page).inserted { result.append(page) }
        }
        guard !result.isEmpty else { throw ConversionError.message("Select at least one PDF page.") }
        return result
    }
}

enum PDFConverter {
    static let outputs: Set<String> = ["png", "svg", "docx", "html", "pptx"]

    static func convert(_ input: URL, to output: URL, format: String, tool: URL, options: PDFOptions) throws {
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= 512 * 1024 * 1024, outputs.contains(format) else {
            throw ConversionError.message("The PDF input or output format is invalid. Use an input up to 512 MiB.")
        }
        let sizes = try PostScriptConverter.pageSizes(input)
        if format == "pptx" {
            try PresentationWriter.convert(input, to: output, sizes: sizes, tool: tool, options: options)
            guard try FileVersion(input) == version else { throw ConversionError.message("The PDF changed during conversion.") }
            return
        }
        let work = output.deletingLastPathComponent()
        var reading = input
        defer { if reading != input { try? FileManager.default.removeItem(at: reading) } }
        let pages: [Int]
        var arguments: [String]
        if format == "docx" || format == "html" {
            pages = try options.selectedPages(count: sizes.count)
            if options.recognizeScans {
                reading = try OCRConverter.preparePDF(input, pages: pages, work: work, tools: tool.deletingLastPathComponent(), language: options.ocrLanguage)
            }
            arguments = format == "docx" ? ["convert", "-F", "docx", "-o", output.lastPathComponent]
                : ["draw", "-q", "-a", "-L", "-m", "268435456", "-F", "xhtml", "-O",
                   "preserve-images,segment,table-hunt", "-o", output.lastPathComponent]
        } else {
            guard (1...sizes.count).contains(options.page) else { throw ConversionError.message("The selected page is outside the PDF.") }
            pages = [options.page]
            arguments = ["draw", "-q", "-a", "-L", "-m", "268435456", "-F", format, "-o", output.lastPathComponent]
            if format == "png" {
                try renderPNG(input, to: output, page: options.page, size: sizes[options.page - 1],
                    resolution: options.resolution, opaque: false, tool: tool)
                guard try FileVersion(input) == version else { throw ConversionError.message("The PDF changed during conversion.") }
                return
            }
        }
        arguments += [reading.path, pages.map(String.init).joined(separator: ",")]
        try ExternalTool.run(tool, arguments: [reading.path, work.path] + arguments, workDirectory: work)
        let size = try FileVersion(output).size
        guard size > 0, size <= 512 * 1024 * 1024 else {
            throw ConversionError.message("The PDF writer produced an empty or oversized file.")
        }
        switch format {
        case "docx", "html":
            let extracted = work.appendingPathComponent("text-\(UUID().uuidString).xml")
            defer { try? FileManager.default.removeItem(at: extracted) }
            if format == "docx" {
                try DocumentConverter.validate(output, format: format)
                try ExternalTool.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", output.path, "word/document.xml"],
                    workDirectory: work, outputFile: extracted, outputLimit: 512 * 1024 * 1024)
            } else {
                try DocumentConverter.validateXML(output, root: "html", namespace: "http://www.w3.org/1999/xhtml")
            }
            let check = PDFDocumentTextCheck()
            guard let parser = XMLParser(contentsOf: format == "docx" ? extracted : output) else {
                throw ConversionError.message("The PDF text check could not read the output.")
            }
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = check
            guard parser.parse(), let document = PDFDocument(url: reading) else {
                throw ConversionError.message("The PDF text check could not read the documents.")
            }
            var expected: [UInt32: Int] = [:]
            for number in pages {
                try Task.checkCancellation()
                autoreleasepool { addPDFCharacters(document.page(at: number - 1)?.string ?? "", to: &expected) }
            }
            guard expected.allSatisfy({ check.characters[$0.key, default: 0] >= $0.value }) else {
                throw ConversionError.message("The \(format.uppercased()) output did not preserve all readable PDF text.")
            }
        case "svg":
            try DocumentConverter.validateXML(output, root: "svg", namespace: "http://www.w3.org/2000/svg")
        default: break
        }
        guard try FileVersion(input) == version else { throw ConversionError.message("The PDF changed during conversion.") }
    }

    static func renderPNG(_ input: URL, to output: URL, page: Int, size: CGSize,
                          resolution: Int, opaque: Bool, tool: URL) throws {
        guard (72...1200).contains(resolution) else { throw ConversionError.message("Use 72–1200 DPI for PDF images.") }
        let scale = Double(resolution) / 72
        guard size.width * scale <= 100_000, size.height * scale <= 100_000,
              ceil(size.width * scale) * ceil(size.height * scale) <= 256_000_000 else {
            throw ConversionError.message("The selected page and resolution exceed the 256-megapixel render limit.")
        }
        let work = output.deletingLastPathComponent()
        try ExternalTool.run(tool, arguments: [input.path, work.path, "draw", "-q", "-a", "-L", "-m", "268435456",
            "-F", "png", "-o", output.lastPathComponent, "-r", String(resolution), "-c", opaque ? "rgb" : "rgba",
            "-B", "128", "-T", "1", input.path, String(page)], workDirectory: work)
        let bytes = try FileVersion(output).size
        guard bytes > 0, bytes <= 512 * 1024 * 1024,
              let image = CGImageSourceCreateWithURL(output as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(image) as String? == "public.png", CGImageSourceGetCount(image) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ConversionError.message("The rendered PDF page is not a readable PNG within 512 MiB.")
        }
        guard abs(Double(width) - size.width * scale) <= 1,
              abs(Double(height) - size.height * scale) <= 1 else {
            throw ConversionError.message("The rendered PDF page has incorrect dimensions.")
        }
    }
}

func addPDFCharacters(_ text: String, to counts: inout [UInt32: Int]) {
    for scalar in text.decomposedStringWithCompatibilityMapping.unicodeScalars
        where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
        counts[scalar.value, default: 0] += 1
    }
}

private final class PDFDocumentTextCheck: NSObject, XMLParserDelegate {
    var characters: [UInt32: Int] = [:]
    private var inText = false
    private var inBody = false
    private var fallback = 0
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "Fallback", namespaceURI == "http://schemas.openxmlformats.org/markup-compatibility/2006" { fallback += 1 }
        if elementName == "t", namespaceURI == "http://schemas.openxmlformats.org/wordprocessingml/2006/main" { inText = true }
        if elementName == "body", namespaceURI == "http://www.w3.org/1999/xhtml" { inBody = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if (inText || inBody), fallback == 0 { addPDFCharacters(string, to: &characters) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { inText = false }
        if elementName == "body", namespaceURI == "http://www.w3.org/1999/xhtml" { inBody = false }
        if elementName == "Fallback", namespaceURI == "http://schemas.openxmlformats.org/markup-compatibility/2006" { fallback -= 1 }
    }
}
