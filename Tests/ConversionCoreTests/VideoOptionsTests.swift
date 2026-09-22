import Foundation
import XCTest
@testable import ConversionCore

final class VideoOptionsTests: XCTestCase {
    func testSonomaVideoToolboxQualityFallback() {
        var options = MediaOptions()
        for (quality, rate) in [(0.0, 32), (50.0, 1_789), (100.0, 100_000)] {
            options.videoQuality = quality
            XCTAssertEqual(MediaConverter.videoRateArguments(codec: "h264_videotoolbox",
                options: options, macOSMajorVersion: 14), ["-b:v", "\(rate)k"])
        }
        options.videoQuality = 75
        XCTAssertEqual(MediaConverter.videoRateArguments(codec: "hevc_videotoolbox",
            options: options, macOSMajorVersion: 15), ["-q:v", "75"])
        options.videoMode = .bitrate
        options.videoBitrateKbps = 4_200
        XCTAssertEqual(MediaConverter.videoRateArguments(codec: "h264_videotoolbox",
            options: options, macOSMajorVersion: 14), ["-b:v", "4200k"])
    }

    func testAudioVideoTimingAndResampledClocks() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("source"), result = work.appendingPathComponent("result")
        func track(_ stream: Int, _ points: [Int], duration: Int, rate: Int) -> String {
            "#tb \(stream): 1/\(rate)\n" + points.map { "\(stream), \($0), \($0), \(duration), 424, 0x123\n" }.joined()
        }
        let video = track(0, [0, 40, 80], duration: 40, rate: 1000)
        let audio = track(1, [0, 1920, 3840], duration: 1920, rate: 48000)
        try Data((video + audio).utf8).write(to: source)
        func check(_ text: String, padding: Double = 0) throws {
            try Data(text.utf8).write(to: result)
            try MediaTiming.compare(source: source, result: result, rate: .preserveSource,
                estimatesFinalDuration: false, usesFrameClock: false, audioPadding: padding)
        }
        try check(video + track(1, [0, 1764, 3528], duration: 1764, rate: 44100))
        try check(track(0, [1400, 1440, 1480], duration: 40, rate: 1000)
            + track(1, [67200, 69120, 71040], duration: 1920, rate: 48000))
        XCTAssertThrowsError(try check(video + track(1, [4800, 6720, 8640], duration: 1920, rate: 48000)))
        XCTAssertThrowsError(try check(video + track(1, [0, 1920], duration: 1920, rate: 48000)))
        XCTAssertThrowsError(try check(video + track(1, [0, 1920, 3840], duration: 1980, rate: 48000)))
        XCTAssertThrowsError(try check(video))
        XCTAssertThrowsError(try check(video + audio, padding: .nan))
        XCTAssertThrowsError(try check(video + audio, padding: -1))
        // Encoder padding can affect both ends of the decoded sample count.
        try check(video + track(1, [-480, 1440, 3360, 5280], duration: 1920, rate: 48000), padding: 0.03)
    }

    func testAutomaticVideoSettingsAndExactUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["ffmpeg", "ffprobe"].allSatisfy({ FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the media helpers before checking video conversion and undo.")
        }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Video Undo \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let raw = work.appendingPathComponent("original.rgb")
        try Data(repeating: 77, count: 128 * 72 * 3 * 12).write(to: raw)
        let sound = work.appendingPathComponent("original.s16le")
        try Data(repeating: 18, count: 48_000).write(to: sound)
        let source = work.appendingPathComponent("original.mkv")
        try ExternalTool.run(tools.appendingPathComponent("ffmpeg"), arguments: [
            "-v", "error", "-nostdin", "-n", "-f", "rawvideo", "-pixel_format", "rgb24",
            "-video_size", "128x72", "-framerate", "24", "-i", raw.path,
            "-itsoffset", "0.125", "-f", "s16le", "-ar", "48000", "-ac", "1", "-i", sound.path,
            "-map", "0:v:0", "-map", "1:a:0", "-c:a", "pcm_s16le",
            "-c:v", "ffv1", "-pix_fmt", "yuv420p", source.path], workDirectory: work)
        let original = try Data(contentsOf: source)
        let engine = try ConversionEngine(toolsDirectory: tools)
        var settings = MediaOptions()
        settings.videoCodec = .prores
        settings.proResProfile = .rgba4444
        settings.videoFrameRate = .fps30
        for target in ["mov", "avi"] {
            if target == "avi" { settings.videoCodec = .automatic }
            let renamed = work.appendingPathComponent("original.\(target)")
            try manager.moveItem(at: source, to: renamed)
            let record = try engine.convertRenamedFile(from: source, to: renamed,
                historyDirectory: work.appendingPathComponent("history"), settings: .init(mediaOptions: settings))
            let info = try MediaConverter(toolsDirectory: tools).inspect(renamed, work: work)
            XCTAssertEqual(info.video.first?.codec_name, target == "mov" ? "prores" : "mpeg4")
            XCTAssertEqual(info.video.first?.pix_fmt, target == "mov" ? "yuva444p12le" : "yuv420p")
            XCTAssertEqual(info.audio.count, 1)
            XCTAssertEqual(try Data(contentsOf: record.backupURL), original)
            XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertFalse(manager.fileExists(atPath: renamed.path))
            try manager.removeItem(at: record.backupURL.deletingLastPathComponent())
        }
        // FFV1 is lossless. MKV accepts it, and neither quality nor bitrate mode changes the result.
        let intermediate = work.appendingPathComponent("intermediate.avi")
        try engine.convert(source, to: intermediate)
        func decodedPixels(_ file: URL) throws -> Data {
            try ExternalTool.run(tools.appendingPathComponent("ffmpeg"), arguments: [
                "-v", "error", "-i", file.path, "-map", "0:V:0", "-an", "-pix_fmt", "yuv420p",
                "-fps_mode", "passthrough", "-f", "rawvideo", "-"
            ], workDirectory: work, captureOutput: true)
        }
        let expectedPixels = try decodedPixels(intermediate)
        var lossless = MediaOptions()
        lossless.videoCodec = .ffv1
        for mode in [MediaEncodingMode.quality, .bitrate] {
            lossless.videoMode = mode
            let output = work.appendingPathComponent("lossless-\(mode.rawValue).mkv")
            try engine.convert(intermediate, to: output, settings: .init(mediaOptions: lossless))
            let info = try MediaConverter(toolsDirectory: tools).inspect(output, work: work)
            XCTAssertEqual(info.video.first?.codec_name, "ffv1", mode.rawValue)
            XCTAssertEqual(try decodedPixels(output), expectedPixels, mode.rawValue)
        }
        // Containers that cannot carry it refuse the conversion and leave no output.
        for target in ["mp4", "mov", "webm", "avi"] {
            let refused = work.appendingPathComponent("refused.\(target)")
            XCTAssertThrowsError(try engine.convert(intermediate, to: refused, settings: .init(mediaOptions: lossless)), target)
            XCTAssertFalse(manager.fileExists(atPath: refused.path), target)
        }
        XCTAssertEqual(try JSONDecoder().decode(MediaOptions.self,
            from: Data(#"{"videoCodec":"ffv1"}"#.utf8)).videoCodec, .ffv1)
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: work.path).contains { $0.hasPrefix(".allomer-") })
    }

    func testSavedSettingsAndTimelineValidation() throws {
        let legacy = try JSONDecoder().decode(MediaOptions.self, from: Data(#"{"videoBitrateKbps":1800}"#.utf8))
        XCTAssertEqual(legacy.videoMode, .bitrate)
        XCTAssertEqual(legacy.videoBitrateKbps, 1800)
        XCTAssertEqual(try JSONDecoder().decode(MediaOptions.self, from: Data("{}".utf8)), MediaOptions())
        let settings = try JSONDecoder().decode(MediaOptions.self, from: Data(#"{"videoCodec":"av1","videoMode":"quality","videoQuality":57,"videoFrameRate":"24000/1001","vp9Speed":6,"av1Speed":10,"proResProfile":5}"#.utf8))
        XCTAssertEqual(try JSONDecoder().decode(MediaOptions.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertEqual(settings.videoMode, .quality)
        XCTAssertEqual(settings.videoFrameRate.value!, 24000.0 / 1001, accuracy: 0.000_001)

        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("source.txt"), result = work.appendingPathComponent("result.txt")
        func timeline(_ points: [Int64], duration: Int64 = 41, clock: String = "1/1000") -> String {
            "#tb 0: \(clock)\n" + points.map { "0, \($0), \($0), \(duration), 424, 0x0123\n" }.joined()
        }
        let points: [Int64] = [0, 125, 250, 300, 425, 550, 600, 725]
        try Data(timeline(points).utf8).write(to: source)
        func check(_ text: String, rate: VideoFrameRate = .preserveSource, estimated: Bool = false) throws {
            try Data(text.utf8).write(to: result)
            try MediaTiming.compare(source: source, result: result, rate: rate,
                estimatesFinalDuration: estimated, usesFrameClock: false)
        }
        // A container origin changes no frame intervals.
        try check(timeline(points.map { $0 + 1400 }))
        try check(timeline(points, duration: 25), estimated: true)
        XCTAssertThrowsError(try check(timeline(points, duration: 25)))
        XCTAssertThrowsError(try check(timeline(points, duration: 200), estimated: false))
        XCTAssertThrowsError(try check(timeline(points, duration: 200), estimated: true))
        try check(timeline((0..<19).map { Int64($0) }, duration: 1, clock: "1/24"), rate: .fps24)
        XCTAssertThrowsError(try check(timeline((0..<16).map { Int64($0) }, duration: 1, clock: "1/24"), rate: .fps24))
        for invalid in [
            timeline(Array(points.dropLast())), timeline(points + [800]),
            timeline([0, 125, 250, 320, 425, 550, 600, 725]), timeline([0, 0]),
            timeline(points, duration: 0), timeline(points, clock: "1/0"),
            timeline(points, clock: "-1/1000"), timeline(points, clock: "1/2147483648"),
            timeline([Int64.min]), timeline([Int64.min + 1, Int64.max]),
            "#tb 0: 1/1000\n" + timeline(points), String(timeline(points).dropLast()),
            "#tb 0: 1/1000\n1, 0, 0, 41, 424, 0x0123\n", "#" + String(repeating: "x", count: 4097) + "\n"
        ] {
            XCTAssertThrowsError(try check(invalid), invalid.prefix(150).description)
        }
        let longPoints = (0..<5000).map { Int64($0) * 42 }
        try Data(timeline(longPoints).utf8).write(to: source)
        try check(timeline(longPoints.map { $0 + 1400 }))
        let large = try FileHandle(forWritingTo: result)
        try large.truncate(atOffset: UInt64(MediaTiming.byteLimit + 1))
        try large.close()
        XCTAssertThrowsError(try MediaTiming.compare(source: source, result: result, rate: .preserveSource,
            estimatesFinalDuration: false, usesFrameClock: false))
    }

    func testOlderCodecsAreSelectableOnlyWhereTheyAreValid() throws {
        XCTAssertEqual(try JSONDecoder().decode(MediaOptions.self,
            from: Data(#"{"videoCodec":"mpeg2video"}"#.utf8)).videoCodec, .mpeg2video)
        XCTAssertEqual(try JSONDecoder().decode(MediaOptions.self,
            from: Data(#"{"videoCodec":"msmpeg4"}"#.utf8)).videoCodec, .msmpeg4)
        XCTAssertEqual(VideoCodec.mpeg2video.title, "MPEG-2")
        XCTAssertEqual(VideoCodec.msmpeg4.title, "MS MPEG-4 v3")
        // Every pair below was first confirmed to mux with the bundled encoder.
        for container in ["mkv", "avi", "mxf", "mpeg", "vob", "ts", "m2ts"] {
            XCTAssertTrue(VideoCodec.choices(for: container).contains(.mpeg2video), container)
        }
        for container in ["mkv", "avi", "wmv"] {
            XCTAssertTrue(VideoCodec.choices(for: container).contains(.msmpeg4), container)
        }
        for container in ["mp4", "mov", "webm", "3gp", "flv"] {
            XCTAssertFalse(VideoCodec.choices(for: container).contains(.mpeg2video), container)
            XCTAssertFalse(VideoCodec.choices(for: container).contains(.msmpeg4), container)
        }
        // Containers that carry only one codec keep their single choice.
        XCTAssertEqual(VideoCodec.choices(for: "wmv"), [.automatic, .msmpeg4])
        XCTAssertEqual(VideoCodec.choices(for: "3gp"), [.automatic, .h264])
    }

    func testAnIncompleteInstallIsRejectedIncludingMissingResources() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let helpers = root.appendingPathComponent("Contents/Helpers")
        try manager.createDirectory(at: helpers, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        XCTAssertNil(ConversionEngine.toolsDirectory(in: root), "An empty bundle must be rejected.")
        // The same gate, called on a plain directory: this is what the command checks for an
        // explicit tools directory or a development build, neither of which is inside a bundle.
        XCTAssertFalse(ConversionEngine.isCompleteToolsDirectory(helpers))

        let names = ["carta", "ffmpeg", "ffprobe", "tabular", "mobitool", "fontconvert", "fontguard", "mailfile", "modeltool",
                     "gs", "postscript", "pdftops", "psguard", "mutool", "pdfguard", "nativeconvert",
                     "nativeguard", "webconvert", "webguard", "cwebp", "webpguard", "webpanim",
                     "webpanimguard", "cjxl", "jxlguard", "tiffcp", "tiffguard", "vectortrace", "traceguard"]
        for name in names {
            let file = helpers.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        // Every executable present, but the resources two capabilities need are not. This is the
        // case the gate used to accept, after which presentation and PostScript output vanished
        // from the offered formats with nothing said.
        XCTAssertNil(ConversionEngine.toolsDirectory(in: root), "Missing resources must be rejected too.")

        let presentation = helpers.deletingLastPathComponent().appendingPathComponent("Resources/Presentation")
        try manager.createDirectory(at: presentation, withIntermediateDirectories: true)
        try Data("// renderer".utf8).write(to: presentation.appendingPathComponent("renderer.js"))
        XCTAssertNil(ConversionEngine.toolsDirectory(in: root), "The Word renderer is still missing.")

        let word = helpers.deletingLastPathComponent().appendingPathComponent("Resources/Word")
        try manager.createDirectory(at: word, withIntermediateDirectories: true)
        try Data("// renderer".utf8).write(to: word.appendingPathComponent("renderer.js"))
        XCTAssertNil(ConversionEngine.toolsDirectory(in: root), "The PostScript font is still missing.")

        // PostScriptConverter.resources builds Contents/Resources/Poppler, which is where the real
        // bundle keeps this font.
        let fonts = helpers.deletingLastPathComponent().appendingPathComponent("Resources/Poppler/fonts")
        try manager.createDirectory(at: fonts, withIntermediateDirectories: true)
        try Data("font".utf8).write(to: fonts.appendingPathComponent("n019003l.pfb"))
        // Compare paths, not URLs: appendingPathComponent marks an existing directory as one,
        // so the same folder can produce URLs that differ only by a trailing slash.
        XCTAssertEqual(ConversionEngine.toolsDirectory(in: root)?.standardizedFileURL.path,
                       helpers.standardizedFileURL.path, "A complete bundle is accepted.")
        XCTAssertTrue(ConversionEngine.isCompleteToolsDirectory(helpers))
        let renderer = presentation.appendingPathComponent("renderer.js")
        try manager.removeItem(at: renderer)
        try manager.createDirectory(at: renderer, withIntermediateDirectories: false)
        XCTAssertNil(ConversionEngine.toolsDirectory(in: root), "A resource path must be a nonempty regular file.")
    }
}
