import ConversionCore
import SwiftUI
import XCTest
@testable import ConvertApp

final class ConversionOptionsTests: XCTestCase {
    @MainActor
    func testSourceIdentityControlsOptionsAfterRename() {
        func view(_ sourceID: String, to targetID: String, category: String, sourceCategory: String) -> ConversionOptionsView {
            ConversionOptionsView(settings: .constant(ConversionSettings()), targetID: targetID,
                source: URL(fileURLWithPath: "/renamed." + targetID), sourceID: sourceID,
                category: category, sourceCategory: sourceCategory)
        }
        let pdfImage = view("pdf", to: "png", category: "image", sourceCategory: "document")
        XCTAssertTrue(pdfImage.showsPDFPages)
        XCTAssertFalse(pdfImage.showsSVGSize)
        let pdfText = view("pdf", to: "txt", category: "document", sourceCategory: "document")
        XCTAssertTrue(pdfText.showsPDFPages)
        XCTAssertTrue(pdfText.showsTextRecognition)
        for source in ["svg", "svgz"] {
            let svgImage = view(source, to: "png", category: "image", sourceCategory: "image")
            XCTAssertTrue(svgImage.showsSVGSize)
            XCTAssertFalse(svgImage.showsPDFPages)
        }
        for source in ["postscript", "eps"] {
            XCTAssertTrue(view(source, to: "pdf", category: "document", sourceCategory: "document").showsPostScriptOptions)
        }
        XCTAssertFalse(view("html", to: "pdf", category: "document", sourceCategory: "document").showsPostScriptOptions)
        XCTAssertTrue(view("png", to: "svg", category: "image", sourceCategory: "image").showsSVGTracing)
        XCTAssertFalse(view("svg", to: "svgz", category: "image", sourceCategory: "image").showsSVGTracing)
        XCTAssertFalse(view("pdf", to: "zip", category: "archive", sourceCategory: "document").showsPDFPages)
        for target in ["avi", "m2ts", "mpeg", "ts", "vob", "wmv", "mp4", "mov", "mkv", "webm"] {
            XCTAssertFalse(view("wav", to: target, category: "video", sourceCategory: "audio").showsVideoOptions)
            XCTAssertTrue(view("mkv", to: target, category: "video", sourceCategory: "video").showsVideoOptions)
        }
        XCTAssertFalse(view("mkv", to: "flac", category: "audio", sourceCategory: "video").showsVideoOptions)
        let fallback = ConversionOptionsView(settings: .constant(ConversionSettings()), targetID: "png",
            source: URL(fileURLWithPath: "/original.PDF"), category: "image", sourceCategory: "document")
        XCTAssertTrue(fallback.showsPDFPages)
        let defaults = ConversionOptionsView(settings: .constant(ConversionSettings()))
        XCTAssertTrue(defaults.showsPDFPages && defaults.showsSVGSize && defaults.showsSVGTracing
            && defaults.showsPostScriptOptions && defaults.showsTextRecognition && defaults.showsVideoOptions)
    }

    func testMarkdownFlavorKeepsLegacySettingsAndRoundTripsRules() throws {
        let old = Data(#"{"standalone":false,"syntaxHighlighting":false,"pdfPageSize":"letter","pdfTemplate":"minimal"}"#.utf8)
        let decoded = try JSONDecoder().decode(DocumentOptions.self, from: old)
        XCTAssertEqual(decoded.markdownFlavor, .gfm)
        XCTAssertFalse(decoded.standalone)
        XCTAssertFalse(decoded.syntaxHighlighting)
        XCTAssertEqual(decoded.pdfPageSize, "letter")
        XCTAssertEqual(decoded.pdfTemplate, "minimal")
        for flavor in DocumentOptions.MarkdownFlavor.allCases {
            var settings = ConversionSettings()
            settings.documentOptions.markdownFlavor = flavor
            let rule = ConversionRule(sourceID: "html", targetID: "markdown", action: .askFirst,
                settings: settings, stageOverrides: [.init(sourceID: "html", targetID: "markdown", settings: settings)])
            XCTAssertEqual(try JSONDecoder().decode(ConversionRule.self, from: JSONEncoder().encode(rule)), rule)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(DocumentOptions.self,
            from: Data(#"{"markdownFlavor":"unknown"}"#.utf8)))
    }

    func testMarkdownFlavorChangesReadingAndWriting() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard manager.isExecutableFile(atPath: tools.appendingPathComponent("carta").path) else {
            throw XCTSkip("Build the document helper before checking Markdown flavors.")
        }
        let work = manager.temporaryDirectory.appendingPathComponent("Markdown flavors \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let input = work.appendingPathComponent("original.md")
        let markdown = "# Café 東京\n\n| Label | Amount |\n| --- | --- |\n| Original | 7 |\n"
        try Data(markdown.utf8).write(to: input)
        let html = work.appendingPathComponent("original.html")
        let document = "<h1>Café 東京</h1><table><thead><tr><th>Label</th><th>Amount</th></tr></thead><tbody><tr><td>Original</td><td>7</td></tr></tbody></table>"
        try Data(document.utf8).write(to: html)
        let engine = try ConversionEngine(toolsDirectory: tools)
        var rendered: [DocumentOptions.MarkdownFlavor: String] = [:]
        var written: [DocumentOptions.MarkdownFlavor: String] = [:]
        for flavor in DocumentOptions.MarkdownFlavor.allCases {
            var options = DocumentOptions()
            options.markdownFlavor = flavor
            options.standalone = false
            let readOutput = work.appendingPathComponent("read-\(flavor.rawValue).html")
            try engine.convert(input, to: readOutput, settings: .init(documentOptions: options))
            rendered[flavor] = try String(contentsOf: readOutput, encoding: .utf8)
            let writeOutput = work.appendingPathComponent("write-\(flavor.rawValue).md")
            try engine.convert(html, to: writeOutput, settings: .init(documentOptions: options))
            written[flavor] = try String(contentsOf: writeOutput, encoding: .utf8)
            XCTAssertTrue(rendered[flavor]!.contains("Café 東京"), flavor.rawValue)
            XCTAssertTrue(written[flavor]!.contains("Original"), flavor.rawValue)
        }
        XCTAssertTrue(try XCTUnwrap(rendered[.gfm]).contains("<table"))
        XCTAssertFalse(try XCTUnwrap(rendered[.commonmark]).contains("<table"))
        XCTAssertTrue(try XCTUnwrap(written[.gfm]).contains("|"))
        XCTAssertTrue(try XCTUnwrap(written[.commonmark]).contains("<table"))
        XCTAssertNotEqual(written[.gfm], written[.commonmark])
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), markdown)
        XCTAssertEqual(try String(contentsOf: html, encoding: .utf8), document)
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: work.path).contains { $0.hasPrefix(".allomer-") })
    }
}
