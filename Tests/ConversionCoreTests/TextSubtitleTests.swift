import Foundation
import XCTest

@testable import ConversionCore

final class TextSubtitleTests: XCTestCase {
    func testSubtitleFormatsPreserveTextAndTiming() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path) else {
            throw XCTSkip("Build the bundled media tools to check subtitle conversion.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("original.srt")
        let text = "1\n00:00:00,125 --> 00:00:01,865\nCafé, 東京 👋\nSecond line\n\n"
            + "2\n00:00:01,500 --> 00:00:03,235\nOverlap & punctuation.\n\n"
            + "3\n00:00:04,040 --> 00:00:04,160\nShort cue\n"
        try text.write(to: input, atomically: false, encoding: .utf8)
        let engine = try ConversionEngine(toolsDirectory: tools)
        let expected = try SubtitleConverter.parseSRT(text)
        let formats = engine.catalog.formats.filter { SubtitleConverter.formats.contains($0.id) }
        XCTAssertEqual(Set(engine.availableOutputs(for: input).map(\.id)), SubtitleConverter.formats.union(ArchiveConverter.formats))
        var inputs: [URL] = []
        for format in formats {
            let output = directory.appendingPathComponent("converted.\(format.extensions[0])")
            try engine.convert(input, to: output)
            inputs.append(output)
            if format.id == "ssa" {
                let ssa = try String(contentsOf: output, encoding: .utf8)
                XCTAssertTrue(ssa.contains("ScriptType: v4.00\n"))
                XCTAssertTrue(ssa.contains("[V4 Styles]"))
                XCTAssertFalse(ssa.contains("[V4+ Styles]"))
            }
        }
        for (index, source) in inputs.enumerated() {
            for target in formats {
                let output = directory.appendingPathComponent("route-\(index).\(target.extensions[0])")
                try engine.convert(source, to: output)
                if target.id == "ssa" {
                    let text = try String(contentsOf: output, encoding: .utf8)
                    XCTAssertTrue(text.contains("Dialogue: Marked=0,"))
                    XCTAssertFalse(text.contains("Marked=Marked="))
                }
            }
            let result = try SubtitleConverter.parseSRT(String(contentsOf: directory.appendingPathComponent("route-\(index).srt"), encoding: .utf8))
            XCTAssertEqual(result.count, expected.count)
            for (before, after) in zip(expected, result) {
                XCTAssertEqual(before.text, after.text)
                XCTAssertLessThanOrEqual(abs(before.start - after.start), 41)
                XCTAssertLessThanOrEqual(abs(before.end - after.end), 41)
            }
        }
        let frameInput = directory.appendingPathComponent("without-header.sub")
        try "{10}{50}Frame timing\n".write(to: frameInput, atomically: false, encoding: .utf8)
        let frameOutput = directory.appendingPathComponent("frames.srt")
        XCTAssertThrowsError(try engine.convert(frameInput, to: frameOutput))
        var options = SubtitleOptions()
        options.sourceFrameRate = 25
        try engine.convert(frameInput, to: frameOutput, settings: .init(subtitleOptions: options))
        XCTAssertEqual(try SubtitleConverter.parseSRT(String(contentsOf: frameOutput, encoding: .utf8)).first?.start, 400)
        let styled = directory.appendingPathComponent("styled.srt")
        try "1\n00:00:00,000 --> 00:00:01,000\n<i>Styled text</i>\n".write(to: styled, atomically: false, encoding: .utf8)
        let plain = directory.appendingPathComponent("plain.sbv")
        XCTAssertThrowsError(try engine.convert(styled, to: plain))
        options.removeFormatting = true
        try engine.convert(styled, to: plain, settings: .init(subtitleOptions: options))
        XCTAssertTrue(try String(contentsOf: plain, encoding: .utf8).contains("\nStyled text\n"))
        let aligned = directory.appendingPathComponent("aligned.ass")
        let ass = try String(contentsOf: directory.appendingPathComponent("converted.ass"), encoding: .utf8)
            .replacingOccurrences(of: "Café", with: #"{\an8}Café"#)
        try ass.write(to: aligned, atomically: false, encoding: .utf8)
        for format in ["srt", "sub"] {
            let output = directory.appendingPathComponent("plain-aligned.\(format)")
            try engine.convert(aligned, to: output, settings: .init(subtitleOptions: options))
            let result = try String(contentsOf: output, encoding: .utf8)
            XCTAssertFalse(result.contains(#"\an8"#))
            XCTAssertTrue(result.contains("Café, 東京 👋"))
        }
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), text)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".allomer-") })
        XCTAssertThrowsError(try SubtitleConverter.parseSRT("1\n00:00:02,000 --> 00:00:01,000\nInvalid\n"))
    }
}
