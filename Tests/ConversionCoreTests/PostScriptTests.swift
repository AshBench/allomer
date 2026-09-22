import CoreGraphics
import Foundation
import XCTest

@testable import ConversionCore

final class PostScriptTests: XCTestCase {
    func testPostScriptPagesSettingsAccessAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["postscript", "psguard"].allSatisfy({ FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the PostScript helper to check PDF conversion.")
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("PDF 100% \" café-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let source = directory.appendingPathComponent("original.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 240, height: 180)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &bounds, nil))
        for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
            context.beginPDFPage(nil)
            context.setFillColor(color)
            context.fill(bounds)
            context.endPDFPage()
        }
        context.closePDF()
        let original = try Data(contentsOf: source)
        var options = PostScriptOptions()
        options.epsPage = 2
        XCTAssertEqual(try JSONDecoder().decode(PostScriptOptions.self, from: Data("{}".utf8)), PostScriptOptions())
        XCTAssertEqual(try JSONDecoder().decode(PostScriptOptions.self, from: JSONEncoder().encode(options)), options)
        let eps = directory.appendingPathComponent("second.eps")
        try engine.convert(source, to: eps, settings: .init(postScriptOptions: options))
        let restored = directory.appendingPathComponent("second.pdf")
        try engine.convert(eps, to: restored)
        let page = try XCTUnwrap(CGPDFDocument(restored as CFURL)?.page(at: 1))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.scaleBy(x: 1 / bounds.width, y: 1 / bounds.height)
        bitmap.drawPDFPage(page)
        let pixel = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertLessThan(pixel[0], 10)
        XCTAssertGreaterThan(pixel[2], 245)
        XCTAssertEqual(CGPDFDocument(restored as CFURL)?.numberOfPages, 1)
        for level in [2, 3] {
            options.languageLevel = level
            let ps = directory.appendingPathComponent("level-\(level).ps")
            try engine.convert(source, to: ps, settings: .init(postScriptOptions: options))
            XCTAssertTrue(try String(contentsOf: ps, encoding: .ascii).contains("%%LanguageLevel: \(level)"))
            let pdf = directory.appendingPathComponent("level-\(level).pdf")
            try engine.convert(ps, to: pdf)
            XCTAssertEqual(CGPDFDocument(pdf as CFURL)?.numberOfPages, 2)
        }
        let croppedEPS = directory.appendingPathComponent("bounds.eps")
        try Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 10 20 150 100\n0 1 0 setrgbcolor 10 20 140 80 rectfill showpage\n%%EOF\n".utf8).write(to: croppedEPS)
        for preset in PostScriptOptions.PDFPreset.allCases {
            options.pdfPreset = preset
            let output = directory.appendingPathComponent("\(preset.rawValue).pdf")
            try engine.convert(croppedEPS, to: output, settings: .init(postScriptOptions: options))
            XCTAssertEqual(CGPDFDocument(output as CFURL)?.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 140, height: 80))
        }
        options.cropEPS = false
        let uncropped = directory.appendingPathComponent("uncropped.pdf")
        try engine.convert(croppedEPS, to: uncropped, settings: .init(postScriptOptions: options))
        XCTAssertGreaterThan(try XCTUnwrap(CGPDFDocument(uncropped as CFURL)?.page(at: 1)).getBoxRect(.mediaBox).width, 140)
        options.epsPage = 3
        XCTAssertThrowsError(try engine.convert(source, to: directory.appendingPathComponent("missing.eps"), settings: .init(postScriptOptions: options)))
        options = PostScriptOptions()
        options.languageLevel = 1
        XCTAssertThrowsError(try engine.convert(source, to: directory.appendingPathComponent("invalid.ps"), settings: .init(postScriptOptions: options)))
        for (index, pair) in [(source, "ps"), (source, "eps"), (eps, "pdf"), (directory.appendingPathComponent("level-2.ps"), "pdf")].enumerated() {
            let originalURL = directory.appendingPathComponent("auto-\(index).\(pair.0.pathExtension)")
            let renamed = originalURL.deletingPathExtension().appendingPathExtension(pair.1)
            let bytes = try Data(contentsOf: pair.0)
            try bytes.write(to: originalURL)
            try manager.moveItem(at: originalURL, to: renamed)
            let record = try engine.convertRenamedFile(from: originalURL, to: renamed,
                historyDirectory: directory.appendingPathComponent("history"))
            XCTAssertEqual(record.state, .completed)
            XCTAssertNotEqual(try Data(contentsOf: renamed), bytes)
            XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
            XCTAssertEqual(try Data(contentsOf: originalURL), bytes)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        let before = try Data(contentsOf: eps)
        XCTAssertThrowsError(try engine.convert(source, to: eps))
        XCTAssertEqual(try Data(contentsOf: eps), before)
    }
}
