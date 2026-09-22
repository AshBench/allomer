import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import ConversionCore

final class JPEGXLTests: XCTestCase {
    func testJPEGXLSettingsMigration() throws {
        let cases: [(String, ImageCompressionMode, Int)] = [
            ("{}", .lossy, 7),
            ("{\"quality\":1}", .lossless, 4),
            ("{\"quality\":1,\"jpegXLLosslessEffort\":8}", .lossless, 8),
            ("{\"quality\":0.85,\"jpegXLLosslessEffort\":8}", .lossy, 7),
            ("{\"quality\":1,\"jpegXLMode\":\"lossy\"}", .lossy, 7),
            ("{\"quality\":0.1,\"jpegXLMode\":\"lossless\"}", .lossless, 7),
            ("{\"quality\":0.1,\"jpegXLMode\":\"lossless\",\"jpegXLEffort\":10}", .lossless, 10)
        ]
        for (json, mode, effort) in cases {
            let options = try JSONDecoder().decode(ImageOptions.self, from: Data(json.utf8))
            XCTAssertEqual(options.jpegXLMode, mode, json)
            XCTAssertEqual(options.jpegXLEffort, effort, json)
            let encoded = try JSONEncoder().encode(options)
            XCTAssertEqual(try JSONDecoder().decode(ImageOptions.self, from: encoded), options)
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNil(values["jpegXLLosslessEffort"])
            XCTAssertEqual(values["jpegXLMode"] as? String, mode.rawValue)
        }
        XCTAssertEqual(try JSONDecoder().decode(ImageOptions.self, from: Data("{}".utf8)), ImageOptions())
    }
    func testJPEGXLOutputAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["cjxl", "jxlguard"].allSatisfy({ FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the JPEG XL tools to check conversion.")
        }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("JPEG XL café \(UUID().uuidString)")
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
        XCTAssertTrue(engine.availableOutputs(for: source).contains { $0.id == "jxl" })
        var options = try JSONDecoder().decode(ImageOptions.self, from: Data("{\"quality\":1}".utf8))
        XCTAssertEqual(options.jpegXLMode, .lossless)
        XCTAssertEqual(options.jpegXLEffort, 4)
        options.jpegXLEffort = 7
        XCTAssertEqual(try JSONDecoder().decode(ImageOptions.self, from: JSONEncoder().encode(options)), options)
        options.jpegXLEffort = 4
        let output = work.appendingPathComponent("result.jxl")
        try engine.convert(source, to: output, settings: .init(imageOptions: options))
        XCTAssertEqual(ImageConverter.detectedType(at: output), "public.jpeg-xl")
        let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertEqual(image.width, 48)
        XCTAssertEqual(image.height, 32)
        try engine.convert(output, to: work.appendingPathComponent("roundtrip.png"))
        XCTAssertThrowsError(try engine.convert(source, to: output))
        options.quality = 2
        XCTAssertThrowsError(try engine.convert(source, to: work.appendingPathComponent("invalid.jxl"), settings: .init(imageOptions: options)))
        options.quality = 1
        let renamed = work.appendingPathComponent("original.jxl")
        try manager.moveItem(at: source, to: renamed)
        let record = try engine.convertRenamedFile(from: source, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), settings: .init(imageOptions: options))
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(ImageConverter.detectedType(at: renamed), "public.jpeg-xl")
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
