import Foundation
import XCTest
@testable import ConversionCore

final class KeepOriginalTests: XCTestCase {
    func testVisibleOriginalUndoAndInterruptedRecords() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.json")
        let renamed = directory.appendingPathComponent("original.yaml")
        let history = directory.appendingPathComponent("history")
        let bytes = Data(#"{"name":"Café 東京","count":3}"#.utf8)
        let changed = Data("A later edit".utf8)
        let engine = try ConversionEngine()
        try bytes.write(to: renamed)
        try changed.write(to: original)
        XCTAssertThrowsError(try engine.convertRenamedFile(from: original, to: renamed,
            historyDirectory: history, keepOriginal: true))
        XCTAssertEqual(try Data(contentsOf: original), changed)
        XCTAssertEqual(try Data(contentsOf: renamed), bytes)
        try manager.removeItem(at: original)
        try manager.createSymbolicLink(at: original, withDestinationURL: directory.appendingPathComponent("missing"))
        XCTAssertThrowsError(try engine.convertRenamedFile(from: original, to: renamed,
            historyDirectory: history, keepOriginal: true))
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: original.path), directory.appendingPathComponent("missing").path)
        try manager.removeItem(at: original)

        try manager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: renamed.path)
        let record = try engine.convertRenamedFile(from: original, to: renamed,
            historyDirectory: history, keepOriginal: true)
        XCTAssertEqual(record.keepOriginal, true)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Data(contentsOf: record.backupURL), bytes)
        XCTAssertEqual(try manager.attributesOfItem(atPath: original.path)[.posixPermissions] as? Int, 0o640)
        let output = try Data(contentsOf: renamed)
        XCTAssertNotEqual(output, bytes)

        var interrupted = record
        interrupted.state = .prepared
        try interrupted.save()
        try manager.removeItem(at: original)
        XCTAssertEqual(try ConversionRecord.loadHistory(from: history).first?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        try changed.write(to: original)
        try interrupted.save()
        XCTAssertEqual(try ConversionRecord.loadHistory(from: history).first?.state, .needsReview)
        XCTAssertEqual(try Data(contentsOf: original), changed)
        XCTAssertEqual(try Data(contentsOf: renamed), output)
        XCTAssertThrowsError(try ConversionEngine.undo(record))
        try bytes.write(to: original)
        try changed.write(to: renamed)
        XCTAssertThrowsError(try ConversionEngine.undo(record))
        XCTAssertEqual(try Data(contentsOf: renamed), changed)
        try output.write(to: renamed)

        interrupted.state = .undoPrepared
        try interrupted.save()
        XCTAssertEqual(try ConversionRecord.loadHistory(from: history).first?.state, .completed)
        try manager.removeItem(at: original)
        try interrupted.save()
        XCTAssertEqual(try ConversionRecord.loadHistory(from: history).first?.state, .needsReview)
        XCTAssertFalse(manager.fileExists(atPath: original.path))
        try bytes.write(to: original)
        let originalVersion = try FileVersion(original)
        let undone = try ConversionEngine.undo(record)
        XCTAssertEqual(undone.state, .undone)
        XCTAssertEqual(try FileVersion(original), originalVersion)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertFalse(manager.fileExists(atPath: renamed.path))
        XCTAssertEqual(try Data(contentsOf: record.undoneOutputURL), output)
        XCTAssertEqual(try Data(contentsOf: record.backupURL), bytes)
        try interrupted.save()
        XCTAssertEqual(try ConversionRecord.loadHistory(from: history).first?.state, .undone)
        try changed.write(to: record.undoneOutputURL)
        try interrupted.save()
        XCTAssertEqual(try ConversionRecord.loadHistory(from: history).first?.state, .needsReview)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    @MainActor
    func testOriginalNameTakenDuringConversionRollsBack() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let original = directory.appendingPathComponent("collision.json")
        let renamed = directory.appendingPathComponent("collision.yaml")
        let history = directory.appendingPathComponent("history")
        let bytes = Data(("[" + Array(repeating: #"{"text":"original","count":3}"#, count: 20_000).joined(separator: ",") + "]").utf8)
        try bytes.write(to: renamed)
        let engine = try ConversionEngine()
        let job = Task.detached {
            try engine.convertRenamedFile(from: original, to: renamed, historyDirectory: history, keepOriginal: true)
        }
        let deadline = Date().addingTimeInterval(5)
        while try !manager.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(".allomer-") }),
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let occupied = Data("Created while conversion was running".utf8)
        do { try occupied.write(to: original, options: .withoutOverwriting) }
        catch { _ = await job.result; throw error }
        let result = await job.result
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(try Data(contentsOf: original), occupied)
        XCTAssertEqual(try Data(contentsOf: renamed), bytes)
        XCTAssertEqual(try ConversionRecord.loadHistory(from: history).first?.state, .aborted)
    }
}
