import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import ConversionCore

final class AnimatedImageTests: XCTestCase {
    func testGIFDelayBlocks() throws {
        let options = try JSONDecoder().decode(ImageOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options.gifMaxColors, 256)
        XCTAssertTrue(options.gifDither)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GIF-delay-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let header = Array("GIF89a".utf8) + [1, 0, 1, 0, 128, 0, 0, 0, 0, 0, 255, 255, 255]
        let control: [UInt8] = [0x21, 0xf9, 4, 0, 0, 0, 0, 0]
        let frame: [UInt8] = [0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0]
        let valid = Data(header + control + frame + [0x3b])
        for delay in [0.0, 0.01, 0.17, 655.35] {
            try valid.write(to: url)
            try GIFEncoder.setDelays(url, delays: [delay])
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(Int(bytes[23]) | Int(bytes[24]) << 8, Int((delay * 100).rounded()))
        }
        for delays in [[], [0, 0], [-1], [.nan], [.infinity], [655.36]] as [[Double]] {
            try valid.write(to: url)
            XCTAssertThrowsError(try GIFEncoder.setDelays(url, delays: delays))
        }
        for count in 0..<valid.count {
            try valid.prefix(count).write(to: url)
            XCTAssertThrowsError(try GIFEncoder.setDelays(url, delays: [0]))
        }
        for malformed in [Data(header + control + control + frame + [0x3b]),
                          valid + Data([0]), Data(header + frame + [0x3b])] {
            try malformed.write(to: url)
            XCTAssertThrowsError(try GIFEncoder.setDelays(url, delays: [0]))
        }
    }
    func testAnimatedGIFTimingLoopsAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["ffmpeg", "cwebp", "webpguard", "webpanim", "webpanimguard"].allSatisfy({
            FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path)
        }) else {
            throw XCTSkip("Build the media and WebP tools to check animation.")
        }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Animation café \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let source = work.appendingPathComponent("original.png")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 3, nil))
        CGImageDestinationSetProperties(writer, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 2]] as CFDictionary)
        let delays = [0.04, 0.09, 0.17]
        for index in 0..<3 {
            let context = try XCTUnwrap(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index) / 2, green: 0.5, blue: 0.75, alpha: 1))
            context.fill(CGRect(x: index * 8, y: 4, width: 24, height: 24))
            let image = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(writer, image, [kCGImagePropertyPNGDictionary:
                [kCGImagePropertyAPNGDelayTime: delays[index], kCGImagePropertyAPNGUnclampedDelayTime: delays[index]]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: source)
        let engine = try ConversionEngine(toolsDirectory: tools)
        XCTAssertTrue(engine.availableOutputs(for: source).contains { $0.id == "gif" })
        XCTAssertFalse(engine.availableOutputs(for: source).contains { $0.id == "png" })
        var options = ImageOptions()
        options.preserveMetadata = false
        let output = work.appendingPathComponent("result.gif")
        options.gifMaxColors = 2
        options.gifDither = false
        try engine.convert(source, to: output, settings: .init(imageOptions: options))
        XCTAssertEqual(try Data(contentsOf: output).prefix(6), Data("GIF89a".utf8))
        let check = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(check), 3)
        let global = try XCTUnwrap(CGImageSourceCopyProperties(check, nil) as? [CFString: Any])
        XCTAssertEqual((global[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int, 2)
        for index in 0..<3 {
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(check, index, nil) as? [CFString: Any])
            let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            XCTAssertEqual(try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double), delays[index], accuracy: 0.000_001)
        }
        XCTAssertThrowsError(try engine.convert(source, to: output))
        let renamed = work.appendingPathComponent("original.gif")
        try manager.moveItem(at: source, to: renamed)
        let record = try engine.convertRenamedFile(from: source, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), settings: .init(imageOptions: options))
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(ImageConverter.detectedType(at: renamed), "com.compuserve.gif")
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(engine.availableOutputs(for: source).contains { $0.id == "webp" })
        options.webpMode = .lossless
        let renamedWebP = work.appendingPathComponent("original.webp")
        try manager.moveItem(at: source, to: renamedWebP)
        let webpRecord = try engine.convertRenamedFile(from: source, to: renamedWebP,
            historyDirectory: work.appendingPathComponent("webp-history"), settings: .init(imageOptions: options))
        let webpCheck = try XCTUnwrap(CGImageSourceCreateWithURL(renamedWebP as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(webpCheck) as String?, "org.webmproject.webp")
        XCTAssertEqual(CGImageSourceGetCount(webpCheck), 3)
        let webpGlobal = try XCTUnwrap(CGImageSourceCopyProperties(webpCheck, nil) as? [CFString: Any])
        XCTAssertEqual((webpGlobal[kCGImagePropertyWebPDictionary] as? [CFString: Any])?[kCGImagePropertyWebPLoopCount] as? Int, 2)
        for index in 0..<3 {
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(webpCheck, index, nil) as? [CFString: Any])
            let webp = try XCTUnwrap(properties[kCGImagePropertyWebPDictionary] as? [CFString: Any])
            XCTAssertEqual(try XCTUnwrap(webp[kCGImagePropertyWebPUnclampedDelayTime] as? Double), delays[index], accuracy: 0.000_001)
        }
        XCTAssertEqual(try ConversionEngine.undo(webpRecord).state, .undone)
        XCTAssertEqual(try Data(contentsOf: source), original)
        // A resample may skip frame zero when it has no duration. The GIF writer must size its
        // canvas from the first selected frame rather than the first source index.
        let selectedSource = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        let selectedAnimation = try XCTUnwrap(try AnimationFrames(source: selectedSource, type: "public.png"))
        try selectedAnimation.prepare(input: source, work: work, decoder: tools.appendingPathComponent("ffmpeg"))
        let selectedGIF = work.appendingPathComponent("selected.gif")
        try GIFEncoder.encode(source: selectedSource, animation: selectedAnimation, to: selectedGIF,
                              frameIndices: [1], delays: [0.1], loopCount: 1,
                              options: options, tool: tools.appendingPathComponent("ffmpeg"))
        XCTAssertEqual(CGImageSourceGetCount(try XCTUnwrap(CGImageSourceCreateWithURL(selectedGIF as CFURL, nil))), 1)
        // Resampling replaces the source's 0.04, 0.09, and 0.17 second delays with equal steps.
        var retimedOptions = options
        retimedOptions.animationFrameRate = 20
        retimedOptions.animationPlays = 4
        let retimed = work.appendingPathComponent("retimed.gif")
        try engine.convert(source, to: retimed, settings: .init(imageOptions: retimedOptions))
        let retimedCheck = try XCTUnwrap(CGImageSourceCreateWithURL(retimed as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(retimedCheck), 6)
        let retimedGlobal = try XCTUnwrap(CGImageSourceCopyProperties(retimedCheck, nil) as? [CFString: Any])
        XCTAssertEqual((retimedGlobal[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int, 4)
        for index in 0..<6 {
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(retimedCheck, index, nil) as? [CFString: Any])
            let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            XCTAssertEqual(try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double), 0.05, accuracy: 0.000_001)
        }
        let retimedWebP = work.appendingPathComponent("retimed.webp")
        try engine.convert(source, to: retimedWebP, settings: .init(imageOptions: retimedOptions))
        let retimedWebPCheck = try XCTUnwrap(CGImageSourceCreateWithURL(retimedWebP as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(retimedWebPCheck), 6)
        let retimedWebPGlobal = try XCTUnwrap(CGImageSourceCopyProperties(retimedWebPCheck, nil) as? [CFString: Any])
        XCTAssertEqual((retimedWebPGlobal[kCGImagePropertyWebPDictionary] as? [CFString: Any])?[kCGImagePropertyWebPLoopCount] as? Int, 4)
        for index in 0..<6 {
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(retimedWebPCheck, index, nil) as? [CFString: Any])
            let webp = try XCTUnwrap(properties[kCGImagePropertyWebPDictionary] as? [CFString: Any])
            XCTAssertEqual(try XCTUnwrap(webp[kCGImagePropertyWebPUnclampedDelayTime] as? Double), 0.05, accuracy: 0.000_001)
        }
        for invalid in [0.0, 0.5, 101.0, Double.nan] {
            var rejected = options
            rejected.animationFrameRate = invalid
            XCTAssertThrowsError(try engine.convert(source, to: work.appendingPathComponent("invalid-rate.gif"), settings: .init(imageOptions: rejected)))
        }
        XCTAssertThrowsError(try AnimationFrames.resampled(delays: Array(repeating: 1, count: 101), rate: 100))
        for width in [-1, 65_536] {
            var rejected = options
            rejected.animationMaxWidth = width
            for target in ["gif", "webp"] {
                XCTAssertThrowsError(try engine.convert(source,
                    to: work.appendingPathComponent("invalid-width-\(width).\(target)"), settings: .init(imageOptions: rejected)))
            }
        }
        // Saved settings without the new keys keep the source's own timing and repeats.
        let legacy = try JSONDecoder().decode(ImageOptions.self, from: Data("{\"quality\":0.5}".utf8))
        XCTAssertNil(legacy.animationFrameRate)
        XCTAssertNil(legacy.animationPlays)
        XCTAssertEqual(legacy.animationMaxWidth, 0)
        // A maximum width scales the 48 by 32 source frames down, keeping proportions.
        var scaledOptions = options
        scaledOptions.animationMaxWidth = 24
        let scaledGIF = work.appendingPathComponent("scaled.gif")
        try engine.convert(source, to: scaledGIF, settings: .init(imageOptions: scaledOptions))
        let scaledCheck = try XCTUnwrap(CGImageSourceCreateWithURL(scaledGIF as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(scaledCheck), 3)
        let scaledFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(scaledCheck, 0, nil))
        XCTAssertEqual(scaledFrame.width, 24)
        XCTAssertEqual(scaledFrame.height, 16)
        let scaledWebP = work.appendingPathComponent("scaled.webp")
        try engine.convert(source, to: scaledWebP, settings: .init(imageOptions: scaledOptions))
        let scaledWebPCheck = try XCTUnwrap(CGImageSourceCreateWithURL(scaledWebP as CFURL, nil))
        let scaledWebPFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(scaledWebPCheck, 0, nil))
        XCTAssertEqual(scaledWebPFrame.width, 24)
        XCTAssertEqual(scaledWebPFrame.height, 16)
        let single = work.appendingPathComponent("single.gif")
        let singleWriter = try XCTUnwrap(CGImageDestinationCreateWithURL(single as CFURL, "com.compuserve.gif" as CFString, 1, nil))
        CGImageDestinationAddImage(singleWriter, try XCTUnwrap(CGImageSourceCreateImageAtIndex(check, 0, nil)), nil)
        XCTAssertTrue(CGImageDestinationFinalize(singleWriter))
        let damaged = try Data(contentsOf: single).dropLast()
        let bad = work.appendingPathComponent("damaged.png")
        try damaged.write(to: bad)
        for target in ["png", "pdf", "txt", "html", "mp4", "webp"] {
            let rejected = work.appendingPathComponent("rejected.\(target)")
            XCTAssertThrowsError(try engine.convert(bad, to: rejected))
            XCTAssertFalse(manager.fileExists(atPath: rejected.path))
            XCTAssertEqual(try Data(contentsOf: bad), damaged)
        }
        let beforeRename = work.appendingPathComponent("damaged.gif")
        XCTAssertThrowsError(try engine.convertRenamedFile(from: beforeRename, to: bad,
            historyDirectory: work.appendingPathComponent("failed-history")))
        XCTAssertEqual(try Data(contentsOf: bad), damaged)
        XCTAssertFalse(manager.fileExists(atPath: beforeRename.path))
        try engine.convert(bad, to: work.appendingPathComponent("retained.zip"))
    }
}
