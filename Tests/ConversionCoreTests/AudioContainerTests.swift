import Foundation
import XCTest
@testable import ConversionCore

final class AudioContainerTests: XCTestCase {
    func testAudioOnlyContainersSettingsDetectionAndUndo() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard manager.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path) else {
            throw XCTSkip("Build the media helpers before checking audio-only containers.")
        }
        let work = manager.temporaryDirectory.appendingPathComponent("Audio containers café \(UUID())")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let media = try MediaConverter(toolsDirectory: tools)
        let codecs = ["avi": "mp3", "m2ts": "ac3", "mpeg": "mp2", "ts": "aac", "vob": "ac3", "wmv": "wmav2"]
        let mxf = try XCTUnwrap(engine.catalog.format(forExtension: "mxf"))
        for source in engine.catalog.formats where source.category == "audio" {
            for targetID in codecs.keys {
                let target = try XCTUnwrap(engine.catalog.format(forExtension: targetID))
                XCTAssertEqual(engine.conversionRoute(from: source, to: target)?.map(\.id), [targetID])
            }
            XCTAssertNil(engine.conversionRoute(from: source, to: mxf))
        }
        let pcm = work.appendingPathComponent("tone.s16le")
        var samples = Data()
        for index in 0..<36_000 {
            for frequency in [440.0, 660.0] {
                var sample = Int16(sin(Double(index) * frequency * 2 * .pi / 48_000) * 8192).littleEndian
                withUnsafeBytes(of: &sample) { samples.append(contentsOf: $0) }
            }
        }
        try samples.write(to: pcm)
        let source = work.appendingPathComponent("original.flac")
        try ExternalTool.run(media.ffmpeg, arguments: ["-v", "error", "-nostdin", "-n", "-f", "s16le",
            "-ar", "48000", "-ac", "2", "-i", pcm.path, "-c:a", "flac", source.path], workDirectory: work)
        let original = try Data(contentsOf: source)
        var options = MediaOptions()
        options.audioBitrateKbps = 128
        options.sampleRate = 44100
        options.channels = 1
        options.videoCodec = .prores // A saved video choice does not create video in an audio-only file.
        var recoveryDirectories: Set<String> = []
        for targetID in codecs.keys.sorted() {
            XCTAssertTrue(engine.availableOutputs(for: source).contains { $0.id == targetID })
            let renamed = work.appendingPathComponent("original.\(targetID)")
            try manager.moveItem(at: source, to: renamed)
            let record = try engine.convertRenamedFile(from: source, to: renamed,
                historyDirectory: work.appendingPathComponent("history"), settings: .init(mediaOptions: options))
            recoveryDirectories.insert(record.backupURL.deletingLastPathComponent().lastPathComponent)
            let result = try media.inspect(renamed, work: work)
            XCTAssertEqual(result.streams.count, 1, targetID)
            XCTAssertTrue(result.video.isEmpty, targetID)
            let audio = try XCTUnwrap(result.audio.first)
            XCTAssertEqual(audio.codec_name, codecs[targetID])
            XCTAssertEqual(audio.channels, 1)
            XCTAssertEqual(audio.sample_rate, "44100")
            XCTAssertEqual(try engine.detectedFormat(at: renamed)?.id, targetID)
            XCTAssertEqual(try Data(contentsOf: record.backupURL), original)
            XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertFalse(manager.fileExists(atPath: renamed.path))
        }
        let rejected = work.appendingPathComponent("rejected.mxf")
        XCTAssertThrowsError(try engine.convert(source, to: rejected))
        XCTAssertFalse(manager.fileExists(atPath: rejected.path))
        let leftovers = try manager.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix(".allomer-") }
        XCTAssertEqual(Set(leftovers), recoveryDirectories, "Only recorded Undo backups should remain.")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
