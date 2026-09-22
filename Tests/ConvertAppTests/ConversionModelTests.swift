import Observation
import ConversionCore
import os
import XCTest
@testable import ConvertApp

final class ConversionModelTests: XCTestCase {
    @MainActor
    func testMonitoringScopePreferencesAndAccessChecks() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ConversionModel(defaults: defaults)
        XCTAssertFalse(model.watchWholeSystem)
        XCTAssertTrue(model.ignoreSystemFiles)
        XCTAssertFalse(model.canMonitor)
        XCTAssertEqual(model.diskAccess, .notChecked)
        XCTAssertNil(defaults.persistentDomain(forName: suite))
        let folder = URL(fileURLWithPath: "/Users/MonitoringFixture/Documents")
        model.folders = [folder]
        XCTAssertEqual(model.monitoringFolders, [folder])
        XCTAssertTrue(model.canMonitor)
        model.readDiskAccess = { .unavailable }
        await model.setWatchWholeSystem(true)
        XCTAssertFalse(model.watchWholeSystem)
        XCTAssertEqual(model.diskAccess, .unavailable)
        XCTAssertEqual(model.monitoringFolders, [folder])
        model.readDiskAccess = { .available }
        await model.setWatchWholeSystem(true)
        XCTAssertTrue(model.watchWholeSystem)
        XCTAssertEqual(model.monitoringFolders.map(\.path), ["/"])
        XCTAssertEqual(model.folders, [folder])
        model.ignoreSystemFiles = false
        let saved = defaults.persistentDomain(forName: suite) as NSDictionary?
        let reloaded = ConversionModel(defaults: defaults)
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, saved)
        XCTAssertTrue(reloaded.watchWholeSystem)
        XCTAssertFalse(reloaded.ignoreSystemFiles)
        XCTAssertEqual(reloaded.diskAccess, .notChecked)
        reloaded.readDiskAccess = { .unavailable }
        await reloaded.refreshDiskAccess()
        XCTAssertFalse(reloaded.watchWholeSystem)
        XCTAssertFalse(ConversionModel(defaults: defaults).watchWholeSystem)
        await model.setWatchWholeSystem(false)
        XCTAssertEqual(model.monitoringFolders, [folder])

        let started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        model.readDiskAccess = {
            started.withLock { $0 = true }
            _ = release.wait(timeout: .now() + 5)
            return .available
        }
        let request = Task { await model.setWatchWholeSystem(true) }
        let deadline = Date().addingTimeInterval(3)
        while !started.withLock({ $0 }), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.checkingDiskAccess)
        await model.setWatchWholeSystem(false)
        release.signal()
        await request.value
        XCTAssertFalse(model.watchWholeSystem)
        XCTAssertFalse(model.checkingDiskAccess)
        XCTAssertEqual(model.monitoringFolders, [folder])
    }

    func testDirectoryAccessProbeUsesOnlyTemporaryFolders() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let missing = work.appendingPathComponent("missing")
        XCTAssertEqual(DiskAccess.check(directories: [missing]), .unknown)
        XCTAssertEqual(DiskAccess.check(directories: [work, missing]), .available)
        let link = work.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: work)
        XCTAssertEqual(DiskAccess.check(directories: [link]), .unknown)
        let denied = work.appendingPathComponent("denied")
        try manager.createDirectory(at: denied, withIntermediateDirectories: false)
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        if getuid() != 0 { XCTAssertEqual(DiskAccess.check(directories: [work, denied]), .unavailable) }
    }

    @MainActor
    func testRetentionPreferencesAndControllerCleanup() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = ConversionModel(defaults: defaults)
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer {
            model.applyRetention(BackupRetentionOptions())
            defaults.removePersistentDomain(forName: suite)
            try? manager.removeItem(at: work)
        }
        let engine = try ConversionEngine()
        let original = work.appendingPathComponent("original.json")
        let renamed = work.appendingPathComponent("original.yaml")
        let bytes = Data(#"{"value":3}"#.utf8)
        try bytes.write(to: renamed)
        let record = try engine.convertRenamedFile(from: original, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), keepOriginal: true)
        let output = try Data(contentsOf: renamed)
        model.engine = engine
        model.history = [record]
        var options = BackupRetentionOptions()
        options.limitSize = true
        options.maximumSizeGiB = 1 / 1_073_741_824
        model.applyRetention(options)
        let saved = defaults.persistentDomain(forName: suite) as NSDictionary?
        let reloaded = ConversionModel(defaults: defaults)
        XCTAssertEqual(reloaded.retention, options)
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, saved)
        var invalid = options
        invalid.maximumSizeGiB = .nan
        model.applyRetention(invalid)
        XCTAssertEqual(model.retention, options)
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, saved)
        XCTAssertTrue(model.retentionStatus.contains("not changed"))
        await model.cleanupBackups()
        XCTAssertFalse(model.cleaningBackups)
        XCTAssertEqual(model.history.first?.backupState, .removed)
        XCTAssertEqual(model.history.first?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Data(contentsOf: renamed), output)
        XCTAssertTrue(model.retentionStatus.contains("Removed 1"))
        defaults.set(Data("broken".utf8), forKey: "backupRetention")
        let damaged = ConversionModel(defaults: defaults)
        XCTAssertFalse(damaged.retention.limitSize)
        XCTAssertFalse(damaged.retention.limitAge)
        XCTAssertTrue(damaged.retentionStatus.contains("disabled"))

        model.applyRetention(BackupRetentionOptions())
        let nextOriginal = work.appendingPathComponent("next.json")
        let nextRenamed = work.appendingPathComponent("next.yaml")
        try bytes.write(to: nextRenamed)
        let next = try engine.convertRenamedFile(from: nextOriginal, to: nextRenamed,
            historyDirectory: work.appendingPathComponent("history"))
        let nextOutput = try Data(contentsOf: nextRenamed)
        model.history.append(next)
        model.busy = true
        model.activeJobs = 1
        model.requestClearBackups()
        let deadline = Date().addingTimeInterval(5)
        while !model.retentionStatus.contains("Waiting"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.retentionStatus.contains("Waiting"))
        model.busy = false
        await model.cleanupBackups()
        XCTAssertNil(model.history.last?.backupState)
        XCTAssertTrue(manager.fileExists(atPath: next.backupURL.path))
        model.activeJobs = 0
        let completion = Date().addingTimeInterval(5)
        while model.history.last?.backupState != .removed, Date() < completion {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.history.last?.backupState, .removed)
        XCTAssertFalse(model.cleaningBackups)
        XCTAssertEqual(try Data(contentsOf: nextRenamed), nextOutput)
    }

    @MainActor
    func testPairSettingsPersistApartFromDefaults() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacyImages = ImageOptions()
        legacyImages.quality = 0.47
        var legacyConfig = ConfigOptions()
        legacyConfig.binaryPlist = true
        defaults.set(try JSONEncoder().encode(legacyImages), forKey: "imageOptions")
        defaults.set(try JSONEncoder().encode(legacyConfig), forKey: "configOptions")
        let savedPreferences = defaults.persistentDomain(forName: suite) as NSDictionary?
        let model = ConversionModel(defaults: defaults)
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, savedPreferences)
        XCTAssertEqual(model.settings.imageOptions, legacyImages)
        XCTAssertEqual(model.settings.configOptions, legacyConfig)
        var selected = model.settings
        selected.imageOptions.quality = 0.25
        selected.configOptions.prettyPrint = false
        let stage = ConversionStageOverride(sourceID: "png", targetID: "jpeg", settings: selected)
        let rule = ConversionRule(sourceID: "png", targetID: "jpeg", action: .askFirst, settings: selected, stageOverrides: [stage])
        model.saveRule(rule)
        model.settings.imageOptions.quality = 0.9
        let reloaded = ConversionModel(defaults: defaults)
        XCTAssertEqual(reloaded.settings.imageOptions.quality, 0.9)
        XCTAssertEqual(reloaded.settings.configOptions, legacyConfig)
        XCTAssertEqual(reloaded.rules, [rule])
        var legacyRule = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        legacyRule.removeValue(forKey: "stageOverrides")
        XCTAssertNil(try JSONDecoder().decode(ConversionRule.self, from: JSONSerialization.data(withJSONObject: legacyRule)).stageOverrides)
        reloaded.manualStageOverrides = [stage]
        reloaded.targetID = "jpeg"
        XCTAssertTrue(reloaded.manualStageOverrides.isEmpty)
        reloaded.manualStageOverrides = [stage]
        reloaded.source = URL(fileURLWithPath: "/unused/test.png")
        XCTAssertTrue(reloaded.manualStageOverrides.isEmpty)
        XCTAssertFalse(reloaded.keepOriginal)
        XCTAssertFalse(reloaded.convertNewFiles)
        XCTAssertFalse(reloaded.convertMultipleFormats)
        reloaded.convertMultipleFormats = true
        XCTAssertTrue(ConversionModel(defaults: defaults).convertMultipleFormats)
        reloaded.convertNewFiles = true
        XCTAssertTrue(ConversionModel(defaults: defaults).convertNewFiles)
        reloaded.keepOriginal = true
        XCTAssertTrue(ConversionModel(defaults: defaults).keepOriginal)
        var replacement = rule
        replacement.action = .doNotConvert
        replacement.keepOriginal = false
        reloaded.saveRule(replacement)
        XCTAssertEqual(reloaded.rules, [replacement])
        replacement.targetID = "webp"
        replacement.settings = nil
        reloaded.saveRule(replacement, replacing: rule.id)
        XCTAssertEqual(ConversionModel(defaults: defaults).rules, [replacement])
        reloaded.removeRule(replacement)
        XCTAssertTrue(ConversionModel(defaults: defaults).rules.isEmpty)
        defaults.set(Data("invalid".utf8), forKey: "conversionRules")
        let damaged = ConversionModel(defaults: defaults)
        XCTAssertEqual(damaged.automaticAction, .askFirst)
        XCTAssertNotNil(damaged.error)
        XCTAssertTrue(damaged.rules.isEmpty)
        defaults.set(try JSONEncoder().encode([rule, rule]), forKey: "conversionRules")
        XCTAssertEqual(ConversionModel(defaults: defaults).automaticAction, .askFirst)
        var duplicatedStages = rule
        duplicatedStages.stageOverrides = [stage, stage]
        defaults.set(try JSONEncoder().encode([duplicatedStages]), forKey: "conversionRules")
        XCTAssertTrue(ConversionModel(defaults: defaults).rules.isEmpty)
        duplicatedStages.stageOverrides = [.init(sourceID: "missing", targetID: "jpeg", settings: selected)]
        defaults.set(try JSONEncoder().encode([duplicatedStages]), forKey: "conversionRules")
        XCTAssertTrue(ConversionModel(defaults: defaults).rules.isEmpty)
        replacement.sourceID = "unknown-format"
        defaults.set(try JSONEncoder().encode([replacement]), forKey: "conversionRules")
        XCTAssertEqual(ConversionModel(defaults: defaults).automaticAction, .askFirst)
    }

    @MainActor
    func testAutomaticActionPersistsWithoutChangingOtherSettings() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "monitoring")
        XCTAssertEqual(ConversionModel(defaults: defaults).automaticAction, .immediately)
        for action in AutomaticConversionAction.allCases {
            ConversionModel(defaults: defaults).automaticAction = action
            XCTAssertEqual(ConversionModel(defaults: defaults).automaticAction, action)
            XCTAssertTrue(defaults.bool(forKey: "monitoring"))
        }
    }

    @MainActor
    func testObservationTracksOnlyUsedValues() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ConversionModel(defaults: defaults)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = model.activeJobs
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        model.queuedJobs = 1
        model.status = "Unrelated status update"
        XCTAssertEqual(changes.withLock { $0 }, 0)
        model.activeJobs = 1
        XCTAssertEqual(changes.withLock { $0 }, 1)
        XCTAssertEqual(model.activeJobs, 1)
    }

    @MainActor
    func testMissingConversionToolsFailLoudlyRatherThanOfferingFewerFormats() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // A test bundle has no Contents/Helpers, which is the shape of a damaged install.
        XCTAssertNil(ConversionEngine.bundledToolsDirectory)
        let model = ConversionModel(defaults: defaults)
        await model.load()
        // The point of this check: an incomplete install must not quietly offer a reduced
        // catalogue of formats. It refuses, names the cause, and says what to do about it.
        XCTAssertNil(model.engine)
        XCTAssertEqual(model.error, "Conversion tools are missing. Reinstall the app.")
        XCTAssertEqual(model.status, "The app could not start its converters.")
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.targets.isEmpty)
    }
}
