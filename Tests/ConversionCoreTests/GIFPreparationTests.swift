import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import ConversionCore

final class GIFPreparationTests: XCTestCase {
    func testLargeGIFPreparationColorTimingAndAutomaticUndo() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("GIF reader \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["ffmpeg", "ffprobe"].allSatisfy({ manager.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the media helpers before checking GIF preparation.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let png = work.appendingPathComponent("flat.png")
        let gif = work.appendingPathComponent("flat.gif")
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 3072, height: 3072, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: CGFloat(30) / 255, green: CGFloat(100) / 255, blue: CGFloat(200) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3072, height: 3072))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        try engine.convert(png, to: gif)
        let metadata = try GIFMetadata(gif)
        XCTAssertEqual([metadata.width, metadata.height, metadata.frames.count, metadata.plays], [3072, 3072, 1, 1])

        let original = try Data(contentsOf: gif)
        let renamed = work.appendingPathComponent("flat.tiff")
        try manager.moveItem(at: gif, to: renamed)
        let record = try engine.convertRenamedFile(from: gif, to: renamed, historyDirectory: work.appendingPathComponent("history"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(renamed as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual([image.width, image.height], [3072, 3072])
        let sample = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sample.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let bytes = try XCTUnwrap(sample.data).assumingMemoryBound(to: UInt8.self)
        for (index, expected) in [30, 100, 200].enumerated() { XCTAssertLessThanOrEqual(abs(Int(bytes[index]) - expected), 1) }
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: gif), original)
        XCTAssertFalse(manager.fileExists(atPath: renamed.path))

        try GIFEncoder.setDelays(gif, delays: [0.17])
        var animated = try Data(contentsOf: gif)
        let insertion = Int(try XCTUnwrap(metadata.frames[0].controlOffset)) - 4
        let profile = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData()) as Data
        var application = Data([0x21, 0xff, 11]) + Data("ICCRGBG1012".utf8)
        for offset in stride(from: 0, to: profile.count, by: 255) {
            let part = profile.subdata(in: offset..<min(profile.count, offset + 255))
            application.append(UInt8(part.count)); application.append(part)
        }
        application.append(0)
        application.append(Data([0x21, 0xff, 11]) + Data("NETSCAPE2.0".utf8) + Data([3, 1, 2, 0, 0]))
        animated.insert(contentsOf: application, at: insertion)
        var comment = Data([0x21, 0xfe])
        for _ in 0..<300 { comment.append(255); comment.append(Data(repeating: 65, count: 255)) }
        comment.append(0)
        animated.insert(contentsOf: comment, at: animated.count - 1)
        try animated.write(to: gif)
        let tagged = try GIFMetadata(gif)
        XCTAssertEqual(tagged.profile, profile)
        XCTAssertEqual(tagged.plays, 3)
        XCTAssertEqual(tagged.frames[0].delay, 0.17)
        let videoInput = try XCTUnwrap(GIFPreparation.prepareVideo(gif, metadata: tagged, work: work))
        var actual = try Data(contentsOf: videoInput), unchanged = animated
        let removed = try XCTUnwrap(tagged.profileRange)
        for range in tagged.paletteRanges {
            unchanged.replaceSubrange(Int(range.lowerBound)..<Int(range.upperBound), with: repeatElement(UInt8(0), count: range.count))
            let shift = range.lowerBound >= removed.upperBound ? removed.count : 0
            actual.replaceSubrange((Int(range.lowerBound) - shift)..<(Int(range.upperBound) - shift),
                with: repeatElement(UInt8(0), count: range.count))
        }
        unchanged.removeSubrange(Int(removed.lowerBound)..<Int(removed.upperBound))
        XCTAssertEqual(actual, unchanged, "Color preparation changed bytes outside the palettes and ICC block")
        XCTAssertNil(try GIFMetadata(videoInput).profile)
        try manager.removeItem(at: videoInput)
        let video = work.appendingPathComponent("profile.mp4")
        try manager.moveItem(at: gif, to: video)
        let videoRecord = try engine.convertRenamedFile(from: gif, to: video, historyDirectory: work.appendingPathComponent("history"))
        _ = try ConversionEngine.undo(videoRecord)
        XCTAssertEqual(try Data(contentsOf: gif), animated)
        XCTAssertFalse(manager.fileExists(atPath: video.path))
        let native = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(native, 0, nil) as? [CFString: Any]
        let prepared = try GIFPreparation.prepare(gif, tools: tools, work: work)
        if properties?[kCGImagePropertyPixelWidth] == nil { XCTAssertNotNil(prepared) }
        if let prepared {
            let check = try XCTUnwrap(CGImageSourceCreateWithURL(prepared as CFURL, nil))
            let animation = try XCTUnwrap(AnimationFrames(source: check, type: "public.png"))
            XCTAssertEqual(animation.loopCount, 3)
            XCTAssertEqual(try XCTUnwrap(animation.delays.first), 0.17, accuracy: 0.000_001)
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(check, 0, nil))
            XCTAssertEqual(frame.colorSpace?.name, CGColorSpace.displayP3)
            try manager.removeItem(at: prepared)
        }
        XCTAssertEqual(try Data(contentsOf: gif), animated)
        let sparse = work.appendingPathComponent("oversized.gif")
        try Data("GIF89a".utf8).write(to: sparse)
        let file = try FileHandle(forWritingTo: sparse)
        try file.truncate(atOffset: 536_870_913)
        try file.close()
        XCTAssertThrowsError(try GIFPreparation.prepare(sparse, tools: tools, work: work))
        try manager.removeItem(at: sparse)
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: work.path).contains {
            $0.hasPrefix("gif-reader-") || $0.hasPrefix("gif-input-") || $0.hasPrefix("gif-video-")
        })
    }
}
