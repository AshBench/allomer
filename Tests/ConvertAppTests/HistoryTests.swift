import XCTest
@testable import ConversionCore
@testable import ConvertApp

final class HistoryTests: XCTestCase {
    @MainActor
    func testClearKeepsActiveJobsRecoveryAndCleanupAcrossRestart() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = work.appendingPathComponent("history")
        let bytes = Data(#"{"value":3}"#.utf8)
        let original = work.appendingPathComponent("Café.json")
        let renamed = work.appendingPathComponent("Café.yaml")
        try bytes.write(to: renamed)
        let engine = try ConversionEngine()
        let record = try engine.convertRenamedFile(from: original, to: renamed, historyDirectory: directory)
        let journal = try Data(contentsOf: record.journalURL)
        let output = try Data(contentsOf: renamed)
        let model = ConversionModel(defaults: defaults, historyDirectory: directory)
        model.history = [record]
        XCTAssertEqual(model.visibleHistory.map(\.id), [record.id], "Old journals appear without a job-log migration")
        var completed = ConversionActivity(id: record.id, originalURL: original, requestedURL: renamed,
            outputURLs: [renamed], state: .completed, sourceID: "json", recordID: record.id)
        var options = ConversionSettings()
        options.configOptions.prettyPrint = false
        completed.configurations = [.init(outputURL: renamed, settings: options, keepOriginal: false)]
        model.recordJob(completed)
        let failed = ConversionActivity(originalURL: original, requestedURL: work.appendingPathComponent("failed.png"),
            outputURLs: [], state: .failed)
        let cancelled = ConversionActivity(originalURL: original, requestedURL: work.appendingPathComponent("cancelled.png"),
            outputURLs: [], state: .cancelled)
        var active = ConversionActivity(originalURL: original, requestedURL: work.appendingPathComponent("active.png"),
            outputURLs: [], state: .running)
        for entry in [failed, cancelled, active] { model.recordJob(entry) }
        await model.historyWriter?.value
        XCTAssertNil(model.historyIssue)
        XCTAssertEqual(try HistoryStore.load(from: model.jobHistoryDirectory).entries.count, 4)

        // Hold an earlier write while a job finishes after Clear has selected its entries.
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        model.historyWriter = Task { for await _ in stream { return } }
        let clearing = Task { await model.clearFinishedHistory() }
        let deadline = Date().addingTimeInterval(3)
        while !model.clearingHistory, Date() < deadline { await Task.yield() }
        XCTAssertTrue(model.clearingHistory)
        active.state = .completed
        model.recordJob(active)
        continuation.yield(())
        continuation.finish()
        await clearing.value
        await model.historyWriter?.value
        XCTAssertNil(model.historyIssue)
        XCTAssertEqual(model.visibleHistory.map(\.id), [active.id], "A job that was active when clearing started remains visible")
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(try Data(contentsOf: record.journalURL), journal)
        XCTAssertEqual(try Data(contentsOf: record.backupURL), bytes)
        XCTAssertEqual(try Data(contentsOf: renamed), output)
        let saved = try HistoryStore.load(from: model.jobHistoryDirectory)
        XCTAssertEqual(Set(saved.entries.map(\.id)), [active.id])
        XCTAssertEqual(saved.hiddenIDs, [record.id, failed.id, cancelled.id])

        let reloaded = ConversionModel(defaults: defaults, historyDirectory: directory)
        reloaded.history = try ConversionRecord.loadHistory(from: directory)
        try await reloaded.loadJobHistory()
        XCTAssertEqual(reloaded.visibleHistory.map(\.id), [active.id])
        XCTAssertEqual(reloaded.history.count, 1)
        var limits = BackupRetentionOptions()
        limits.limitAge = true
        limits.maximumAgeDays = 1
        let cleaned = try BackupRetention.clean(reloaded.history, options: limits, now: record.date.addingTimeInterval(86_400))
        XCTAssertEqual(cleaned.removedCount, 1, cleaned.issues.description)
        XCTAssertEqual(try Data(contentsOf: renamed), output)
        reloaded.history = cleaned.records
        XCTAssertEqual(reloaded.visibleHistory.map(\.id), [active.id], "Cleanup cannot restore a cleared history row")
    }

