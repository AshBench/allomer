import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import ConversionCore

final class MediaOutputTests: XCTestCase {
    func testMediaOutputsWithInstalledTool() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["ffmpeg", "ffprobe"].allSatisfy({ FileManager.default.isExecutableFile(atPath:
            tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Configure the development FFmpeg tools to check the media adapter.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = try MediaConverter(toolsDirectory: tools)
        let engine = try ConversionEngine(toolsDirectory: tools)
        let audio = directory.appendingPathComponent("tone ' café.wav")
        let video = directory.appendingPathComponent("moving.mkv")
        var wav = Data()
        func append(_ value: some FixedWidthInteger) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + 96_000 * 4))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(2))
        append(UInt32(48_000))
        append(UInt32(48_000 * 4))
        append(UInt16(4))
        append(UInt16(16))
        wav.append(contentsOf: "data".utf8)
        append(UInt32(96_000 * 4))
        for index in 0..<96_000 {
            let sample = Int16(sin(Double(index) * 440 * 2 * .pi / 48_000) * 8192)
            append(sample)
            append(sample)
        }
        try wav.write(to: audio)
        let frames = directory.appendingPathComponent("original.yuv")
        XCTAssertTrue(FileManager.default.createFile(atPath: frames.path, contents: nil))
        let frameWriter = try FileHandle(forWritingTo: frames)
        for frame in 0..<50 {
            try frameWriter.write(contentsOf: Data(repeating: UInt8(16 + frame * 3), count: 720 * 576))
            try frameWriter.write(contentsOf: Data(repeating: 128, count: 720 * 576 / 2))
        }
        try frameWriter.close()
        try ExternalTool.run(media.ffmpeg, arguments: ["-v", "error", "-f", "rawvideo",
            "-pixel_format", "yuv420p", "-video_size", "720x576", "-framerate", "25", "-i", frames.path, "-i", audio.path,
            "-c:v", "mpeg4", "-threads", "2", "-c:a", "pcm_s16le", video.path], workDirectory: directory)
        let originalAudio = try Data(contentsOf: audio)
        let originalVideo = try Data(contentsOf: video)
        var tested = Set<String>()
        for format in engine.catalog.formats where media.supports(format.id) {
            let output = directory.appendingPathComponent("result.\(format.extensions[0])")
            do {
                try engine.convert(format.category == "audio" ? audio : video, to: output)
                let info = try media.inspect(output, work: directory)
                XCTAssertEqual(info.audio.count, 1, format.id)
                XCTAssertEqual(info.video.count, format.category == "video" ? 1 : 0, format.id)
                XCTAssertGreaterThan(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0, format.id)
                // Decode the full result so a valid header cannot hide corrupt media packets.
                try ExternalTool.run(media.ffmpeg, arguments: ["-v", "error", "-xerror",
                    "-protocol_whitelist", "file,pipe", "-i", output.path, "-f", "null", "-"], workDirectory: directory)
                tested.insert(format.id)
                XCTAssertEqual(try engine.detectedFormat(at: output)?.id, format.id, "Named \(format.id)")
                let misnamed = directory.appendingPathComponent("detect-\(format.id).wrong")
                try FileManager.default.copyItem(at: output, to: misnamed)
                // A VOB has the same container signature as an MPEG program stream.
                XCTAssertEqual(try engine.detectedFormat(at: misnamed)?.id,
                               format.id == "vob" ? "mpeg" : format.id, "Misnamed \(format.id)")
                if format.category == "video" {
                    var animation = ImageOptions()
                    animation.videoMaxWidth = 90
                    animation.videoFrameRate = 5
                    for target in ["gif", "webp"] {
                        let converted = directory.appendingPathComponent("from-\(format.id).\(target)")
                        try engine.convert(output, to: converted, settings: .init(imageOptions: animation))
                        let source = try XCTUnwrap(CGImageSourceCreateWithURL(converted as CFURL, nil))
                        XCTAssertGreaterThan(CGImageSourceGetCount(source), 0, format.id)
                    }
                }
            } catch {
                XCTFail("\(format.id): \(error.localizedDescription)")
            }
        }
        XCTAssertEqual(tested, Set(engine.catalog.formats
            .filter { ["audio", "video"].contains($0.category) }.map(\.id)))
        var preserveOptions = ImageOptions()
        preserveOptions.videoPreserveFrameRate = true
        preserveOptions.videoMaxWidth = 90
        preserveOptions.videoGIFColors = 16
        for target in ["gif", "webp"] {
            let preserved = directory.appendingPathComponent("preserved.\(target)")
            try engine.convert(video, to: preserved, settings: .init(imageOptions: preserveOptions))
            let animated = try XCTUnwrap(CGImageSourceCreateWithURL(preserved as CFURL, nil))
            // The fixture is 50 frames at 25 fps, so preserved timing keeps every frame at 0.04 seconds.
            XCTAssertEqual(CGImageSourceGetCount(animated), 50, target)
            let keys = try XCTUnwrap(AnimationFrames.keys(try XCTUnwrap(CGImageSourceGetType(animated) as String?)))
            for index in 0..<50 {
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(animated, index, nil) as? [CFString: Any])
                let frame = try XCTUnwrap(properties[keys.dictionary] as? [CFString: Any])
                let delay = frame[keys.unclamped] as? Double ?? frame[keys.delay] as? Double
                XCTAssertEqual(try XCTUnwrap(delay), 0.04, accuracy: 0.002, "\(target) frame \(index)")
            }
        }
        var animationOptions = ImageOptions()
        animationOptions.videoFrameRate = 12.5
        animationOptions.videoMaxWidth = 180
        animationOptions.videoLoopCount = 2
        animationOptions.videoGIFColors = 16
        animationOptions.videoGIFDither = false
        animationOptions.webpMode = .lossless
        for target in ["gif", "webp"] {
            XCTAssertTrue(engine.availableOutputs(for: video).contains { $0.id == target })
            let renamed = directory.appendingPathComponent("moving.\(target)")
            try FileManager.default.moveItem(at: video, to: renamed)
            let record = try engine.convertRenamedFile(from: video, to: renamed,
                historyDirectory: directory.appendingPathComponent("history-\(target)"), settings: .init(imageOptions: animationOptions))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(renamed as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 25)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 180)
            XCTAssertEqual(image.height, 144)
            let keys = try XCTUnwrap(AnimationFrames.keys(try XCTUnwrap(CGImageSourceGetType(source) as String?)))
            let properties = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
            XCTAssertEqual((properties[keys.dictionary] as? [CFString: Any])?[keys.loop] as? Int, 2)
            XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
            XCTAssertEqual(try Data(contentsOf: video), originalVideo)
            try FileManager.default.removeItem(at: record.backupURL.deletingLastPathComponent())
        }
        let lossless = directory.appendingPathComponent("result.flac")
        let pcm = try ExternalTool.run(media.ffmpeg, arguments: ["-v", "error", "-i", lossless.path,
            "-f", "s16le", "-"], workDirectory: directory, captureOutput: true)
        let sourcePCM = try ExternalTool.run(media.ffmpeg, arguments: ["-v", "error", "-i", audio.path,
            "-f", "s16le", "-"], workDirectory: directory, captureOutput: true)
        XCTAssertEqual(pcm, sourcePCM)
        XCTAssertEqual(try Data(contentsOf: audio), originalAudio)
        XCTAssertEqual(try Data(contentsOf: video), originalVideo)
        XCTAssertThrowsError(try engine.convert(audio, to: lossless))
        var invalid = MediaOptions()
        invalid.channels = 0
        XCTAssertThrowsError(try engine.convert(audio, to: directory.appendingPathComponent("invalid.mp3"), settings: .init(mediaOptions: invalid)))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.hasPrefix(".allomer-") })
    }
}
