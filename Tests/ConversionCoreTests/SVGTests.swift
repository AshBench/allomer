import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import XCTest
import zlib

@testable import ConversionCore

final class SVGTests: XCTestCase {
    func testSVGTracingAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["vectortrace", "traceguard"].allSatisfy({ FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the tracing helper to check conversion.")
        }
        var options = try JSONDecoder().decode(ImageOptions.self, from: Data("{\"tracing\":{\"preset\":\"poster\"}}".utf8))
        XCTAssertEqual(options.tracing.preset, .poster)
        XCTAssertEqual(options.tracing.filterSpeckle, 4)
        XCTAssertFalse(options.tracing.advanced)
        XCTAssertEqual(ImageOptions().tracing.preset, .photo)
        XCTAssertEqual(try JSONDecoder().decode(ImageOptions.self, from: JSONEncoder().encode(options)), options)
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("SVG tracing café 100%, \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let source = work.appendingPathComponent("original.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: source)
        let engine = try ConversionEngine(toolsDirectory: tools)
        XCTAssertTrue(engine.availableOutputs(for: source).contains { $0.id == "svg" })
        XCTAssertTrue(engine.availableOutputs(for: source).contains { $0.id == "svgz" })
        let output = work.appendingPathComponent("traced.svg")
        try engine.convert(source, to: output, settings: .init(imageOptions: options))
        let xml = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(xml.contains("<path "))
        XCTAssertFalse(xml.contains("<image"))
        XCTAssertEqual(try DocumentConverter.validateXML(output, root: "svg", namespace: "http://www.w3.org/2000/svg")["width"], "48")
        XCTAssertThrowsError(try engine.convert(source, to: output, settings: .init(imageOptions: options)))
        options.tracing.maxIterations = 0
        let invalid = work.appendingPathComponent("invalid.svg")
        XCTAssertThrowsError(try engine.convert(source, to: invalid, settings: .init(imageOptions: options)))
        XCTAssertFalse(manager.fileExists(atPath: invalid.path))
        options.tracing.maxIterations = 10
        let pages = work.appendingPathComponent("pages.tiff")
        let pageWriter = try XCTUnwrap(CGImageDestinationCreateWithURL(pages as CFURL, "public.tiff" as CFString, 2, nil))
        for _ in 0..<2 { CGImageDestinationAddImage(pageWriter, try XCTUnwrap(context.makeImage()), nil) }
        XCTAssertTrue(CGImageDestinationFinalize(pageWriter))
        XCTAssertFalse(engine.availableOutputs(for: pages).contains { ["svg", "svgz"].contains($0.id) })
        XCTAssertThrowsError(try engine.convert(pages, to: work.appendingPathComponent("pages.svg")))
        let renamed = work.appendingPathComponent("original.svg")
        try manager.moveItem(at: source, to: renamed)
        let record = try engine.convertRenamedFile(from: source, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), settings: .init(imageOptions: options))
        XCTAssertEqual(record.state, .completed)
        XCTAssertTrue(try String(contentsOf: renamed, encoding: .utf8).contains("<path "))
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testSVGSizeCompressionResourcesAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("webguard").path) else {
            throw XCTSkip("Build the native web helper to check SVG conversion.")
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("SVG café 100% \(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="640" height="400" viewBox="0 0 640 400">
          <style>text {font: bold 28px Arial; fill: #123456}</style>
          <rect x="20" y="80" width="500" height="200" fill="red"/>
          <text x="30" y="55">Original SVG text</text>
        </svg>
        """
        try svg.write(to: source, atomically: false, encoding: .utf8)
        let original = try Data(contentsOf: source)
        let engine = try ConversionEngine(toolsDirectory: tools)
        var options = ImageOptions()
        let old = try JSONDecoder().decode(ImageOptions.self, from: Data("{\"quality\":0.6}".utf8))
        XCTAssertEqual(old.quality, 0.6)
        XCTAssertEqual(old.svgWidth, 0)
        XCTAssertEqual(old.svgScale, 1)
        options.svgWidth = 320
        options.svgScale = -1 // Explicit dimensions make scale inactive.
        XCTAssertEqual(try JSONDecoder().decode(ImageOptions.self, from: JSONEncoder().encode(options)), options)
        let png = directory.appendingPathComponent("small.png")
        try engine.convert(source, to: png, settings: .init(imageOptions: options))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil)), 0, nil))
        XCTAssertEqual(decoded.width, 320)
        XCTAssertEqual(decoded.height, 200)
        options.svgHeight = 320
        let square = directory.appendingPathComponent("square.pdf")
        try engine.convert(source, to: square, settings: .init(imageOptions: options))
        let pdf = try XCTUnwrap(PDFDocument(url: square))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 320, height: 320))
        XCTAssertTrue(pdf.string?.contains("Original SVG text") == true)
        options.svgWidth = 0
        options.svgHeight = 0
        XCTAssertThrowsError(try engine.convert(source, to: directory.appendingPathComponent("bad-scale.png"), settings: .init(imageOptions: options)))
        options.svgScale = 0.5
        for name in ["png", "pdf", "svgz", "jpg"] {
            let before = directory.appendingPathComponent("auto-\(name).svg")
            let renamed = before.deletingPathExtension().appendingPathExtension(name)
            try original.write(to: before)
            try manager.moveItem(at: before, to: renamed)
            let record = try engine.convertRenamedFile(from: before, to: renamed,
                historyDirectory: directory.appendingPathComponent("history"), settings: .init(imageOptions: options))
            XCTAssertEqual(record.state, .completed)
            if name == "svgz" {
                let restored = directory.appendingPathComponent("inflated.svg")
                try engine.convert(renamed, to: restored)
                XCTAssertEqual(try Data(contentsOf: restored), original)
                try engine.convert(renamed, to: directory.appendingPathComponent("from-svgz.png"))
            }
            XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
            XCTAssertEqual(try Data(contentsOf: before), original)
        }
        let malicious = directory.appendingPathComponent("external.svg")
        try svg.replacingOccurrences(of: "</svg>", with: "<image href=\"https://example.invalid/missing.png\" width=\"40\" height=\"40\"/></svg>")
            .write(to: malicious, atomically: false, encoding: .utf8)
        let rejected = directory.appendingPathComponent("external.png")
        XCTAssertThrowsError(try engine.convert(malicious, to: rejected))
        XCTAssertFalse(manager.fileExists(atPath: rejected.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertThrowsError(try engine.convert(source, to: png))
    }
}
