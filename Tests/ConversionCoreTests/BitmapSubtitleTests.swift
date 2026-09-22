import Foundation
import XCTest
@testable import ConversionCore

final class BitmapSubtitleTests: XCTestCase {
    func testBitmapSubtitleLanguageAndAutomaticUndo() throws {
        guard let path = ProcessInfo.processInfo.environment["ALLOMER_BITMAP_FIXTURE"] else {
            throw XCTSkip("Set ALLOMER_BITMAP_FIXTURE to the original PGS Matroska fixture.")
        }
        let manager = FileManager.default
        let fixture = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: fixture)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = ProcessInfo.processInfo.environment["ALLOMER_TOOLS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(".tools/bin")
        let engine = try ConversionEngine(toolsDirectory: tools)
        let work = manager.temporaryDirectory.appendingPathComponent("Bitmap subtitles \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let source = work.appendingPathComponent("original.mkv")
        try original.write(to: source)
        XCTAssertEqual(try engine.subtitleTracks(in: source).first?.codec, "hdmv_pgs_subtitle")

        // These JSON values use the same schema as saved global text-language options.
        let invalid = try JSONDecoder().decode(PDFOptions.self, from: Data(#"{"ocrLanguage":"unsupported-language"}"#.utf8))
        let rejected = work.appendingPathComponent("rejected.srt")
        XCTAssertThrowsError(try engine.convert(source, to: rejected, settings: .init(pdfOptions: invalid))) { error in
            XCTAssertTrue(error.localizedDescription.contains("language is not supported"), error.localizedDescription)
        }
        XCTAssertFalse(manager.fileExists(atPath: rejected.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: work.path).contains { $0.hasPrefix(".allomer-") })

        let language = try JSONDecoder().decode(PDFOptions.self, from: Data(#"{"ocrLanguage":"en-US"}"#.utf8))
        XCTAssertEqual(language.ocrLanguage, "en-US")
        let renamed = work.appendingPathComponent("original.srt")
        try manager.moveItem(at: source, to: renamed)
        let record = try engine.convertRenamedFile(from: source, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), settings: .init(pdfOptions: language))
        let expected = [SubtitleCue(start: 1000, end: 2000, text: "Amber kite"),
                        SubtitleCue(start: 3250, end: 5500, text: "Quiet orbit\nSilver pebble")]
        XCTAssertEqual(try SubtitleConverter.parseSRT(String(contentsOf: renamed, encoding: .utf8)), expected)
        XCTAssertEqual(try Data(contentsOf: record.backupURL), original)
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: fixture), original)
        XCTAssertFalse(manager.fileExists(atPath: renamed.path))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix(".allomer-") },
                       [record.backupURL.deletingLastPathComponent().lastPathComponent])
    }
}
