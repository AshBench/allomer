import XCTest
@testable import ConversionCore

final class AutomaticMediaIdentityTests: XCTestCase {
    @MainActor
    func testOrdinaryWMVRenameUsesOriginalRuleAndKeepsUndo() async throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["ffmpeg", "ffprobe"].allSatisfy({ manager.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the media helpers before checking audio-only WMV identity.")
        }
        let work = manager.temporaryDirectory.appendingPathComponent("WMV identity \(UUID().uuidString)")
        let watched = work.appendingPathComponent("watched")
        try manager.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let pcm = work.appendingPathComponent("original.s16le")
        try Data(repeating: 18, count: 96_000).write(to: pcm)
        let source = watched.appendingPathComponent("original.wmv")
        try ExternalTool.run(tools.appendingPathComponent("ffmpeg"), arguments: [
            "-v", "error", "-nostdin", "-n", "-f", "s16le", "-ar", "48000", "-ac", "1", "-i", pcm.path,
            "-c:a", "wmav2", "-b:a", "96k", "-f", "asf", source.path], workDirectory: work)
        let bytes = try Data(contentsOf: source)
        let engine = try ConversionEngine(toolsDirectory: tools)
        let media = try MediaConverter(toolsDirectory: tools)
        XCTAssertTrue(try media.inspect(source, work: work).video.isEmpty)
        var approvals: [ConversionApproval] = []
        var results: [Result<ConversionRecord, Error>] = []
        let service = AutomaticConverter(engine: engine, historyDirectory: work.appendingPathComponent("history")) {
            results.append($0)
        }
        service.action = .doNotConvert
        service.rules = [
            .init(sourceID: "wmv", targetID: "flac", action: .askFirst),
            .init(sourceID: "wma", targetID: "flac", action: .doNotConvert)
        ]
        service.approvalsChanged = { approvals = $0 }
        try service.start(folders: [watched])
        defer { service.stop() }
        let renamed = watched.appendingPathComponent("original.flac")
        let move = Process()
        move.executableURL = URL(fileURLWithPath: "/bin/mv")
        move.arguments = [source.path, renamed.path]
        try move.run()
        move.waitUntilExit()
        XCTAssertEqual(move.terminationStatus, 0)
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(condition(), "The media rename did not reach its expected state.")
        }
        try await waitFor { approvals.count == 1 }
        let approval = try XCTUnwrap(approvals.first)
        XCTAssertEqual(approval.originalURL, source)
        XCTAssertEqual(approval.renamedURL, renamed)
        XCTAssertEqual(try Data(contentsOf: renamed), bytes)
        service.decide(approval.id, convert: true)
        try await waitFor { results.count == 1 }
        let record = try XCTUnwrap(results.first).get()
        XCTAssertEqual(record.originalURL, source)
        XCTAssertEqual(record.snapshotURL.pathExtension, "wmv")
        XCTAssertEqual(try Data(contentsOf: record.backupURL), bytes)
        let output = try media.inspect(renamed, work: work)
        XCTAssertEqual(output.audio.first?.codec_name, "flac")
        XCTAssertTrue(output.video.isEmpty)
        await service.stopAndWait()
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertFalse(manager.fileExists(atPath: renamed.path))
        try manager.removeItem(at: record.backupURL.deletingLastPathComponent())
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: watched.path).contains { $0.hasPrefix(".allomer-") })
    }

    func testMisleadingSourceHintDoesNotReplaceContentDetection() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let file = work.appendingPathComponent("renamed.flac")
        let bytes = Data(#"{"name":"Original content","count":7}"#.utf8)
        try bytes.write(to: file)
        let engine = try ConversionEngine()
        for hint in ["wmv", "mkv", "mp4", "md", "ipynb"] {
            XCTAssertEqual(try engine.detectedFormat(at: file, sourceExtensionHint: hint)?.id, "json", hint)
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
