import Foundation
import ConversionCore
import Observation

@MainActor
@Observable
final class ConversionModel {
    enum Tab: Hashable { case automatic, manual, history, settings }
    var tab = Tab.automatic
    let appSettings: AppSettings
    var engine: ConversionEngine?
    var source: URL? { didSet { if source != oldValue { manualStageOverrides = [] } } }
    var targets: [FileFormat] = []
    var embeddedSubtitleTracks: [EmbeddedSubtitleTrack] = []
    var targetID = "" { didSet { if targetID != oldValue { manualStageOverrides = [] } } }
    var manualStageOverrides: [ConversionStageOverride] = []
    var settings = ConversionSettings() { didSet { saveOptions() } }
    var keepOriginal = false {
        didSet {
            defaults.set(keepOriginal, forKey: PreferenceKey.keepOriginal)
            automatic?.keepOriginal = keepOriginal
        }
    }
    var convertNewFiles = false {
        didSet {
            defaults.set(convertNewFiles, forKey: PreferenceKey.convertNewFiles)
            automatic?.convertNewFiles = convertNewFiles
        }
    }
    var convertMultipleFormats = false {
        didSet {
            defaults.set(convertMultipleFormats, forKey: PreferenceKey.convertMultipleFormats)
            automatic?.convertMultipleFormats = convertMultipleFormats
        }
    }
    var rules: [ConversionRule] = [] {
        didSet {
            defaults.set(try? JSONEncoder().encode(rules), forKey: PreferenceKey.conversionRules)
            automatic?.rules = rules
        }
    }
    var folders: [URL] = []
    var exclusions: [URL] = []
    var watchWholeSystem = false
    var ignoreSystemFiles = true {
        didSet {
            defaults.set(ignoreSystemFiles, forKey: PreferenceKey.ignoreSystemFiles)
            if monitoring, ignoreSystemFiles != oldValue { setMonitoring(true) }
        }
    }
    var diskAccess = DiskAccess.notChecked
    var checkingDiskAccess = false
    @ObservationIgnored var readDiskAccess: @Sendable () -> DiskAccess = { DiskAccess.check() }
    var accessCheckGeneration = UUID()
    var monitoring = false
    var automaticAction = AutomaticConversionAction.immediately {
        didSet {
            defaults.set(automaticAction.rawValue, forKey: PreferenceKey.automaticAction)
            automatic?.action = automaticAction
        }
    }
    var approvals: [ConversionApproval] = []
    var activeJobs = 0 { didSet { if activeJobs == 0 { startWaitingCleanup() } } }
    var queuedJobs = 0
    var history: [ConversionRecord] = [] {
        didSet { historyByID = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) }) }
    }
    var historyByID: [UUID: ConversionRecord] = [:]
    var historyJobs: [UUID: ConversionActivity] = [:]
    var hiddenHistoryIDs: Set<UUID> = []
    var historyIssue: String?
    var clearingHistory = false
    @ObservationIgnored var historyWriter: Task<Void, Never>?
    @ObservationIgnored var manualJobID: UUID?
    var automaticStatus = "Add a folder to begin."
    var busy = false { didSet { if !busy { startWaitingCleanup() } } }
    var retention = BackupRetentionOptions() {
        didSet {
            defaults.set(try? JSONEncoder().encode(retention), forKey: PreferenceKey.backupRetention)
            scheduleBackupCleanup()
        }
    }
    var cleaningBackups = false
    var retentionStatus = "Backups stay until a limit is applied or they are cleared."
    var status = "Preparing converters…"
    var error: String?
    var savedFile: URL?
    // Synchronous conversion runs outside the UI actor. This handle owns cancellation.
    var worker: Task<Void, Error>?
    var manualCompletion: Task<Void, Never>?
    var workerCanCancel = false
    var automatic: AutomaticConverter?
    var cleanupTimer: Timer?
    var cleanupWorker: Task<BackupCleanupResult, Error>?
    var cleanupWaiting = false
    var clearBackupsRequested = false
    var isQuitting = false
    let defaults: UserDefaults
    let historyDirectory: URL

    var target: FileFormat? { targets.first { $0.id == targetID } }
    var canCancel: Bool { worker != nil && workerCanCancel }
    var canMonitor: Bool { watchWholeSystem || !folders.isEmpty }
    var monitoringFolders: [URL] { watchWholeSystem ? [URL(fileURLWithPath: "/")] : folders }

    init(defaults: UserDefaults = .standard, historyDirectory: URL? = nil) {
        self.defaults = defaults
        self.appSettings = AppSettings(defaults: defaults)
        self.historyDirectory = historyDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Allomer/History", isDirectory: true)
        if let data = defaults.data(forKey: PreferenceKey.backupRetention) {
            do {
                let options = try JSONDecoder().decode(BackupRetentionOptions.self, from: data)
                try options.validate()
                _retention = options
            } catch {
                _retentionStatus = "Saved backup limits could not be read. Automatic cleanup is disabled."
            }
        }
        _keepOriginal = defaults.bool(forKey: PreferenceKey.keepOriginal)
        _convertNewFiles = defaults.bool(forKey: PreferenceKey.convertNewFiles)
        _convertMultipleFormats = defaults.bool(forKey: PreferenceKey.convertMultipleFormats)
        _watchWholeSystem = defaults.bool(forKey: PreferenceKey.watchWholeSystem)
        _ignoreSystemFiles = defaults.object(forKey: PreferenceKey.ignoreSystemFiles) as? Bool ?? true
        _automaticAction = defaults.string(forKey: PreferenceKey.automaticAction)
            .flatMap(AutomaticConversionAction.init(rawValue:)) ?? .immediately
        if let data = defaults.data(forKey: PreferenceKey.conversionSettings),
           let saved = try? JSONDecoder().decode(ConversionSettings.self, from: data) {
            _settings = saved
        } else {
            _settings.imageOptions = saved(ImageOptions.self, key: PreferenceKey.legacyImageOptions) ?? ImageOptions()
            _settings.documentOptions = saved(DocumentOptions.self, key: PreferenceKey.legacyDocumentOptions) ?? DocumentOptions()
            _settings.mediaOptions = saved(MediaOptions.self, key: PreferenceKey.legacyMediaOptions) ?? MediaOptions()
            _settings.subtitleOptions = saved(SubtitleOptions.self, key: PreferenceKey.legacySubtitleOptions) ?? SubtitleOptions()
            _settings.configOptions = saved(ConfigOptions.self, key: PreferenceKey.legacyConfigOptions) ?? ConfigOptions()
            _settings.archiveOptions = saved(ArchiveOptions.self, key: PreferenceKey.legacyArchiveOptions) ?? ArchiveOptions()
            _settings.spreadsheetOptions = saved(SpreadsheetOptions.self, key: PreferenceKey.legacySpreadsheetOptions) ?? SpreadsheetOptions()
            _settings.emailOptions = saved(EmailOptions.self, key: PreferenceKey.legacyEmailOptions) ?? EmailOptions()
            _settings.modelOptions = saved(ModelOptions.self, key: PreferenceKey.legacyModelOptions) ?? ModelOptions()
            _settings.postScriptOptions = saved(PostScriptOptions.self, key: PreferenceKey.legacyPostScriptOptions) ?? PostScriptOptions()
            _settings.pdfOptions = saved(PDFOptions.self, key: PreferenceKey.legacyPDFOptions) ?? PDFOptions()
        }
        if let data = defaults.data(forKey: PreferenceKey.conversionRules) {
            do {
                _rules = try JSONDecoder().decode([ConversionRule].self, from: data)
                let knownIDs = Set(try FormatCatalog().formats.map(\.id))
                guard Set(rules.map(\.id)).count == rules.count,
                      rules.allSatisfy({ rule in
                          let stages = rule.stageOverrides ?? []
                          return rule.sourceID != rule.targetID && knownIDs.contains(rule.sourceID) && knownIDs.contains(rule.targetID)
                              && stages.count <= 256 && Set(stages.map(\.id)).count == stages.count
                              && stages.allSatisfy { ($0.sourceID.map { knownIDs.contains($0) } ?? true) && knownIDs.contains($0.targetID) }
                      }) else {
                    throw ConversionError.message("Saved rules contain duplicate, identical, or unknown formats.")
                }
            } catch {
                _rules = []
                _automaticAction = .askFirst
                defaults.set(AutomaticConversionAction.askFirst.rawValue, forKey: PreferenceKey.automaticAction)
                _error = "Saved format rules could not be read. Automatic conversion will ask first."
            }
        }
    }

    func load() async {
        guard engine == nil, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            guard let tools = ConversionEngine.bundledToolsDirectory else {
                throw ConversionError.message("Conversion tools are missing. Reinstall the app.")
            }
            let engine = try await Task.detached(priority: .utility) {
                try ConversionEngine(toolsDirectory: tools)
            }.value
            folders = resolveFolders(key: PreferenceKey.watchedFolders)
            exclusions = resolveFolders(key: PreferenceKey.excludedFolders)
            let historyDirectory = historyDirectory
            var historyLoaded = true
            do {
                history = try await Task.detached(priority: .utility) {
                    try ConversionRecord.loadHistory(from: historyDirectory)
                }.value
                try await loadJobHistory()
            } catch {
                historyLoaded = false
                self.error = "History could not be loaded: \(error.localizedDescription)"
                automaticStatus = "History needs review before monitoring resumes."
            }
            let service = AutomaticConverter(engine: engine, historyDirectory: historyDirectory) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let record):
                    history.removeAll { $0.id == record.id }
                    history.insert(record, at: 0)
                    automaticStatus = record.outputURLs.count == 1 ? "Converted \(record.convertedURL.lastPathComponent)."
                        : "Created \(record.outputURLs.count) outputs."
                    for output in record.outputURLs { appSettings.converted(output) }
                    if let issues = record.multipleOutputs?.issues, !issues.isEmpty {
                        automaticStatus += " Some outputs were skipped. See History."
                        self.error = issues.joined(separator: "\n")
                        appSettings.failed(issues.joined(separator: "\n"))
                    }
                    scheduleBackupCleanup()
                case .failure(let error):
                    self.error = error.localizedDescription
                    automaticStatus = "Conversion needs attention."
                    appSettings.failed(error.localizedDescription)
                }
            }
            service.activity = { [weak self] active, queued, monitoring in
                self?.activeJobs = active
                self?.queuedJobs = queued
                self?.monitoring = monitoring
            }
            service.jobChanged = { [weak self] job in self?.recordJob(job) }
            service.action = automaticAction
            service.rules = rules
            service.keepOriginal = keepOriginal
            service.convertNewFiles = convertNewFiles
            service.convertMultipleFormats = convertMultipleFormats
            service.approvalsChanged = { [weak self] approvals in
                self?.approvals = approvals
            }
            automatic = service
            saveOptions()
            if watchWholeSystem { await refreshDiskAccess() }
            if historyLoaded, defaults.bool(forKey: PreferenceKey.monitoring), canMonitor { setMonitoring(true) }
            // Enable controls only after settings, history, and the watcher are ready.
            self.engine = engine
            status = "Choose a file or drop one here."
            scheduleBackupCleanup()
        } catch {
            self.error = error.localizedDescription
            status = "The app could not start its converters."
        }
    }

    private func saved<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func saveOptions() {
        defaults.set(try? JSONEncoder().encode(settings), forKey: PreferenceKey.conversionSettings)
        automatic?.settings = settings
        automatic?.cpuProfile = settings.mediaOptions.cpuProfile
    }
}
