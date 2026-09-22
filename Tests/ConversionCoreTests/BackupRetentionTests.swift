import Darwin
import Foundation
import XCTest
@testable import ConversionCore

final class BackupRetentionTests: XCTestCase {
    func testUndoneAndUnfinishedRecordsAndCancellation() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let bytes = Data(#"{"value":3}"#.utf8)
        let engine = try ConversionEngine()
        var records: [ConversionRecord] = []
        for keep in [false, true] {
            let original = work.appendingPathComponent("undone-\(keep).json")
            let renamed = work.appendingPathComponent("undone-\(keep).yaml")
            try bytes.write(to: renamed)
            let record = try engine.convertRenamedFile(from: original, to: renamed,
                historyDirectory: work.appendingPathComponent("history"), keepOriginal: keep)
            records.append(try ConversionEngine.undo(record))
        }
        var options = BackupRetentionOptions()
        options.limitAge = true
        options.maximumAgeDays = 1
        let history = records
        let policy = options
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BackupRetention.clean(history, options: policy, removeAll: true)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled cleanup must not start removal") }
        catch is CancellationError {} catch { throw error }
        for record in records { XCTAssertTrue(manager.fileExists(atPath: record.backupURL.path)) }
        let boundary = records.map(\.date).max()!.addingTimeInterval(86_400)
        let cleaned = try BackupRetention.clean(records, options: options, now: boundary)
        XCTAssertEqual(cleaned.removedCount, 2)
        XCTAssertTrue(cleaned.issues.isEmpty, cleaned.issues.description)
        for record in records {
            XCTAssertEqual(try Data(contentsOf: record.originalURL), bytes)
            XCTAssertFalse(manager.fileExists(atPath: record.convertedURL.path))
        }

        let renamed = work.appendingPathComponent("unfinished.yaml")
        try bytes.write(to: renamed)
        var record = try engine.convertRenamedFile(from: work.appendingPathComponent("unfinished.json"),
            to: renamed, historyDirectory: work.appendingPathComponent("history"))
        let output = try Data(contentsOf: renamed)
        for state: ConversionRecord.State in [.prepared, .undoPrepared] {
            record.state = state
            try record.save()
            let refused = try BackupRetention.clean([record], options: options, removeAll: true)
            XCTAssertEqual(refused.removedCount, 0)
            XCTAssertEqual(refused.issues.count, 1)
            XCTAssertTrue(manager.fileExists(atPath: record.backupURL.path))
        }
        record.state = .needsReview
        try record.save()
        let refused = try BackupRetention.clean([record], options: options,
            now: record.date.addingTimeInterval(86_400))
        XCTAssertEqual(refused.removedCount, 0)
        XCTAssertEqual(refused.issues.count, 1)
        let cleared = try BackupRetention.clean([record], options: options, removeAll: true)
        XCTAssertEqual(cleared.removedCount, 1)
        XCTAssertTrue(cleared.issues.isEmpty, cleared.issues.description)
        XCTAssertEqual(try Data(contentsOf: renamed), output)
    }

