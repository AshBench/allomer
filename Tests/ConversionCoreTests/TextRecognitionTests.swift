import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import XCTest

@testable import ConversionCore

final class TextRecognitionTests: XCTestCase {
    func testImageTextRecognitionAndSearchablePDFWithAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("nativeguard").path) else {
            throw XCTSkip("Build the native helper to check OCR.")
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("OCR 100% café-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 480))
        let lines = ["Local text stays here", "Invoice number 4827", "Total 123.45"]
        for (index, value) in lines.enumerated() {
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 50, y: 360 - index * 110)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 48, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])), context)
        }
        let source = directory.appendingPathComponent("original.png")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: source)
        let textOutput = directory.appendingPathComponent("recognized.txt")
        try engine.convert(source, to: textOutput)
        let text = try String(contentsOf: textOutput, encoding: .utf8)
        for line in lines { XCTAssertTrue(text.contains(line), text) }
        let jpeg = directory.appendingPathComponent("original.jpg")
        let jpegText = directory.appendingPathComponent("jpeg-text.txt")
        try engine.convert(source, to: jpeg)
        try engine.convert(jpeg, to: jpegText)
        let checkedJPEGText = try String(contentsOf: jpegText, encoding: .utf8)
        for line in lines { XCTAssertTrue(checkedJPEGText.contains(line), checkedJPEGText) }
        var options = PDFOptions()
        XCTAssertFalse(options.imageOCR)
        XCTAssertFalse(try JSONDecoder().decode(PDFOptions.self, from: Data("{}".utf8)).imageOCR)
        XCTAssertEqual(try JSONDecoder().decode(PDFOptions.self, from: Data("{}".utf8)).ocrLanguage, "auto")
        XCTAssertTrue(PDFOptions.ocrLanguages.contains("en-US"))
        options.imageOCR = true
        options.ocrLanguage = "en-US"
        XCTAssertEqual(try JSONDecoder().decode(PDFOptions.self, from: JSONEncoder().encode(options)), options)
        let pdf = directory.appendingPathComponent("searchable.pdf")
        try engine.convert(source, to: pdf, settings: .init(pdfOptions: options))
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        let page = try XCTUnwrap(document.page(at: 0))
        let searchable = page.string ?? ""
        for line in lines { XCTAssertTrue(searchable.contains(line), searchable) }
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 1000, accuracy: 0.01)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 480, accuracy: 0.01)
        let bounds = try XCTUnwrap(document.findString(lines[0], withOptions: []).first).bounds(for: page)
        XCTAssertEqual(bounds.minX, 50, accuracy: 15)
        XCTAssertEqual(bounds.minY, 360, accuracy: 15)
        XCTAssertGreaterThan(bounds.width, 350)
        XCTAssertLessThan(bounds.height, 65)
        let mixed = directory.appendingPathComponent("mixed.pdf")
        var paper = CGRect(x: 0, y: 0, width: 1000, height: 480)
        let scanWriter = try XCTUnwrap(CGContext(mixed as CFURL, mediaBox: &paper, nil))
        scanWriter.beginPDFPage(nil)
        scanWriter.textPosition = CGPoint(x: 50, y: 300)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Already selectable", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil)])), scanWriter)
        scanWriter.endPDFPage()
        scanWriter.beginPDFPage(nil)
        scanWriter.draw(try XCTUnwrap(context.makeImage()), in: paper)
        scanWriter.endPDFPage()
        scanWriter.beginPDFPage(nil)
        scanWriter.endPDFPage()
        scanWriter.closePDF()
        let mixedBytes = try Data(contentsOf: mixed)
        XCTAssertFalse(options.recognizeScans)
        XCTAssertFalse(try JSONDecoder().decode(PDFOptions.self, from: Data("{}".utf8)).recognizeScans)
        // A selectable page skips the OCR tools entirely.
        XCTAssertEqual(try OCRConverter.preparePDF(mixed, pages: [1], work: directory,
            tools: directory.appendingPathComponent("missing-tools")), mixed)
        let disabled = directory.appendingPathComponent("ocr-disabled.html")
        try engine.convert(mixed, to: disabled, settings: .init(pdfOptions: options))
        XCTAssertFalse(try String(contentsOf: disabled, encoding: .utf8).contains(lines[0]))
        options.recognizeScans = true
        options.page = 0
        options.resolution = 0 // Inactive image controls must not block document output.
        XCTAssertEqual(try JSONDecoder().decode(PDFOptions.self, from: JSONEncoder().encode(options)), options)
        for name in ["html", "md", "docx"] {
            let before = directory.appendingPathComponent("scanned-\(name).pdf")
            let renamed = before.deletingPathExtension().appendingPathExtension(name)
            try mixedBytes.write(to: before)
            try manager.moveItem(at: before, to: renamed)
            options.pages = "2"
            let record = try engine.convertRenamedFile(from: before, to: renamed,
                historyDirectory: directory.appendingPathComponent("history"), settings: .init(pdfOptions: options))
            let contents: String
            if name == "docx" {
                contents = String(decoding: try ExternalTool.run(URL(fileURLWithPath: "/usr/bin/unzip"),
                    arguments: ["-p", renamed.path, "word/document.xml"], workDirectory: directory, captureOutput: true), as: UTF8.self)
            } else { contents = try String(contentsOf: renamed, encoding: .utf8) }
            XCTAssertTrue(contents.contains(lines[0]), contents.prefix(1000).description)
            XCTAssertFalse(contents.contains("Already selectable"))
            XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
            XCTAssertEqual(try Data(contentsOf: before), mixedBytes)
        }
        let missingPDFTool = directory.appendingPathComponent("incomplete-tools")
        try manager.createDirectory(at: missingPDFTool, withIntermediateDirectories: false)
        try manager.createSymbolicLink(at: missingPDFTool.appendingPathComponent("nativeguard"),
            withDestinationURL: tools.appendingPathComponent("nativeguard"))
        XCTAssertThrowsError(try OCRConverter.preparePDF(mixed, pages: [2], work: directory, tools: missingPDFTool))
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("ocr-") && $0.hasSuffix(".pdf") })
        let prepared = try OCRConverter.preparePDF(mixed, pages: [1, 2, 3], work: directory, tools: tools)
        let preparedPDF = try XCTUnwrap(PDFDocument(url: prepared))
        XCTAssertEqual(preparedPDF.pageCount, 3)
        XCTAssertEqual(preparedPDF.page(at: 0)?.string, PDFDocument(url: mixed)?.page(at: 0)?.string)
        XCTAssertTrue(preparedPDF.page(at: 1)?.string?.contains(lines[0]) == true)
        XCTAssertTrue((preparedPDF.page(at: 2)?.string ?? "").isEmpty)
        try manager.removeItem(at: prepared)
        XCTAssertEqual(try Data(contentsOf: mixed), mixedBytes)
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("ocr-") && $0.hasSuffix(".pdf") })
        var invalidLanguage = PDFOptions()
        invalidLanguage.ocrLanguage = "unsupported-language"
        invalidLanguage.recognizeScans = true
        let rejectedText = directory.appendingPathComponent("invalid-language.txt")
        let rejectedDocument = directory.appendingPathComponent("invalid-language.docx")
        XCTAssertThrowsError(try engine.convert(source, to: rejectedText, settings: .init(pdfOptions: invalidLanguage)))
        XCTAssertThrowsError(try engine.convert(mixed, to: rejectedDocument, settings: .init(pdfOptions: invalidLanguage)))
        XCTAssertFalse(manager.fileExists(atPath: rejectedText.path))
        XCTAssertFalse(manager.fileExists(atPath: rejectedDocument.path))
        options = PDFOptions()
        options.imageOCR = true
        for name in ["txt", "md", "docx", "pdf"] {
            let before = directory.appendingPathComponent("auto-\(name).png")
            let renamed = before.deletingPathExtension().appendingPathExtension(name)
            try original.write(to: before)
            try manager.moveItem(at: before, to: renamed)
            let record = try engine.convertRenamedFile(from: before, to: renamed,
                historyDirectory: directory.appendingPathComponent("history"), settings: .init(pdfOptions: options))
            XCTAssertEqual(record.state, .completed)
            if name == "md" { XCTAssertTrue(try String(contentsOf: renamed, encoding: .utf8).contains(lines[0])) }
            if name == "docx" {
                let data = try ExternalTool.run(URL(fileURLWithPath: "/usr/bin/unzip"),
                    arguments: ["-p", renamed.path, "word/document.xml"], workDirectory: directory, captureOutput: true)
                XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(lines[0]))
            }
            XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
            XCTAssertEqual(try Data(contentsOf: before), original)
        }
        let misleading = directory.appendingPathComponent("image-with-wrong-extension.pdf")
        try original.write(to: misleading)
        try engine.convert(misleading, to: directory.appendingPathComponent("from-misleading.txt"))
        let privateWork = directory.appendingPathComponent("boundary")
        try manager.createDirectory(at: privateWork, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ExternalTool.run(tools.appendingPathComponent("nativeguard"),
            arguments: [source.path, privateWork.path, "image", misleading.path, "blocked.txt", "txt"],
            workDirectory: privateWork))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertThrowsError(try engine.convert(source, to: textOutput))
        XCTAssertEqual(try String(contentsOf: textOutput, encoding: .utf8), text)
    }
}
