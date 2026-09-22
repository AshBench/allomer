import CoreServices
import XCTest
@testable import ConversionCore

final class AutomaticActionTests: XCTestCase {
    @MainActor
    func testNewArrivalsUseDetectedFormatsAndRestoreTheirNames() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watched = work.appendingPathComponent("watched")
        try manager.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let bytes = Data(#"{"name":"Café","count":3}"#.utf8)
        let engine = try ConversionEngine()
        var results: [Result<ConversionRecord, Error>] = []
        var approvals: [ConversionApproval] = []
        var active = 0
        var queued = 0
        let service = AutomaticConverter(engine: engine, historyDirectory: work.appendingPathComponent("history")) {
            results.append($0)
        }
        service.approvalsChanged = { approvals = $0 }
        service.activity = { jobs, waiting, _ in active = jobs; queued = waiting }
        try service.start(folders: [watched])
        defer { service.stop() }
        func external(_ command: String, _ source: URL, _ destination: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = [source.path, destination.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        func arrive(_ name: String, contents: Data? = nil) throws -> URL {
            let source = work.appendingPathComponent(UUID().uuidString)
            try (contents ?? bytes).write(to: source)
            let destination = watched.appendingPathComponent(name)
            try external("/bin/cp", source, destination)
            return destination
        }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(condition(), "The arrival watcher did not reach the expected state.")
        }
        XCTAssertFalse(service.convertNewFiles)
        let disabled = try arrive("disabled.yaml")
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(try Data(contentsOf: disabled), bytes)

        service.convertNewFiles = true
        service.keepOriginal = true
        let immediate = try arrive("immediate.yaml")
        try await waitFor { results.count == 1 }
        let record = try results[0].get()
        XCTAssertEqual(record.originalURL, immediate)
        XCTAssertEqual(record.convertedURL, immediate)
        XCTAssertEqual(record.detectedSourceExtension, "json")
        XCTAssertEqual(try Data(contentsOf: record.visibleOriginalURL), bytes)
        XCTAssertNotEqual(try Data(contentsOf: immediate), bytes)
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: immediate), bytes)
        XCTAssertFalse(manager.fileExists(atPath: record.visibleOriginalURL.path))

        // The detected pair selects this rule despite the arrival's YAML name.
        service.action = .doNotConvert
        service.rules = [ConversionRule(sourceID: "json", targetID: "yaml", action: .askFirst, keepOriginal: false)]
        let asked = try arrive("asked.yaml")
        try await waitFor { approvals.count == 1 }
        XCTAssertEqual(approvals.first?.detectedSourceID, "json")
        XCTAssertEqual(approvals.first?.originalURL, asked)
        service.decide(try XCTUnwrap(approvals.first).id, convert: true)
        try await waitFor { results.count == 2 }
        let askedRecord = try results[1].get()
        XCTAssertNotEqual(askedRecord.keepOriginal, true)
        _ = try ConversionEngine.undo(askedRecord)
        XCTAssertEqual(try Data(contentsOf: asked), bytes)

        let changed = try arrive("changed.yaml")
        try await waitFor { approvals.count == 1 }
        let edited = Data(#"{"changed":true}"#.utf8)
        try edited.write(to: changed)
        service.decide(try XCTUnwrap(approvals.first).id, convert: true)
        try await waitFor { results.count == 3 }
        XCTAssertThrowsError(try results[2].get())
        XCTAssertEqual(try Data(contentsOf: changed), edited)

        let again = try arrive("again.yaml")
        try await waitFor { approvals.count == 1 }
        let oldID = try XCTUnwrap(approvals.first).id
        let next = watched.appendingPathComponent("again.toml")
        service.rules.append(ConversionRule(sourceID: "json", targetID: "toml", action: .askFirst, keepOriginal: false))
        try external("/bin/mv", again, next)
        try await waitFor { approvals.first?.renamedURL == next }
        XCTAssertEqual(approvals.first?.originalURL, again)
        XCTAssertEqual(approvals.first?.detectedSourceID, "json")
        XCTAssertFalse(service.decide(oldID, convert: true))
        service.decide(try XCTUnwrap(approvals.first).id, convert: true)
        try await waitFor { results.count == 4 }
        _ = try ConversionEngine.undo(try results[3].get())
        XCTAssertEqual(try Data(contentsOf: again), bytes)
        XCTAssertFalse(manager.fileExists(atPath: next.path))

        let held = try arrive("held.yaml")
        try await waitFor { approvals.count == 1 }
        let original = watched.appendingPathComponent("ordinary.json")
        let renamed = watched.appendingPathComponent("ordinary.yaml")
        try bytes.write(to: original)
        try external("/bin/mv", original, renamed)
        try await waitFor { approvals.count == 2 }
        service.convertNewFiles = false
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?.originalURL, original)
        service.decide(try XCTUnwrap(approvals.first).id, convert: false)
        XCTAssertEqual(try Data(contentsOf: held), bytes)

