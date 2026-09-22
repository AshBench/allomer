import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import ConversionCore

final class AVIFTests: XCTestCase {
    func testBundledFallbackPreservesTransparency() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path),
              FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffprobe").path) else {
            throw XCTSkip("Build the media tools to check AVIF fallback encoding.")
        }
        let media = try MediaConverter(toolsDirectory: tools)
        guard AVIFConverter.isAvailable(in: media) else {
            throw XCTSkip("Build the media tools with libaom to check AVIF fallback encoding.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }

        let input = work.appendingPathComponent("input.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL,
            "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))

        let output = work.appendingPathComponent("output.avif")
        var options = ImageOptions()
        options.quality = 1
        try AVIFConverter.convert(input, to: output, media: media, options: options)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertFalse([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo))
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 6)
        var pixels = [UInt8](repeating: 0, count: 8 * 6 * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: 8, height: 6, bitsPerComponent: 8,
                bytesPerRow: 8 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        try XCTUnwrap(rendered).draw(decoded, in: CGRect(x: 0, y: 0, width: 8, height: 6))
        XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).allSatisfy { (127...129).contains(Int(pixels[$0])) })
    }
}
