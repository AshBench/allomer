import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import XCTest

@testable import ConversionCore

final class DocumentPDFTests: XCTestCase {
    func testHTMLAndMarkdownPDFPagesSettingsAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["webguard", "carta", "pdfguard"].allSatisfy({ FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the native, document, and PDF helpers to check document PDF export.")
        }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Document PDF café 100% \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let source = work.appendingPathComponent("original.html")
        let markup = """
        <!DOCTYPE html><meta charset="utf-8"><style>.next{break-before:page}@media print{.screen{display:none}}</style>
        <h1>Original Café document</h1><p>First page with <b>bold text</b>.</p>
        <p class="screen">Screen only</p><h1 class="next">Second page</h1><p>Last paragraph.</p>
        """
        try markup.write(to: source, atomically: false, encoding: .utf8)
        let engine = try ConversionEngine(toolsDirectory: tools)
        let old = try JSONDecoder().decode(DocumentOptions.self, from: Data("{\"standalone\":false}".utf8))
        XCTAssertFalse(old.standalone)
        XCTAssertEqual(old.pdfPageSize, "a4")
        XCTAssertEqual(old.pdfTemplate, "github")
        var options = old
        options.pdfPageSize = "letter"
        options.pdfTemplate = "unused" // HTML has no Markdown template.
        let output = work.appendingPathComponent("letter.pdf")
        try engine.convert(source, to: output, settings: .init(documentOptions: options))
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Original Café document") == true)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Last paragraph.") == true)
        XCTAssertFalse(document.string?.contains("Screen only") == true)
        XCTAssertThrowsError(try engine.convert(source, to: output, settings: .init(documentOptions: options)))
        options.pdfPageSize = "invalid"
        XCTAssertThrowsError(try engine.convert(source, to: work.appendingPathComponent("bad-size.pdf"), settings: .init(documentOptions: options)))
        options.pdfPageSize = "a4"
        options.pdfTemplate = "minimal"
        options.syntaxHighlighting = false
        XCTAssertEqual(try JSONDecoder().decode(DocumentOptions.self, from: JSONEncoder().encode(options)), options)
        for (extensionName, contents) in [("html", markup), ("md", "# Original Markdown\n\nA **bold** paragraph.\n\n```swift\nlet answer = 42\n```\n") ] {
            let before = work.appendingPathComponent("automatic.\(extensionName)")
            let renamed = work.appendingPathComponent("automatic.pdf")
            let original = Data(contents.utf8)
            try original.write(to: before)
            try manager.moveItem(at: before, to: renamed)
            let record = try engine.convertRenamedFile(from: before, to: renamed,
                historyDirectory: work.appendingPathComponent("history"), settings: .init(documentOptions: options))
            let result = try XCTUnwrap(PDFDocument(url: renamed))
            XCTAssertEqual(result.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 595.28, accuracy: 1)
            XCTAssertTrue(result.string?.contains(extensionName == "html" ? "Last paragraph." : "let answer = 42") == true)
            XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
            XCTAssertEqual(try Data(contentsOf: before), original)
        }
        let bad = work.appendingPathComponent("remote.html")
        let retained = try Set(manager.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix(".allomer-") })
        try "<img src=\"https://example.invalid/remote.png\">".write(to: bad, atomically: false, encoding: .utf8)
        let refused = work.appendingPathComponent("remote.pdf")
        XCTAssertThrowsError(try engine.convert(bad, to: refused))
        XCTAssertFalse(manager.fileExists(atPath: refused.path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), markup)
        XCTAssertEqual(try Set(manager.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix(".allomer-") }), retained)
    }
    func testPDFPagesRenderingDocumentsAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("pdfguard").path) else {
            throw XCTSkip("Build the PDF tool to check page conversion.")
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("PDF 100% \" \(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let source = directory.appendingPathComponent("original.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &bounds, nil))
        for (index, title) in ["First page", "Second page"].enumerated() {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: index == 0 ? 1 : 0, green: 0, blue: index == 1 ? 1 : 0, alpha: 1))
            context.fill(bounds)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 32, y: 700)
            let text = NSAttributedString(string: title, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        let original = try Data(contentsOf: source)
        var options = PDFOptions()
        options.page = 2
        options.pages = "2"
        options.resolution = 72
        options.slideResolution = 72
        XCTAssertEqual(try JSONDecoder().decode(PDFOptions.self, from: JSONEncoder().encode(options)), options)
        XCTAssertEqual(try JSONDecoder().decode(PDFOptions.self, from: Data("{\"page\":2}".utf8)).resolution, 300)
        XCTAssertEqual(try JSONDecoder().decode(PDFOptions.self, from: Data("{\"page\":2}".utf8)).slideResolution, 144)
        let png = directory.appendingPathComponent("second.png")
        try engine.convert(source, to: png, settings: .init(pdfOptions: options))
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
        XCTAssertEqual(decoded.width, 596)
        XCTAssertEqual(decoded.height, 842)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(pixel[2], 245)
        XCTAssertLessThan(pixel[0], 10)
        let docx = directory.appendingPathComponent("second.docx")
        try engine.convert(source, to: docx, settings: .init(pdfOptions: options))
        let xml = try ExternalTool.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", docx.path, "word/document.xml"],
            workDirectory: directory, captureOutput: true)
        XCTAssertTrue(String(decoding: xml, as: UTF8.self).contains("Second page"))
        XCTAssertFalse(String(decoding: xml, as: UTF8.self).contains("First page"))
        options.pages = "2,1-2"
        let slides = directory.appendingPathComponent("selected.pptx")
        try engine.convert(source, to: slides, settings: .init(pdfOptions: options))
        let members = try ArchiveConverter.manifest(slides, format: "zip")
        XCTAssertEqual(members.filter { $0.path.hasPrefix("ppt/media/") }.count, 2)
        let firstSlide = try ExternalTool.run(URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", slides.path, "ppt/slides/slide1.xml"], workDirectory: directory, captureOutput: true)
        XCTAssertTrue(String(decoding: firstSlide, as: UTF8.self).contains("PDF page 2"))
        let firstImage = try ExternalTool.run(URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", slides.path, "ppt/media/page1.png"], workDirectory: directory, captureOutput: true)
        let slideImage = try XCTUnwrap(CGImageSourceCreateWithData(firstImage as CFData, nil))
        let slidePixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(slideImage, 0, nil))
        XCTAssertEqual(slidePixels.width, 596)
        XCTAssertEqual(slidePixels.height, 842)
        bitmap.draw(slidePixels, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[2], 245)
        XCTAssertLessThan(pixel[0], 10)
        let partial = directory.appendingPathComponent("partial.pptx")
        if engine.outputCapabilities(for: try XCTUnwrap(engine.catalog.format(forExtension: "pdf"))).contains("Presentation PDF") {
            let returned = directory.appendingPathComponent("slides.pdf")
            try engine.convert(slides, to: returned)
            XCTAssertEqual(try PostScriptConverter.pageSizes(returned).count, 2)
            let originalSlides = try Data(contentsOf: slides)
            let autoSource = directory.appendingPathComponent("auto-slides.pptx")
            let renamed = directory.appendingPathComponent("auto-slides.pdf")
            try originalSlides.write(to: renamed)
            let record = try engine.convertRenamedFile(from: autoSource, to: renamed,
                historyDirectory: directory.appendingPathComponent("slide-history"))
            XCTAssertEqual(record.state, .completed)
            XCTAssertEqual(try PostScriptConverter.pageSizes(renamed).count, 2)
            XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
            XCTAssertEqual(try Data(contentsOf: autoSource), originalSlides)
        }
        XCTAssertThrowsError(try ArchiveConverter.makeZIP(to: partial, paths: ["first.xml", "second.png"]) { path, file in
            if path == "second.png" { throw CancellationError() }
            try Data("<first/>".utf8).write(to: file)
        })
        XCTAssertFalse(manager.fileExists(atPath: partial.path))
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("zip-part-") })
        options.resolution = 1200
        let large = directory.appendingPathComponent("high-resolution.png")
        try engine.convert(source, to: large, settings: .init(pdfOptions: options))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(
            XCTUnwrap(CGImageSourceCreateWithURL(large as CFURL, nil)), 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 9922)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 14032)
        options.pages = "2,1-2"
        XCTAssertEqual(try options.selectedPages(count: 2), [2, 1])
        for invalid in ["", "0", "01", "3", "2-1", "1,,2", "1-", "all,1", "-1", "١"] {
            options.pages = invalid
            XCTAssertThrowsError(try options.selectedPages(count: 2), invalid)
        }
        options = PDFOptions()
        options.page = 3
        XCTAssertThrowsError(try engine.convert(source, to: directory.appendingPathComponent("missing.svg"), settings: .init(pdfOptions: options)))
        options.page = 1
        options.resolution = 1201
        options.slideResolution = 1201
        XCTAssertThrowsError(try engine.convert(source, to: directory.appendingPathComponent("invalid.png"), settings: .init(pdfOptions: options)))
        XCTAssertThrowsError(try engine.convert(source, to: directory.appendingPathComponent("invalid.pptx"), settings: .init(pdfOptions: options)))
        options = PDFOptions()
        options.page = 2
        options.pages = "2"
        for extensionName in ["png", "svg", "docx", "html", "md", "jpg", "pptx"] {
            let originalURL = directory.appendingPathComponent("auto-\(extensionName).pdf")
            let renamed = originalURL.deletingPathExtension().appendingPathExtension(extensionName)
            try original.write(to: originalURL)
            try manager.moveItem(at: originalURL, to: renamed)
            let record = try engine.convertRenamedFile(from: originalURL, to: renamed,
                historyDirectory: directory.appendingPathComponent("history"), settings: .init(pdfOptions: options))
            XCTAssertEqual(record.state, .completed)
            if extensionName == "md" {
                let text = try String(contentsOf: renamed, encoding: .utf8)
                XCTAssertTrue(text.contains("Second page"))
                XCTAssertFalse(text.contains("First page"))
            }
            XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
            XCTAssertEqual(try Data(contentsOf: originalURL), original)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        let before = try Data(contentsOf: png)
        XCTAssertThrowsError(try engine.convert(source, to: png))
        XCTAssertEqual(try Data(contentsOf: png), before)
    }
    func testDocumentConversionWithUpstreamTool() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("carta").path) else {
            throw XCTSkip("Run sh tools/fetch-carta.sh to check the document adapter.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("sample ' café.md")
        let docx = directory.appendingPathComponent("sample.docx")
        let html = directory.appendingPathComponent("sample.html")
        let text = "# Café 東京\n\nAn **original** test document.\n"
        try text.write(to: input, atomically: true, encoding: .utf8)
        let engine = try ConversionEngine(toolsDirectory: tools)
        try engine.convert(input, to: docx)
        let independentRead = try NSAttributedString(url: docx,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(independentRead.string.contains("Café 東京"))
        try engine.convert(docx, to: html)
        let result = try String(contentsOf: html, encoding: .utf8)
        XCTAssertTrue(result.contains("Café 東京"))
        XCTAssertTrue(result.contains("<strong>original</strong>"))
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), text)
        for format in engine.catalog.formats where DocumentConverter.outputFormats.contains(format.id) {
            let output = directory.appendingPathComponent("converted.\(format.extensions[0])")
            try engine.convert(input, to: output)
        }
        let invalid = directory.appendingPathComponent("invalid.docx")
        try Data("This is not a document container.".utf8).write(to: invalid)
        XCTAssertThrowsError(try DocumentConverter.validate(invalid, format: "docx"))

        let asset = directory.appendingPathComponent("asset.png")
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        pixels.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let imageFile = try XCTUnwrap(CGImageDestinationCreateWithURL(asset as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(imageFile, try XCTUnwrap(pixels.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(imageFile))
        let withImage = text + "\n![Original fixture](asset.png)\n"
        try withImage.write(to: input, atomically: true, encoding: .utf8)
        let renamed = directory.appendingPathComponent("with-image.docx")
        try FileManager.default.moveItem(at: input, to: renamed)
        let record = try engine.convertRenamedFile(from: input, to: renamed,
            historyDirectory: directory.appendingPathComponent("history"))
        let entries = try ExternalTool.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z", "-1", renamed.path],
            workDirectory: directory, captureOutput: true)
        let imageEntry = try XCTUnwrap(String(decoding: entries, as: UTF8.self).split(separator: "\n")
            .first { $0.hasPrefix("word/media/") && $0.hasSuffix(".png") })
        let embedded = try ExternalTool.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", renamed.path, String(imageEntry)],
            workDirectory: directory, captureOutput: true)
        XCTAssertEqual(embedded, try Data(contentsOf: asset))
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), withImage)
    }
}