        service.convertNewFiles = true
        service.rules.removeAll()
        service.action = .immediately
        service.keepOriginal = false
        service.maintenanceInProgress = true
        let maintenance = try arrive("maintenance.yaml")
        try await waitFor { queued == 1 }
        XCTAssertEqual(active, 0)
        XCTAssertEqual(results.count, 4)
        service.maintenanceInProgress = false
        try await waitFor { results.count == 5 }
        _ = try ConversionEngine.undo(try results[4].get())
        XCTAssertEqual(try Data(contentsOf: maintenance), bytes)

        let correct = try arrive("correct.json")
        let unknownBytes = Data([0, 1, 2, 0xff, 0, 3, 4, 0xfe])
        let unknown = try arrive("unknown.yaml", contents: unknownBytes)
        try await Task.sleep(for: .seconds(2))
        try await waitFor { active == 0 && queued == 0 }
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(try Data(contentsOf: correct), bytes)
        XCTAssertEqual(try Data(contentsOf: unknown), unknownBytes)
        XCTAssertEqual(try Data(contentsOf: disabled), bytes)
        await service.stopAndWait()
    }

    @MainActor
    func testDecisionsAfterExternalRenames() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watched = directory.appendingPathComponent("watched")
        try manager.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let sourceBytes = Data(#"{"name":"Café","count":3}"#.utf8)
        var results: [Result<ConversionRecord, Error>] = []
        var approvals: [ConversionApproval] = []
        let service = AutomaticConverter(engine: try ConversionEngine(),
            historyDirectory: directory.appendingPathComponent("history")) { results.append($0) }
        service.approvalsChanged = { approvals = $0 }
        XCTAssertEqual(service.action, .immediately)
        service.action = .askFirst
        try service.start(folders: [watched])
        defer { service.stop() }

        func move(_ original: URL, _ renamed: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/mv")
            process.arguments = [original.path, renamed.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        func rename(_ name: String) throws -> URL {
            let original = watched.appendingPathComponent(name + ".json")
            let renamed = watched.appendingPathComponent(name + ".yaml")
            try sourceBytes.write(to: original)
            try move(original, renamed)
            return renamed
        }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(condition(), "The watcher did not reach the expected state.")
        }

        let accepted = try rename("accepted")
        try await waitFor { approvals.count == 1 }
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(try Data(contentsOf: accepted), sourceBytes)
        service.decide(try XCTUnwrap(approvals.first).id, convert: true)
        try await waitFor { results.count == 1 }
        let record = try XCTUnwrap(results.first).get()
        XCTAssertEqual(try Data(contentsOf: record.backupURL), sourceBytes)
        XCTAssertTrue(try String(contentsOf: accepted, encoding: .utf8).contains("count: 3"))
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: record.originalURL), sourceBytes)
        XCTAssertTrue(approvals.isEmpty)

        let skipped = try rename("skipped")
        try await waitFor { approvals.count == 1 }
        service.decide(try XCTUnwrap(approvals.first).id, convert: false)
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertEqual(try Data(contentsOf: skipped), sourceBytes)
        XCTAssertEqual(results.count, 1)

        let changed = try rename("changed")
        try await waitFor { approvals.count == 1 }
        let changedBytes = Data(#"{"new":"contents"}"#.utf8)
        try changedBytes.write(to: changed)
        service.decide(try XCTUnwrap(approvals.first).id, convert: true)
        try await waitFor { results.count == 2 }
        XCTAssertThrowsError(try results[1].get())
        XCTAssertEqual(try Data(contentsOf: changed), changedBytes)

        let renamedAgain = try rename("again")
        try await waitFor { approvals.count == 1 }
        let firstApproval = try XCTUnwrap(approvals.first)
        let finalName = renamedAgain.deletingPathExtension().appendingPathExtension("toml")
        try move(renamedAgain, finalName)
        try await waitFor { approvals.first?.renamedURL == finalName }
        XCTAssertEqual(approvals.first?.originalURL.pathExtension, "json")
        service.decide(firstApproval.id, convert: true)
        XCTAssertEqual(results.count, 2)
        service.decide(try XCTUnwrap(approvals.first).id, convert: true)
        try await waitFor { results.count == 3 }
        let secondRecord = try results[2].get()
        _ = try ConversionEngine.undo(secondRecord)
        XCTAssertEqual(try Data(contentsOf: secondRecord.originalURL), sourceBytes)

        let reverted = try rename("reverted")
        try await waitFor { approvals.count == 1 }
        let restoredName = reverted.deletingPathExtension().appendingPathExtension("json")
        try move(reverted, restoredName)
        try await waitFor { approvals.isEmpty }
        XCTAssertEqual(try Data(contentsOf: restoredName), sourceBytes)
        XCTAssertEqual(results.count, 3)

        let held = try rename("held")
        try await waitFor { approvals.count == 1 }
        let heldID = try XCTUnwrap(approvals.first).id
        service.action = .doNotConvert
        XCTAssertTrue(approvals.isEmpty)
        service.decide(heldID, convert: true)
        let ignored = try rename("ignored")
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertEqual(try Data(contentsOf: held), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: ignored), sourceBytes)

        service.action = .askFirst
        let paused = try rename("paused")
        try await waitFor { approvals.count == 1 }
        let pausedID = try XCTUnwrap(approvals.first).id
        await service.stopAndWait()
        service.decide(pausedID, convert: true)
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertEqual(try Data(contentsOf: paused), sourceBytes)
        XCTAssertEqual(results.count, 3)

        service.action = .doNotConvert
        var compact = ConversionSettings()
        compact.configOptions.prettyPrint = false
        let stage = ConversionStageOverride(sourceID: "json", targetID: "yaml", settings: compact)
        service.rules = [ConversionRule(sourceID: "json", targetID: "yaml", action: .immediately,
            settings: ConversionSettings(), stageOverrides: [stage])]
        try service.start(folders: [watched])
        let byRule = try rename("by-rule")
        try await waitFor { results.count == 4 }
        XCTAssertTrue(try String(contentsOf: byRule, encoding: .utf8).contains("{"))
        _ = try ConversionEngine.undo(try results[3].get())
        XCTAssertTrue(service.settings.configOptions.prettyPrint)

        service.rules[0].action = .askFirst
        let aliasOriginal = watched.appendingPathComponent("alias.json")
        let aliasRenamed = watched.appendingPathComponent("alias.yml")
        try sourceBytes.write(to: aliasOriginal)
        try move(aliasOriginal, aliasRenamed)
        try await waitFor { approvals.count == 1 }
        service.decide(try XCTUnwrap(approvals.first).id, convert: true)
        try await waitFor { results.count == 5 }
        XCTAssertTrue(try String(contentsOf: aliasRenamed, encoding: .utf8).contains("{"))
        _ = try ConversionEngine.undo(try results[4].get())

        let oneOff = try rename("one-off")
        try await waitFor { approvals.count == 1 }
        service.decide(try XCTUnwrap(approvals.first).id, convert: true, settings: ConversionSettings(), stageOverrides: [])
        try await waitFor { results.count == 6 }
        XCTAssertFalse(try String(contentsOf: oneOff, encoding: .utf8).contains("{"))
        XCTAssertEqual(service.rules[0].settings, ConversionSettings())
        XCTAssertEqual(service.rules[0].stageOverrides, [stage])
        _ = try ConversionEngine.undo(try results[5].get())

        let affected = try rename("affected")
        try await waitFor { approvals.count == 1 }
        let affectedID = try XCTUnwrap(approvals.first).id
        service.rules.append(ConversionRule(sourceID: "png", targetID: "jpeg", action: .askFirst))
        XCTAssertEqual(approvals.first?.id, affectedID)
        service.rules[0].settings = nil
        XCTAssertEqual(approvals.first?.id, affectedID)
        service.rules[0].action = .doNotConvert
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertFalse(service.decide(affectedID, convert: true))
        service.action = .immediately
        let ruleSkipped = try rename("rule-skipped")
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(results.count, 6)
        XCTAssertEqual(try Data(contentsOf: affected), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: ruleSkipped), sourceBytes)

        service.rules.removeAll()
        let fallback = try rename("fallback")
        try await waitFor { results.count == 7 }
        XCTAssertFalse(try String(contentsOf: fallback, encoding: .utf8).contains("{"))
        let fallbackRecord = try results[6].get()
        _ = try ConversionEngine.undo(fallbackRecord)
        XCTAssertEqual(try Data(contentsOf: fallbackRecord.originalURL), sourceBytes)

        service.keepOriginal = true
        let keptByDefault = try rename("kept-default")
        try await waitFor { results.count == 8 }
        let keptDefaultRecord = try results[7].get()
        XCTAssertEqual(keptDefaultRecord.keepOriginal, true)
        XCTAssertEqual(try Data(contentsOf: keptDefaultRecord.originalURL), sourceBytes)
        XCTAssertNotEqual(try Data(contentsOf: keptByDefault), sourceBytes)
        _ = try ConversionEngine.undo(keptDefaultRecord)
        XCTAssertEqual(try Data(contentsOf: keptDefaultRecord.originalURL), sourceBytes)

        service.rules = [ConversionRule(sourceID: "json", targetID: "yaml", action: .askFirst, keepOriginal: false)]
        _ = try rename("kept-rule-off")
        try await waitFor { approvals.count == 1 }
        service.decide(try XCTUnwrap(approvals.first).id, convert: true)
        try await waitFor { results.count == 9 }
        let ruleOffRecord = try results[8].get()
        XCTAssertNotEqual(ruleOffRecord.keepOriginal, true)
        XCTAssertFalse(manager.fileExists(atPath: ruleOffRecord.originalURL.path))
        _ = try ConversionEngine.undo(ruleOffRecord)

        service.keepOriginal = false
        _ = try rename("kept-one-off")
        try await waitFor { approvals.count == 1 }
        service.decide(try XCTUnwrap(approvals.first).id, convert: true, keepOriginal: true)
        try await waitFor { results.count == 10 }
        let oneOffRecord = try results[9].get()
        XCTAssertEqual(oneOffRecord.keepOriginal, true)
        XCTAssertEqual(try Data(contentsOf: oneOffRecord.originalURL), sourceBytes)
        XCTAssertFalse(service.keepOriginal)
        XCTAssertEqual(service.rules[0].keepOriginal, false)
        _ = try ConversionEngine.undo(oneOffRecord)

        service.rules[0].keepOriginal = true
        _ = try rename("kept-rule-on")
        try await waitFor { approvals.count == 1 }
        service.decide(try XCTUnwrap(approvals.first).id, convert: true)
        try await waitFor { results.count == 11 }
        let ruleOnRecord = try results[10].get()
        XCTAssertEqual(ruleOnRecord.keepOriginal, true)
        XCTAssertEqual(try Data(contentsOf: ruleOnRecord.originalURL), sourceBytes)
        _ = try ConversionEngine.undo(ruleOnRecord)

        var queued = 0
        var active = 0
        service.activity = { jobs, waiting, _ in active = jobs; queued = waiting }
        service.rules.removeAll()
        service.action = .immediately
        service.keepOriginal = false
        service.maintenanceInProgress = true
        let duringMaintenance = try rename("maintenance")
        try await waitFor { queued == 1 }
        XCTAssertEqual(active, 0)
        XCTAssertEqual(results.count, 11)
        XCTAssertEqual(try Data(contentsOf: duringMaintenance), sourceBytes)
        service.maintenanceInProgress = false
        try await waitFor { results.count == 12 }
        _ = try ConversionEngine.undo(try results[11].get())

        service.action = .askFirst
        let confirmedWhileHeld = try rename("confirmed-maintenance")
        try await waitFor { approvals.count == 1 }
        service.maintenanceInProgress = true
        service.decide(try XCTUnwrap(approvals.first).id, convert: true, settings: compact, keepOriginal: false)
        XCTAssertEqual(queued, 1)
        service.keepOriginal = true
        service.settings.configOptions.prettyPrint = true
        service.maintenanceInProgress = false
        try await waitFor { results.count == 13 }
        let heldRecord = try results[12].get()
        XCTAssertNotEqual(heldRecord.keepOriginal, true)
        XCTAssertFalse(manager.fileExists(atPath: heldRecord.originalURL.path))
        XCTAssertTrue(try String(contentsOf: confirmedWhileHeld, encoding: .utf8).contains("{"))
        _ = try ConversionEngine.undo(heldRecord)
        await service.stopAndWait()
    }

    @MainActor
    func testLowFreeSpaceIsMeasuredAgainstTheSourceSize() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let file = work.appendingPathComponent("source.json")
        try Data(count: 1_048_576).write(to: file)
        let version = try SourceVersion(file)
        // A one MiB source needs twice that plus the 128 MiB margin, so 130 MiB.
        XCTAssertTrue(AutomaticConverter.isLowOnSpace(available: 0, source: version))
        XCTAssertTrue(AutomaticConverter.isLowOnSpace(available: 129 * 1_048_576, source: version))
        XCTAssertFalse(AutomaticConverter.isLowOnSpace(available: 130 * 1_048_576, source: version))
        XCTAssertFalse(AutomaticConverter.isLowOnSpace(available: 4 * 1_073_741_824, source: version))
        XCTAssertNotNil(AutomaticConverter.availableSpace(beside: file))
        XCTAssertNil(AutomaticConverter.availableSpace(beside: URL(fileURLWithPath: "/nonexistent-volume/x/y")))
    }

    @MainActor
    func testLostEventsRestartMonitoringAndGiveUpAfterRepeats() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watched = work.appendingPathComponent("watched")
        try manager.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let engine = try ConversionEngine()
        var failures: [String] = []
        var monitoring = false
        let service = AutomaticConverter(engine: engine, historyDirectory: work.appendingPathComponent("history")) {
            if case .failure(let error) = $0 { failures.append(error.localizedDescription) }
        }
        service.activity = { _, _, active in monitoring = active }
        try service.start(folders: [watched])
        defer { service.stop() }
        XCTAssertTrue(monitoring)
        let dropped = FileEvent(url: watched, inode: nil, flags: UInt32(kFSEventStreamEventFlagKernelDropped), id: 1)
        XCTAssertTrue(dropped.requiresRescan)

        service.accept([dropped])
        XCTAssertTrue(monitoring)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(try XCTUnwrap(failures.last).contains("Monitoring restarted"))

        // A settled batch clears the streak, so ordinary occasional drops never accumulate.
        service.accept([FileEvent(url: watched.appendingPathComponent("x.json"), inode: nil, flags: 0, id: 2)])
        for _ in 0..<3 { service.accept([dropped]) }
        XCTAssertTrue(monitoring)
        XCTAssertEqual(failures.count, 4)
        service.accept([dropped])
        XCTAssertFalse(monitoring)
        XCTAssertTrue(try XCTUnwrap(failures.last).contains("needs to be restarted"))

        // A manual restart begins a new recovery streak.
        try service.start(folders: [watched])
        service.accept([dropped])
        XCTAssertTrue(monitoring)
        XCTAssertTrue(try XCTUnwrap(failures.last).contains("Monitoring restarted"))
    }

    @MainActor
    func testLostEventsStopMonitoringWhenTheWatchedFolderIsGone() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watched = work.appendingPathComponent("watched")
        try manager.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let engine = try ConversionEngine()
        var failures: [String] = []
        var monitoring = false
        let service = AutomaticConverter(engine: engine, historyDirectory: work.appendingPathComponent("history")) {
            if case .failure(let error) = $0 { failures.append(error.localizedDescription) }
        }
        service.activity = { _, _, active in monitoring = active }
        try service.start(folders: [watched])
        defer { service.stop() }
        try manager.removeItem(at: watched)
        service.accept([FileEvent(url: watched, inode: nil, flags: UInt32(kFSEventStreamEventFlagRootChanged), id: 1)])
        XCTAssertFalse(monitoring)
        XCTAssertTrue(try XCTUnwrap(failures.last).contains("needs to be restarted"))
    }
}