    func testAgeSizeAndExplicitRemovalKeepLiveFiles() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let now = Date()
        let bytes = Data(#"{"value":3}"#.utf8)
        let engine = try ConversionEngine()
        func make(_ name: String, daysOld: Int, keep: Bool = false) throws -> ConversionRecord {
            let original = work.appendingPathComponent(name + ".json")
            let renamed = work.appendingPathComponent(name + ".yaml")
            try bytes.write(to: renamed)
            let record = try engine.convertRenamedFile(from: original, to: renamed,
                historyDirectory: work.appendingPathComponent("history"), keepOriginal: keep)
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
            value["date"] = now.addingTimeInterval(-Double(daysOld) * 86_400).timeIntervalSinceReferenceDate
            let dated = try JSONDecoder().decode(ConversionRecord.self, from: JSONSerialization.data(withJSONObject: value))
            try dated.save()
            return dated
        }
        let old = try make("old", daysOld: 40, keep: true)
        let middle = try make("middle", daysOld: 10)
        let recent = try make("recent", daysOld: 1)
        var records = [recent, old, middle]
        let outputs = try Dictionary(uniqueKeysWithValues: records.map { ($0.id, try Data(contentsOf: $0.convertedURL)) })
        var options = BackupRetentionOptions()
        let unchanged = try BackupRetention.clean(records, options: options, now: now)
        XCTAssertEqual(unchanged.removedCount, 0)
        XCTAssertEqual(unchanged.retainedBytes, Int64(bytes.count * 6))
        XCTAssertTrue(unchanged.issues.isEmpty)

        options.limitAge = true
        let age = try BackupRetention.clean(records, options: options, now: now)
        XCTAssertEqual(age.removedCount, 1)
        XCTAssertTrue(age.issues.isEmpty, age.issues.description)
        XCTAssertEqual(age.records.first { $0.id == old.id }?.backupState, .removed)
        XCTAssertEqual(age.retainedBytes, Int64(bytes.count * 4))
        XCTAssertFalse(manager.fileExists(atPath: old.recoveryDirectory.path))
        XCTAssertEqual(try Data(contentsOf: old.originalURL), bytes)
        XCTAssertThrowsError(try ConversionEngine.undo(old))
        records = age.records

        options.limitAge = false
        options.limitSize = true
        options.maximumSizeGiB = Double(bytes.count * 2) / 1_073_741_824
        let size = try BackupRetention.clean(records, options: options, now: now)
        XCTAssertEqual(size.removedCount, 1)
        XCTAssertTrue(size.issues.isEmpty, size.issues.description)
        XCTAssertEqual(size.records.first { $0.id == middle.id }?.backupState, .removed)
        XCTAssertNil(size.records.first { $0.id == recent.id }?.backupState)
        XCTAssertEqual(size.retainedBytes, Int64(bytes.count * 2))
        for record in records { XCTAssertEqual(try Data(contentsOf: record.convertedURL), outputs[record.id]) }

        let edited = Data("An edited backup".utf8)
        try edited.write(to: recent.backupURL)
        options.maximumSizeGiB = 1 / 1_073_741_824
        let protected = try BackupRetention.clean(size.records, options: options, now: now)
        XCTAssertEqual(protected.removedCount, 0)
        XCTAssertEqual(protected.issues.count, 1)
        XCTAssertEqual(try Data(contentsOf: recent.backupURL), edited)

        let outside = work.appendingPathComponent("outside.txt")
        try edited.write(to: outside)
        try manager.createSymbolicLink(at: recent.recoveryDirectory.appendingPathComponent("outside-link"), withDestinationURL: outside)
        let cleared = try BackupRetention.clean(protected.records, options: options, removeAll: true, now: now)
        XCTAssertTrue(cleared.issues.isEmpty, cleared.issues.description)
        XCTAssertEqual(cleared.removedCount, 1)
        XCTAssertEqual(cleared.retainedBytes, 0)
        XCTAssertTrue(cleared.records.allSatisfy { $0.backupState == .removed && !$0.canUndo })
        XCTAssertEqual(try Data(contentsOf: outside), edited)
        XCTAssertEqual(try Data(contentsOf: old.originalURL), bytes)
        for record in records { XCTAssertEqual(try Data(contentsOf: record.convertedURL), outputs[record.id]) }
        XCTAssertEqual(try ConversionRecord.loadHistory(from: work.appendingPathComponent("history")).count, 3)
        XCTAssertEqual(try BackupRetention.clean(cleared.records, options: options, removeAll: true).removedCount, 0)
        options.maximumSizeGiB = .nan
        XCTAssertThrowsError(try BackupRetention.clean([], options: options))
        options.limitSize = false
        options.limitAge = true
        options.maximumAgeDays = 0
        XCTAssertThrowsError(try BackupRetention.clean([], options: options))
    }

    func testInterruptedRemovalChecksDirectoryIdentityAndBlocksStaleUndo() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let original = work.appendingPathComponent("original.json")
        let renamed = work.appendingPathComponent("original.yaml")
        let bytes = Data(#"{"value":3}"#.utf8)
        try bytes.write(to: renamed)
        let record = try ConversionEngine().convertRenamedFile(from: original, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), keepOriginal: true)
        let output = try Data(contentsOf: renamed)
        var pending = record
        pending.backupState = .removing
        pending.removalInode = try FileVersion(record.recoveryDirectory, allowingDirectories: true).inode
        pending.removalVolumeID = try record.recoveryDirectory.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        try pending.save()
        XCTAssertFalse(try XCTUnwrap(ConversionRecord.loadHistory(from: work.appendingPathComponent("history")).first).canUndo)
        XCTAssertThrowsError(try ConversionEngine.undo(record))

        let retained = work.appendingPathComponent("retained")
        try manager.moveItem(at: record.recoveryDirectory, to: retained)
        try manager.createDirectory(at: record.recoveryDirectory, withIntermediateDirectories: false)
        let foreign = record.recoveryDirectory.appendingPathComponent("unrelated.txt")
        try bytes.write(to: foreign)
        let refused = try BackupRetention.clean([pending], options: BackupRetentionOptions())
        XCTAssertEqual(refused.removedCount, 0)
        XCTAssertFalse(refused.issues.isEmpty)
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
        XCTAssertTrue(manager.fileExists(atPath: retained.path))