    @MainActor
    func testInterruptedJobsFiltersAndInvalidMetadata() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ConversionModel(defaults: defaults, historyDirectory: work.appendingPathComponent("history"))
        let original = work.appendingPathComponent("Café.json")
        let output = work.appendingPathComponent("report.yaml")
        var entry = ConversionActivity(originalURL: original, requestedURL: output, outputURLs: [output], state: .waiting)
        entry.message = "Testing a name collision"
        XCTAssertTrue(HistoryFilter.active.matches(entry, query: "cafe"))
        XCTAssertTrue(HistoryFilter.all.matches(entry, query: "report.yaml"))
        XCTAssertTrue(HistoryFilter.all.matches(entry, query: "COLLISION"))
        XCTAssertFalse(HistoryFilter.completed.matches(entry, query: ""))
        XCTAssertFalse(HistoryFilter.all.matches(entry, query: "missing"))
        for state in ConversionActivity.State.allCases {
            entry.state = state
            XCTAssertEqual(HistoryFilter.active.matches(entry, query: "  "), !state.isFinished)
            XCTAssertEqual(HistoryFilter.completed.matches(entry, query: ""), state == .completed)
            XCTAssertEqual(HistoryFilter.failed.matches(entry, query: ""), state == .failed)
            XCTAssertEqual(HistoryFilter.cancelled.matches(entry, query: ""), state == .cancelled)
        }
        entry.state = .running
        var configuration = ConversionActivity.Configuration(outputURL: output, settings: ConversionSettings(), keepOriginal: false)
        configuration.record(.init(index: 0, count: 2, sourceID: "xls", targetID: "json", settings: ConversionSettings()))
        entry.configurations = [configuration]
        try HistoryStore.save(entry, in: model.jobHistoryDirectory)
        try await model.loadJobHistory()
        await model.historyWriter?.value
        XCTAssertEqual(model.historyJobs[entry.id]?.state, .failed)
        XCTAssertTrue(model.historyJobs[entry.id]?.message?.contains("app stopped") == true)
        XCTAssertEqual(model.historyJobs[entry.id]?.configurations.first?.steps?.first?.state, .failed)
        XCTAssertTrue(model.historyJobs[entry.id]?.configurations.first?.steps?.first?.message?.contains("app stopped") == true)

        let engine = try ConversionEngine()
        try Data(#"{"value":3}"#.utf8).write(to: output)
        var record = try engine.convertRenamedFile(from: original, to: output, historyDirectory: model.historyDirectory)
        var completed = ConversionActivity(id: record.id, originalURL: original, requestedURL: output,
            outputURLs: [output], state: .running, recordID: record.id)
        completed.configurations = [configuration]
        try HistoryStore.save(completed, in: model.jobHistoryDirectory)
        model.history = [record]
        try await model.loadJobHistory()
        await model.historyWriter?.value
        XCTAssertEqual(model.historyJobs[record.id]?.state, .completed)
        XCTAssertEqual(model.historyJobs[record.id]?.configurations.first?.steps?.first?.state, .completed)
        let saved = try XCTUnwrap(try HistoryStore.load(from: model.jobHistoryDirectory).entries.first { $0.id == record.id })
        XCTAssertEqual(saved.configurations.first?.steps?.first?.state, .completed)

        // The preceding history schema has no step field.
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var oldConfigurations = try XCTUnwrap(oldJSON["configurations"] as? [[String: Any]])
        oldConfigurations[0].removeValue(forKey: "steps")
        oldJSON["configurations"] = oldConfigurations
        let old = try JSONDecoder().decode(ConversionActivity.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertNil(old.configurations.first?.steps)
        XCTAssertEqual(old.configurations.first?.settings, configuration.settings)

        var invalidStep = saved
        invalidStep.configurations[0].record(.init(index: -1, count: 2, sourceID: "json", targetID: "yaml", settings: nil))
        try HistoryStore.save(invalidStep, in: model.jobHistoryDirectory)
        XCTAssertThrowsError(try HistoryStore.load(from: model.jobHistoryDirectory))
        try HistoryStore.save(saved, in: model.jobHistoryDirectory)
        record.state = .needsReview
        try record.save()
        model.history = [record]
        XCTAssertFalse(model.canClearHistory(try XCTUnwrap(model.historyJobs[record.id])))
        await model.clearFinishedHistory()
        XCTAssertEqual(model.visibleHistory.map(\.id), [record.id])
        XCTAssertTrue(manager.fileExists(atPath: record.backupURL.path))

        let invalid = model.jobHistoryDirectory.appendingPathComponent("invalid.json")
        let corrupt = Data("corrupt metadata".utf8)
        try corrupt.write(to: invalid)
        XCTAssertThrowsError(try HistoryStore.load(from: model.jobHistoryDirectory))
        XCTAssertEqual(try Data(contentsOf: invalid), corrupt)
        try manager.removeItem(at: invalid)
        let symlink = model.jobHistoryDirectory.appendingPathComponent("\(UUID()).json")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: output)
        XCTAssertThrowsError(try HistoryStore.load(from: model.jobHistoryDirectory))
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: symlink.path), output.path)

        let blocked = work.appendingPathComponent("blocked-history")
        try Data("This is a file, not a history directory".utf8).write(to: blocked)
        let unavailable = ConversionModel(defaults: defaults, historyDirectory: blocked)
        entry.state = .completed
        unavailable.recordJob(entry)
        await unavailable.historyWriter?.value
        XCTAssertNotNil(unavailable.historyIssue)
        XCTAssertNil(unavailable.error, "A log write failure must not replace the conversion result")
        XCTAssertEqual(unavailable.visibleHistory.first?.state, .completed)
    }
}
