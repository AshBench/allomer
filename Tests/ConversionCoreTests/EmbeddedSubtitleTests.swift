import Foundation
import XCTest
@testable import ConversionCore

final class EmbeddedSubtitleTests: XCTestCase {
    func testTrackSelectionTimingStylesAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["ffmpeg", "ffprobe"].allSatisfy({ FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the media helpers before checking embedded subtitles.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Embedded subtitles \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let image = work.appendingPathComponent("frame.ppm")
        try (Data("P6\n16 12\n255\n".utf8) + Data(repeating: 90, count: 16 * 12 * 3)).write(to: image)
        let first = work.appendingPathComponent("first.srt"), second = work.appendingPathComponent("second.srt")
        let firstText = "1\n00:00:00,125 --> 00:00:01,865\nCafé 世界 👋\nSecond line\n\n2\n00:00:01,500 --> 00:00:03,235\nOverlap.\n"
        let secondText = "1\n00:00:00,500 --> 00:00:02,000\nDifferent track.\n"
        try Data(firstText.utf8).write(to: first); try Data(secondText.utf8).write(to: second)
        let movie = work.appendingPathComponent("original.mkv")
        try ExternalTool.run(tools.appendingPathComponent("ffmpeg"), arguments: [
            "-nostdin", "-v", "error", "-n", "-f", "image2", "-loop", "1", "-framerate", "25", "-i", image.path,
            "-f", "srt", "-i", first.path, "-f", "srt", "-i", second.path, "-map", "0:v", "-map", "1:s", "-map", "2:s",
            "-t", "4", "-c:v", "mpeg4", "-pix_fmt", "yuv420p", "-c:s", "srt",
            "-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=First track",
            "-metadata:s:s:1", "language=fra", "-disposition:s:0", "0", "-disposition:s:1", "default",
            "-output_ts_offset", "5", "-f", "matroska", movie.path], workDirectory: work)
        let original = try Data(contentsOf: movie)
        let tracks = try engine.subtitleTracks(in: movie)
        XCTAssertEqual(tracks.map(\.id), [1, 2])
        XCTAssertEqual(tracks.map(\.language), ["eng", "fra"])
        XCTAssertEqual(tracks.first?.title, "First track")
        XCTAssertTrue(SubtitleConverter.formats.isSubset(of: Set(engine.availableOutputs(for: movie).map(\.id))))
        let expected = try SubtitleConverter.parseSRT(firstText)
        for format in ["srt", "vtt", "ass", "ssa", "sbv", "sub"] {
            let output = work.appendingPathComponent("converted.\(format)")
            try engine.convert(movie, to: output)
            let checked = work.appendingPathComponent("check-\(format).srt")
            try engine.convert(output, to: checked)
            let cues = try SubtitleConverter.parseSRT(String(contentsOf: checked, encoding: .utf8))
            XCTAssertEqual(cues.map(\.text), expected.map(\.text))
            for (before, after) in zip(expected, cues) {
                XCTAssertLessThanOrEqual(abs(before.start - after.start), 41)
                XCTAssertLessThanOrEqual(abs(before.end - after.end), 41)
            }
        }
        let defaultOutput = work.appendingPathComponent("default.srt")
        try engine.convert(movie, to: defaultOutput)
        XCTAssertEqual(try SubtitleConverter.parseSRT(String(contentsOf: defaultOutput, encoding: .utf8)), expected)
        let damaged = work.appendingPathComponent("damaged.mkv")
        try original.prefix(original.count / 2).write(to: damaged)
        let partial = work.appendingPathComponent("partial.srt")
        XCTAssertThrowsError(try engine.convert(damaged, to: partial))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: damaged), original.prefix(original.count / 2))
        var options = try JSONDecoder().decode(SubtitleOptions.self, from: Data(#"{"embeddedTrack":2}"#.utf8))
        let selected = work.appendingPathComponent("selected.srt")
        try engine.convert(movie, to: selected, settings: .init(subtitleOptions: options))
        XCTAssertEqual(try SubtitleConverter.parseSRT(String(contentsOf: selected, encoding: .utf8)), try SubtitleConverter.parseSRT(secondText))
        let legacy = try JSONDecoder().decode(SubtitleOptions.self, from: Data(#"{"frameRate":30,"removeFormatting":true}"#.utf8))
        XCTAssertEqual(legacy.frameRate, 30); XCTAssertTrue(legacy.removeFormatting); XCTAssertNil(legacy.embeddedTrack)
        let styled = work.appendingPathComponent("styled.ass")
        var styleText = try String(contentsOf: work.appendingPathComponent("converted.ass"), encoding: .utf8)
        styleText = styleText.replacingOccurrences(of: "Style: Default,Arial,16,", with: "Style: Default,Georgia,28,")
        styleText = styleText.replacingOccurrences(of: "Café", with: #"{\pos(50,80)\i1}Café"#)
        XCTAssertTrue(styleText.contains("Georgia,28,"))
        try Data(styleText.utf8).write(to: styled)
        let styledMovie = work.appendingPathComponent("styled.mkv")
        try ExternalTool.run(tools.appendingPathComponent("ffmpeg"), arguments: [
            "-nostdin", "-v", "error", "-n", "-i", movie.path, "-f", "ass", "-i", styled.path,
            "-map", "0:v", "-map", "1:s", "-c", "copy", "-f", "matroska", styledMovie.path], workDirectory: work)
        let styledOutput = work.appendingPathComponent("style-result.ass")
        try engine.convert(styledMovie, to: styledOutput)
        let styledResult = try String(contentsOf: styledOutput, encoding: .utf8)
        XCTAssertTrue(styledResult.contains("Georgia,28,"))
        XCTAssertTrue(styledResult.contains(#"{\pos(50,80)\i1}Café"#))
        for missing in [0, -1, 3, 257] {
            options.embeddedTrack = missing
            let output = work.appendingPathComponent("missing-\(missing).srt")
            XCTAssertThrowsError(try engine.convert(movie, to: output, settings: .init(subtitleOptions: options)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: movie), original)
        }
        XCTAssertThrowsError(try engine.convert(movie, to: selected))
        let renamed = work.appendingPathComponent("original.srt")
        try FileManager.default.moveItem(at: movie, to: renamed)
        options.embeddedTrack = 2
        let record = try engine.convertRenamedFile(from: movie, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), settings: .init(subtitleOptions: options))
        XCTAssertEqual(try SubtitleConverter.parseSRT(String(contentsOf: renamed, encoding: .utf8)), try SubtitleConverter.parseSRT(secondText))
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: movie), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix(".allomer-") },
                       [record.backupURL.deletingLastPathComponent().lastPathComponent])
    }
}
