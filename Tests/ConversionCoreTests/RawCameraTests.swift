import Foundation
import ImageIO
import XCTest
@testable import ConversionCore

final class RawCameraTests: XCTestCase {
    func testCameraRAWAutomaticConversionAndUndo() throws {
        guard let path = ProcessInfo.processInfo.environment["ALLOMER_RAW_FIXTURES"] else {
            throw XCTSkip("Set ALLOMER_RAW_FIXTURES after tools/check-raw.py --download.")
        }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Camera RAW \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = try ConversionEngine(toolsDirectory: root.appendingPathComponent(".tools/bin"))
        struct Sample: Decodable { let file: String; let sha256: String; let pixels: [Int] }
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: root.appendingPathComponent("tools/raw-samples.json")))
        for sample in samples {
            let fixture = URL(fileURLWithPath: path).appendingPathComponent(sample.file)
            XCTAssertEqual(try fileHash(fixture), sample.sha256)
            let source = work.appendingPathComponent(sample.file)
            try cloneSource(fixture, to: source)
            let outputs = Set(engine.availableOutputs(for: source).map(\.id))
            XCTAssertTrue(Set(["png", "jpeg", "tiff", "gif", "heic", "avif", "webp", "jxl", "svg", "pdf", "ico", "icns", "mp4"]).isSubset(of: outputs))
            let renamed = work.appendingPathComponent(sample.file + ".jpg")
            try manager.moveItem(at: source, to: renamed)
            XCTAssertEqual(try engine.detectedFormat(at: renamed)?.id, engine.catalog.format(for: source)?.id, sample.file)
            let record = try engine.convertRenamedFile(from: source, to: renamed, historyDirectory: work.appendingPathComponent("history"))
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(renamed as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(image) as String?, "public.jpeg")
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
            XCTAssertEqual([decoded.width, decoded.height], sample.pixels)
            _ = try ConversionEngine.undo(record)
            XCTAssertEqual(try fileHash(source), sample.sha256)
            XCTAssertFalse(manager.fileExists(atPath: renamed.path))
            XCTAssertEqual(try fileHash(fixture), sample.sha256)
        }
    }

    func testCameraTagsDoNotTurnTIFFIntoRAW() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Camera TIFF \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 41, height: 31, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 41, height: 31))
        let image = try XCTUnwrap(context.makeImage())
        for (index, camera) in [("NIKON CORPORATION", "NIKON D90"), ("SONY", "NEX-5"), ("PENTAX Corporation", "PENTAX K10D")].enumerated() {
            let source = work.appendingPathComponent("ordinary-\(index).jpg")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.tiff" as CFString, 2, nil))
            let properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: camera.0, kCGImagePropertyTIFFModel: camera.1]]
            for _ in 0..<2 { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let detected = try XCTUnwrap(ImageConverter.inspect(source))
            XCTAssertEqual(detected.type, "public.tiff")
            XCTAssertEqual(detected.frames, 2)
            XCTAssertEqual(try ConversionEngine().detectedFormat(at: source)?.id, "tiff")
            XCTAssertNil(try ImageConverter.prepareInput(source, type: detected.type, work: work))
        }
    }
}
