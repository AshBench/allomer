import Foundation
import ImageIO
import XCTest
@testable import ConversionCore

final class IconImageTests: XCTestCase {
    func testIconSizesInputRoutesAndUndo() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Icon images \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        let required = ["cwebp", "webpguard", "webpanim", "webpanimguard", "cjxl", "jxlguard", "vectortrace", "traceguard"]
        guard required.allSatisfy({ manager.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the image helpers before checking icon conversion routes.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let source = work.appendingPathComponent("artwork.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 0.75))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 180))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: source)
        for ext in ["ico", "icns"] {
            let output = work.appendingPathComponent("generated.\(ext)")
            try engine.convert(source, to: output)
            let container = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(container), ext == "ico" ? 7 : 10)
            var widths: [Int] = []
            for index in 0..<CGImageSourceGetCount(container) {
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(container, index, nil))
                XCTAssertEqual(decoded.width, decoded.height)
                widths.append(decoded.width)
            }
            XCTAssertEqual(widths.sorted(), ext == "ico" ? [16,24,32,48,64,128,256] : [16,32,32,64,128,256,256,512,512,1024])
            let outputs = Set(engine.availableOutputs(for: output).map(\.id))
            XCTAssertTrue(Set(["png", "jpeg", "tiff", "webp", "jxl", "svg", "pdf", "ico", "icns"]).isSubset(of: outputs))
            XCTAssertEqual(engine.conversionRoute(from: output, to: try XCTUnwrap(engine.catalog.format(forExtension: "pdf")))?.map(\.id), ["png", "pdf"])
            for target in ["png", "jpg", "webp", "jxl", "svg", "pdf"] {
                try engine.convert(output, to: work.appendingPathComponent("returned-\(ext).\(target)"))
            }
            let png = try XCTUnwrap(CGImageSourceCreateWithURL(work.appendingPathComponent("returned-\(ext).png") as CFURL, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(png, 0, nil))
            XCTAssertEqual(decoded.width, ext == "ico" ? 256 : 1024)
            let bytes = try Data(contentsOf: output)
            XCTAssertThrowsError(try engine.convert(source, to: output))
            XCTAssertEqual(try Data(contentsOf: output), bytes)
        }
        let renamed = work.appendingPathComponent("artwork.ico")
        try manager.moveItem(at: source, to: renamed)
        let record = try engine.convertRenamedFile(from: source, to: renamed, historyDirectory: work.appendingPathComponent("history"))
        XCTAssertEqual(ImageConverter.detectedType(at: renamed), "com.microsoft.ico")
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let retained = Set(try manager.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix(".allomer-") })
        let timed = work.appendingPathComponent("timed.gif")
        let gif = try XCTUnwrap(CGImageDestinationCreateWithURL(timed as CFURL, "com.compuserve.gif" as CFString, 1, nil))
        CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(gif))
        let failed = work.appendingPathComponent("timed.ico")
        XCTAssertThrowsError(try engine.convert(timed, to: failed))
        XCTAssertFalse(manager.fileExists(atPath: failed.path))
        XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix(".allomer-") }), retained)
    }
}
