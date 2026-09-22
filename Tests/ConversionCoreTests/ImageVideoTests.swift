import AVFoundation
import Foundation
import ImageIO
import XCTest
@testable import ConversionCore

final class ImageVideoTests: XCTestCase {
    func testImageVideoRoutesOrientationPaddingAndUndo() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Image video \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["ffmpeg", "ffprobe"].allSatisfy({ manager.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the media helpers before checking image-to-video conversion.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let media = try MediaConverter(toolsDirectory: tools)
        let context = try XCTUnwrap(CGContext(data: nil, width: 65, height: 49, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 65, height: 49))
        let image = try XCTUnwrap(context.makeImage())
        let source = work.appendingPathComponent("artwork.png")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: source)
        let formats = engine.catalog.formats.filter { $0.category == "video" }
        XCTAssertEqual(formats.count, 13)
        for format in formats {
            XCTAssertEqual(engine.conversionRoute(from: source, to: format)?.map(\.id), ["gif", format.id])
        }
        var options = ImageOptions()
        options.preserveMetadata = false
        options.gifMaxColors = 16
        options.gifDither = false
        let renamed = work.appendingPathComponent("artwork.mp4")
        try manager.moveItem(at: source, to: renamed)
        let record = try engine.convertRenamedFile(from: source, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), settings: .init(imageOptions: options))
        let info = try media.inspect(renamed, work: work)
        XCTAssertEqual(info.video.first?.width, 50)
        XCTAssertEqual(info.video.first?.height, 66)
        XCTAssertEqual(try XCTUnwrap(info.format.duration.flatMap(Double.init)), 0.1, accuracy: 0.001)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: renamed))
        let (frame, _) = try await generator.image(at: .zero)
        let pixel = try XCTUnwrap(CGContext(data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixel.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        let bytes = try XCTUnwrap(pixel.data).assumingMemoryBound(to: UInt8.self)
        let center = (frame.height / 2) * pixel.bytesPerRow + (frame.width / 2) * 4
        for (index, expected) in [204, 51, 26].enumerated() {
            XCTAssertLessThanOrEqual(abs(Int(bytes[center + index]) - expected), 6, "Native video playback changed the color")
        }
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(manager.fileExists(atPath: renamed.path))

        let pages = work.appendingPathComponent("pages.tiff")
        let tiff = try XCTUnwrap(CGImageDestinationCreateWithURL(pages as CFURL, "public.tiff" as CFString, 2, nil))
        for _ in 0..<2 { CGImageDestinationAddImage(tiff, image, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(tiff))
        XCTAssertFalse(engine.availableOutputs(for: pages).contains { $0.category == "video" })

        let raw = work.appendingPathComponent("odd.rgb")
        try Data(repeating: 100, count: 65 * 49 * 3 * 2).write(to: raw)
        let video = work.appendingPathComponent("odd.mkv")
        try ExternalTool.run(media.ffmpeg, arguments: ["-v", "error", "-f", "rawvideo", "-pixel_format", "rgb24",
            "-video_size", "65x49", "-framerate", "25", "-i", raw.path, "-c:v", "ffv1", "-f", "matroska", video.path], workDirectory: work)
        let output = work.appendingPathComponent("padded.mp4")
        try engine.convert(video, to: output)
        let padded = try media.inspect(output, work: work)
        XCTAssertEqual(padded.video.first?.width, 66)
        XCTAssertEqual(padded.video.first?.height, 50)
        try ExternalTool.run(media.ffmpeg, arguments: ["-v", "error", "-xerror", "-i", output.path,
            "-f", "null", "-"], workDirectory: work)
    }
}