        try manager.moveItem(at: retained, to: record.removalDirectory)
        try manager.removeItem(at: record.removalDirectory.appendingPathComponent("input"))
        let resumed = try BackupRetention.clean([pending], options: BackupRetentionOptions())
        XCTAssertEqual(resumed.removedCount, 1)
        XCTAssertTrue(resumed.issues.isEmpty, resumed.issues.description)
        XCTAssertEqual(resumed.records.first?.backupState, .removed)
        XCTAssertFalse(manager.fileExists(atPath: record.removalDirectory.path))
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Data(contentsOf: renamed), output)
        try pending.save()
        let refusedReplacement = try BackupRetention.clean([pending], options: BackupRetentionOptions())
        XCTAssertEqual(refusedReplacement.removedCount, 0)
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
        try manager.removeItem(at: record.recoveryDirectory)
        let finished = try BackupRetention.clean([pending], options: BackupRetentionOptions())
        XCTAssertEqual(finished.records.first?.backupState, .removed)
        XCTAssertTrue(finished.issues.isEmpty, finished.issues.description)
    }

    func testAbandonedWorkDirectoriesAreSweptAndLiveOnesAreKept() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let history = work.appendingPathComponent("history")
        let bytes = Data(#"{"value":3}"#.utf8)
        let renamed = work.appendingPathComponent("kept.yaml")
        try bytes.write(to: renamed)
        let record = try ConversionEngine().convertRenamedFile(from: work.appendingPathComponent("kept.json"),
                                                              to: renamed, historyDirectory: history)
        XCTAssertTrue(manager.fileExists(atPath: record.recoveryDirectory.path))
        XCTAssertFalse(manager.fileExists(atPath: record.recoveryDirectory.appendingPathComponent(".in-progress").path))
        let converted = try Data(contentsOf: renamed)

        func leftover(_ name: String) throws -> URL {
            let url = work.appendingPathComponent(name)
            try manager.createDirectory(at: url, withIntermediateDirectories: false)
            try bytes.write(to: url.appendingPathComponent("leftover"))
            return url
        }
        let orphan = try leftover(".allomer-\(UUID().uuidString)")
        let marked = try leftover(".allomer-\(UUID().uuidString)")
        try BackupRetention.markWorkDirectory(marked)
        let held = work.appendingPathComponent(".allomer-\(UUID().uuidString)")
        try manager.createDirectory(at: held.appendingPathComponent("input"), withIntermediateDirectories: true)
        let removing = try leftover(".allomer-removing-\(UUID().uuidString)")
        let unrelated = try leftover(".allomer-not-a-uuid")
        // A backup whose journal lives in some other history location must survive on its contents.
        let foreign = try leftover(".allomer-\(UUID().uuidString)")
        try bytes.write(to: foreign.appendingPathComponent("original.json"))
        try manager.removeItem(at: foreign.appendingPathComponent("leftover"))
        let link = work.appendingPathComponent(".allomer-\(UUID().uuidString)")
        try manager.createSymbolicLink(at: link, withDestinationURL: foreign)
        // Unfinished work is only the input folder and a partly written output.
        let partial = work.appendingPathComponent(".allomer-\(UUID().uuidString)")
        try manager.createDirectory(at: partial.appendingPathComponent("input"), withIntermediateDirectories: true)
        try bytes.write(to: partial.appendingPathComponent("converted.yaml"))
        let descriptor = BackupRetention.lockWorkDirectory(held)
        XCTAssertGreaterThanOrEqual(descriptor, 0)

        BackupRetention.sweepAbandonedWork(in: work, historyDirectory: history)

        XCTAssertFalse(manager.fileExists(atPath: partial.path), "Unfinished work with no journal is reclaimed.")
        XCTAssertFalse(manager.fileExists(atPath: marked.path), "Marked crash residue is reclaimed even with converter temporary files.")
        XCTAssertTrue(manager.fileExists(atPath: foreign.path), "A directory holding a backup is never reclaimed.")
        XCTAssertTrue(manager.fileExists(atPath: orphan.path), "A directory with unknown contents is left alone.")
        XCTAssertTrue(manager.fileExists(atPath: held.path), "A locked directory belongs to a live conversion.")
        XCTAssertTrue(manager.fileExists(atPath: removing.path), "A removal directory is recorded work.")
        XCTAssertTrue(manager.fileExists(atPath: unrelated.path), "A name without a valid identifier is not ours to judge.")
        XCTAssertNotNil(try? manager.destinationOfSymbolicLink(atPath: link.path), "A symbolic link is never followed.")
        XCTAssertTrue(manager.fileExists(atPath: record.recoveryDirectory.path), "A journalled backup must survive.")
        XCTAssertEqual(try Data(contentsOf: record.backupURL), bytes)
        XCTAssertEqual(try Data(contentsOf: renamed), converted)

        // Once the owner lets go, the same directory is reclaimed on the next pass.
        close(descriptor)
        BackupRetention.sweepAbandonedWork(in: work, historyDirectory: history)
        XCTAssertFalse(manager.fileExists(atPath: held.path))
        XCTAssertTrue(manager.fileExists(atPath: record.recoveryDirectory.path))
        XCTAssertEqual(try Data(contentsOf: record.backupURL), bytes)
    }
}
