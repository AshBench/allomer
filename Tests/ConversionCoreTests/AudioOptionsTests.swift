import Foundation
import XCTest
@testable import ConversionCore

final class AudioOptionsTests: XCTestCase {
    func testDecodedAudioTimingAndAutomaticExtraction() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Audio timing \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let sourceTiming = work.appendingPathComponent("source.txt"), resultTiming = work.appendingPathComponent("result.txt")
        func timeline(_ points: [Int], duration: Int = 4800, rate: Int = 48000) -> String {
            "#tb 0: 1/\(rate)\n" + points.map { "0, \($0), \($0), \(duration), 9600, 0x123\n" }.joined()
        }
        try Data(timeline([0, 4800, 9600]).utf8).write(to: sourceTiming)
        func check(_ text: String, padding: Double? = 0, declared: Double? = nil) throws {
            try Data(text.utf8).write(to: resultTiming)
            try MediaTiming.compare(source: sourceTiming, result: resultTiming, rate: .preserveSource,
                estimatesFinalDuration: false, usesFrameClock: false, audioPadding: padding,
                includeVideo: false, sourceDuration: declared)
        }
        try check(timeline([0, 4410, 8820], duration: 4410, rate: 44100))
        try check(timeline([240000, 244800, 249600]))
        try check(timeline([0, 4800, 9600, 14400]), padding: 0.05)
        XCTAssertThrowsError(try check(timeline([0, 4800])))
        XCTAssertThrowsError(try check(timeline([0, 4800, 9600, 14400])))
        XCTAssertThrowsError(try check(timeline([0, 5000, 9800])))
        XCTAssertThrowsError(try check(timeline([0, 0, 9600])))
        XCTAssertThrowsError(try check(timeline([0, 4800, 9600]), padding: nil))
        XCTAssertThrowsError(try check(timeline([0, 4800, 9600]), padding: .infinity))
        try check(timeline([0, 4800, 9600]), declared: 0.3)
        XCTAssertThrowsError(try check(timeline([0, 4800, 9600]), declared: 0.4))
        XCTAssertThrowsError(try check(timeline([0, 4800, 9600]), declared: .nan))

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["ffmpeg", "ffprobe"].allSatisfy({ FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the media helpers before checking decoded audio timing.")
        }
        let raw = work.appendingPathComponent("original.s16le")
        // Two seconds of original mono samples, with a timestamp-only pause halfway through.
        let samples = Data(repeating: 19, count: 48000 * 2 * 2)
        try samples.write(to: raw)
        let source = work.appendingPathComponent("original.mka")
        try ExternalTool.run(tools.appendingPathComponent("ffmpeg"), arguments: [
            "-v", "error", "-nostdin", "-n", "-copyts", "-f", "s16le", "-ar", "48000", "-ac", "1", "-i", raw.path,
            "-af", "asetpts=PTS+5/TB+if(gte(T\\,1)\\,0.02/TB\\,0)", "-c:a", "pcm_s16le", source.path], workDirectory: work)
        let original = try Data(contentsOf: source)
        let renamed = work.appendingPathComponent("original.wav")
        try manager.moveItem(at: source, to: renamed)
        let record = try ConversionEngine(toolsDirectory: tools).convertRenamedFile(from: source, to: renamed,
            historyDirectory: work.appendingPathComponent("history"))
        let decoded = try ExternalTool.run(tools.appendingPathComponent("ffmpeg"), arguments: [
            "-v", "error", "-nostdin", "-i", renamed.path, "-map", "0:a:0", "-c:a", "pcm_s16le", "-f", "s16le", "-"],
            workDirectory: work, captureOutput: true)
        XCTAssertEqual(decoded.count, samples.count + 960 * 2)
        XCTAssertEqual(decoded.filter { $0 == 0 }.count, 960 * 2)
        XCTAssertEqual(decoded.filter { $0 != 0 }, samples)
        XCTAssertEqual(try Data(contentsOf: record.backupURL), original)
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(manager.fileExists(atPath: renamed.path))
        try manager.removeItem(at: record.backupURL.deletingLastPathComponent())
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: work.path).contains { $0.hasPrefix(".allomer-") })
    }

    func testSavedOptionsCoverArtAndAutomaticUndo() throws {
        let legacy = try JSONDecoder().decode(MediaOptions.self, from: Data(#"{"audioBitrateKbps":128,"videoBitrateKbps":1800,"sampleRate":44100,"channels":1,"preserveMetadata":false,"cpuProfile":"low","timeout":90}"#.utf8))
        XCTAssertEqual(legacy.audioBitrateKbps, 128)
        XCTAssertEqual(legacy.videoBitrateKbps, 1800)
        XCTAssertEqual(legacy.sampleRate, 44100)
        XCTAssertEqual(legacy.channels, 1)
        XCTAssertFalse(legacy.preserveMetadata)
        XCTAssertEqual(legacy.cpuProfile, .low)
        XCTAssertEqual(legacy.timeout, 90)
        XCTAssertEqual(legacy.audioMode, .quality)
        XCTAssertEqual(legacy.audioQuality, 100)
        XCTAssertEqual(legacy.flacCompressionLevel, 8)
        XCTAssertTrue(legacy.preserveCoverArt)
        XCTAssertEqual(try JSONDecoder().decode(MediaOptions.self, from: Data("{}".utf8)), MediaOptions())

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["ffmpeg", "ffprobe"].allSatisfy({ FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the media helpers before checking saved audio options.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let ffmpeg = tools.appendingPathComponent("ffmpeg")
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Audio options \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        var samples = Data()
        for i in 0..<36_000 {
            for frequency in [440.0, 660.0] {
                var sample = Int16(sin(Double(i) * frequency * 2 * .pi / 48_000) * 8192).littleEndian
                withUnsafeBytes(of: &sample) { samples.append(contentsOf: $0) }
            }
        }
        let pcm = work.appendingPathComponent("original.s16le")
        try samples.write(to: pcm)
        let image = work.appendingPathComponent("original.ppm")
        try (Data("P6\n32 32\n255\n".utf8) + Data(repeating: 72, count: 32 * 32 * 3)).write(to: image)
        let picture = work.appendingPathComponent("cover.png")
        try ExternalTool.run(ffmpeg, arguments: ["-v", "error", "-nostdin", "-n", "-i", image.path,
            "-frames:v", "1", "-c:v", "png", "-f", "image2", picture.path], workDirectory: work)
        let source = work.appendingPathComponent("original.flac")
        try ExternalTool.run(ffmpeg, arguments: ["-v", "error", "-nostdin", "-n", "-f", "s16le",
            "-ar", "48000", "-ac", "2", "-i", pcm.path, "-i", picture.path,
            "-map", "0:a:0", "-map", "1:v:0", "-c:a", "flac", "-c:v", "copy",
            "-disposition:v", "attached_pic", "-metadata", "title=Original audio",
            "-metadata:s:v", "comment=Cover (front)", "-f", "flac", source.path], workDirectory: work)
        let original = try Data(contentsOf: source)
        let art = try Data(contentsOf: picture)
        let options = try JSONDecoder().decode(MediaOptions.self, from: Data(#"{"audioMode":"quality","audioQuality":37,"flacCompressionLevel":0,"preserveMetadata":false,"preserveCoverArt":true}"#.utf8))
        XCTAssertEqual(try JSONDecoder().decode(MediaOptions.self, from: JSONEncoder().encode(options)), options)
        for format in ["mp3", "m4a", "ogg", "mka"] {
            let renamed = work.appendingPathComponent("original.\(format)")
            try manager.moveItem(at: source, to: renamed)
            let record = try engine.convertRenamedFile(from: source, to: renamed,
                historyDirectory: work.appendingPathComponent("history"), settings: .init(mediaOptions: options))
            let retained = try ExternalTool.run(ffmpeg, arguments: ["-v", "error", "-i", renamed.path,
                "-map", "0:v:0", "-c:v", "copy", "-frames:v", "1", "-f", "image2pipe", "-"],
                workDirectory: work, captureOutput: true)
            XCTAssertEqual(retained, art, format)
            XCTAssertEqual(try Data(contentsOf: record.backupURL), original)
            XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertFalse(manager.fileExists(atPath: renamed.path))
            try manager.removeItem(at: record.backupURL.deletingLastPathComponent())
        }
        let renamed = work.appendingPathComponent("original.wav")
        try manager.moveItem(at: source, to: renamed)
        XCTAssertThrowsError(try engine.convertRenamedFile(from: source, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), settings: .init(mediaOptions: options)))
        XCTAssertEqual(try Data(contentsOf: renamed), original)
        var drop = options
        drop.preserveCoverArt = false
        let record = try engine.convertRenamedFile(from: source, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), settings: .init(mediaOptions: drop))
        let decoded = try ExternalTool.run(ffmpeg, arguments: ["-v", "error", "-i", renamed.path,
            "-map", "0:a:0", "-f", "s16le", "-"], workDirectory: work, captureOutput: true)
        XCTAssertEqual(decoded, samples)
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: source), original)
        try manager.removeItem(at: record.backupURL.deletingLastPathComponent())
        for value in [Double.nan, .infinity, -1, 101] {
            var invalid = options
            invalid.audioQuality = value
            let output = work.appendingPathComponent("invalid.mp3")
            XCTAssertThrowsError(try engine.convert(source, to: output, settings: .init(mediaOptions: invalid)))
            XCTAssertFalse(manager.fileExists(atPath: output.path))
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: work.path).contains { $0.hasPrefix(".allomer-") })
    }
}
