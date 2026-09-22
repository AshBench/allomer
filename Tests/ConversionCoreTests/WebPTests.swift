import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import ConversionCore

final class WebPTests: XCTestCase {
    func testWebPOptionsConversionAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("webpguard").path) else {
            throw XCTSkip("Build the WebP helper to check encoding.")
        }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("WebP café \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let source = work.appendingPathComponent("original.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary:
            [kCGImagePropertyExifUserComment: "Original WebP metadata"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: source)
        let engine = try ConversionEngine(toolsDirectory: tools)
        XCTAssertTrue(engine.availableOutputs(for: source).contains { $0.id == "webp" })
        let old = try JSONDecoder().decode(ImageOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(old.quality, 0.85)
        XCTAssertEqual(old.webpMode, .lossy)
        XCTAssertEqual(old.webpEffort, 4)
        var options = old
        for mode in ImageCompressionMode.allCases {
            options.webpMode = mode
            options.webpEffort = mode == .lossy ? 0 : 6
            let output = work.appendingPathComponent("\(mode).webp")
            try engine.convert(source, to: output, settings: .init(imageOptions: options))
            let check = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(check) as String?, "org.webmproject.webp")
            XCTAssertEqual(CGImageSourceGetCount(check), 1)
            XCTAssertNil(try AnimationFrames(source: check, type: "org.webmproject.webp"))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any])
            XCTAssertEqual((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String,
                           "Original WebP metadata")
            try engine.convert(output, to: work.appendingPathComponent("\(mode)-roundtrip.png"))
            XCTAssertThrowsError(try engine.convert(source, to: output, settings: .init(imageOptions: options)))
        }
        XCTAssertEqual(try JSONDecoder().decode(ImageOptions.self, from: JSONEncoder().encode(options)), options)
        options.preserveMetadata = false
        options.convertToSRGB = true
        let clean = work.appendingPathComponent("clean.webp")
        try engine.convert(source, to: clean, settings: .init(imageOptions: options))
        let cleanSource = try XCTUnwrap(CGImageSourceCreateWithURL(clean as CFURL, nil))
        let cleanProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(cleanSource, 0, nil) as? [CFString: Any])
        XCTAssertNil((cleanProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
        options.webpEffort = 7
        let invalid = work.appendingPathComponent("invalid.webp")
        XCTAssertThrowsError(try engine.convert(source, to: invalid, settings: .init(imageOptions: options)))
        XCTAssertFalse(manager.fileExists(atPath: invalid.path))
        options.webpEffort = 4
        let renamed = work.appendingPathComponent("original.webp")
        try manager.moveItem(at: source, to: renamed)
        let record = try engine.convertRenamedFile(from: source, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), settings: .init(imageOptions: options))
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(ImageConverter.detectedType(at: renamed), "org.webmproject.webp")
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
