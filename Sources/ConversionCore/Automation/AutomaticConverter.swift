import Darwin
import Foundation

public enum AutomaticConversionAction: String, Codable, CaseIterable, Sendable {
    case immediately, askFirst = "ask_first", doNotConvert = "do_not_convert"

    public var title: String {
        switch self {
        case .immediately: "Convert immediately"
        case .askFirst: "Ask first"
        case .doNotConvert: "Do not convert"
        }
    }
}

public struct ConversionApproval: Identifiable, Sendable {
    public let id: UUID
    public let originalURL: URL
    public let renamedURL: URL
    public var detectedSourceID: String? = nil
    public var inputURL: URL? = nil
}

@MainActor
public final class AutomaticConverter {
    private struct Key: Hashable { let device: Int32; let inode: UInt64 }
    private struct Pending {
        var events: [URL: FileEvent] = [:]
        var version: SourceVersion?
        var lastEvent = Date()
        var canBeArrival = false
    }
    private struct Request {
        let id = UUID()
        let date = Date()
        let key: Key
        let original: URL
        let renamed: URL
        let version: SourceVersion
        var isNewFile = false
        var detectedSourceID: String?
        var confirmedSettings: ConversionSettings?
        var confirmedStageOverrides: [ConversionStageOverride]?
        var confirmedKeepOriginal: Bool?
        var multiple: MultipleOutputName?
        var selections: [Selection]?
        var configurations: [ConversionActivity.Configuration] = []
    }
    private struct Selection {
        let id = UUID()
        let url: URL
        var pending: Bool
        var settings: ConversionSettings?
        var keepOriginal: Bool
        var stageOverrides: [ConversionStageOverride]
    }
    private struct Running {
        let request: Request
        let task: Task<ConversionRecord, Error>
    }
    private struct Detecting {
        let request: Request
        let task: Task<FileFormat?, Error>
    }

    private let engine: ConversionEngine
    private let historyDirectory: URL
    private let receive: (Result<ConversionRecord, Error>) -> Void
    private var events: FolderEvents?
    private var generation = UUID()
    private var pending: [Key: Pending] = [:]
    private var ready: [Request] = []
    private var queueIndex = 0
    private var running: [Key: Running] = [:]
    private var detecting: [Key: Detecting] = [:]
    private var completions: [UUID: Task<Void, Never>] = [:]
    private var waiting: [Key: Request] = [:]
    private var monitoring: Monitoring?
    private var recoveries = 0
    private var timer: Task<Void, Never>?
    public var cpuProfile = CPUProfile.medium
    public var maintenanceInProgress = false {
        didSet { if !maintenanceInProgress { pump() } }
    }
    public var action = AutomaticConversionAction.immediately {
        didSet {
            if action != oldValue {
                for request in waiting.values { report(request, state: .cancelled, message: "The default action changed.") }
                waiting.removeAll()
                reportApprovals()
            }
        }
    }
    public var approvalsChanged: (([ConversionApproval]) -> Void)?
    public var jobChanged: ((ConversionActivity) -> Void)?
    public var settings = ConversionSettings()
    public var keepOriginal = false
    public var convertNewFiles = false {
        didSet {
            guard !convertNewFiles, oldValue else { return }
            for job in detecting.values where job.request.isNewFile { job.task.cancel() }
            for job in running.values where job.request.isNewFile { job.task.cancel() }
            for index in (queueIndex..<ready.count).reversed() where ready[index].isNewFile {
                report(ready[index], state: .cancelled, message: "New-file conversion was disabled.")
                ready.remove(at: index)
            }
            for request in waiting.values where request.isNewFile { report(request, state: .cancelled, message: "New-file conversion was disabled.") }
            waiting = waiting.filter { !$0.value.isNewFile }
            pending = pending.filter { _, group in
                group.events.keys.contains { !FileManager.default.fileExists(atPath: $0.path) }
            }
            reportApprovals()
            reportActivity()
        }
    }
    public var convertMultipleFormats = false {
        didSet {
            guard !convertMultipleFormats, oldValue else { return }
            for job in detecting.values where job.request.multiple != nil { job.task.cancel() }
            for job in running.values where job.request.multiple != nil { job.task.cancel() }
            for index in (queueIndex..<ready.count).reversed() where ready[index].multiple != nil {
                report(ready[index], state: .cancelled, message: "Multiple-format conversion was disabled.")
                ready.remove(at: index)
            }
            for request in waiting.values where request.multiple != nil { report(request, state: .cancelled, message: "Multiple-format conversion was disabled.") }
            waiting = waiting.filter { $0.value.multiple == nil }
            reportApprovals()
            reportActivity()
        }
    }
    public var rules: [ConversionRule] = [] {
        didSet {
            waiting = waiting.filter { _, request in
                let unchanged = (request.multiple?.targets.map(\.url) ?? [request.renamed]).allSatisfy { target in
                    (rule(for: request, target: target, in: oldValue)?.action ?? action)
                        == (rule(for: request, target: target, in: rules)?.action ?? action)
                }
                if !unchanged { report(request, state: .cancelled, message: "The format rule changed.") }
                return unchanged
            }
            reportApprovals()
        }
    }
    public var activity: ((Int, Int, Bool) -> Void)?

    public init(engine: ConversionEngine, historyDirectory: URL,
                receive: @escaping (Result<ConversionRecord, Error>) -> Void) {
        self.engine = engine
        self.historyDirectory = historyDirectory
        self.receive = receive
    }

    private struct Monitoring {
        let folders: [URL]
        let excluding: [URL]
        let ignoreSystemFiles: Bool
    }

    public func start(folders: [URL], excluding: [URL] = [], ignoreSystemFiles: Bool = false) throws {
        stop()
        let configuration = Monitoring(folders: folders.map { $0.resolvingSymlinksInPath().standardizedFileURL },
                                       excluding: excluding, ignoreSystemFiles: ignoreSystemFiles)
        try arm(configuration)
        monitoring = configuration
        recoveries = 0
        reportActivity()
    }

    private func arm(_ configuration: Monitoring) throws {
        // A retained URL answers from its own cached resource values, so a folder removed after
        // monitoring started would still look present. Ask the filesystem instead.
        guard configuration.folders.allSatisfy({ folder in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }) else {
            throw ConversionError.message("A watched folder is no longer available. Choose it again.")
        }
        generation = UUID()
        let generation = generation
        events = try FolderEvents(folders: configuration.folders, excluding: configuration.excluding,
                                  ignoreSystemFiles: configuration.ignoreSystemFiles, ignoreOwnChanges: true) { [weak self] batch in
            Task { @MainActor [weak self] in
                guard self?.generation == generation else { return }
                self?.accept(batch)
            }
        }
    }

    // A dropped batch means some renames were never seen. Build a fresh stream so monitoring
    // survives it, and leave queued, waiting and running work alone. Pending event groups are
    // cleared because their paths may be stale. A folder that is genuinely gone fails here.
    private func rearm() -> Bool {
        guard let monitoring else { return false }
        events?.stop()
        events = nil
        timer?.cancel()
        timer = nil
        pending.removeAll()
        do { try arm(monitoring) } catch { return false }
        return true
    }

    public func stop() {
        generation = UUID()
        monitoring = nil
        events?.stop()
        events = nil
        timer?.cancel()
        timer = nil
        pending.removeAll()
        for request in ready[queueIndex...] { report(request, state: .cancelled, message: "Monitoring stopped.") }
        for request in waiting.values { report(request, state: .cancelled, message: "Monitoring stopped.") }
        ready.removeAll()
        waiting.removeAll()
        reportApprovals()
        queueIndex = 0
        for job in running.values { job.task.cancel() }
        for job in detecting.values { job.task.cancel() }
        reportActivity()
    }

    public func stopAndWait() async {
        stop()
        let tasks = running.values.map(\.task)
        let probes = detecting.values.map(\.task)
        let completions = Array(completions.values)
        for task in tasks { _ = try? await task.value }
        for task in probes { _ = try? await task.value }
        for completion in completions { await completion.value }
    }

    @discardableResult
    public func cancel(_ id: UUID) -> Bool {
        if let job = running.values.first(where: { $0.request.id == id }) { job.task.cancel(); return true }
        if let job = detecting.values.first(where: { $0.request.id == id }) { job.task.cancel(); return true }
        if let entry = waiting.first(where: { $0.value.id == id }) {
            waiting.removeValue(forKey: entry.key)
            report(entry.value, state: .cancelled, message: "Cancelled before conversion.")
            reportApprovals()
            return true
        }
        if let index = (queueIndex..<ready.count).first(where: { ready[$0].id == id }) {
            let request = ready.remove(at: index)
            report(request, state: .cancelled, message: "Cancelled while queued.")
            reportActivity()
            return true
        }
        return false
    }

    private func report(_ request: Request, state: ConversionActivity.State, message: String? = nil,
                        outputs: [URL]? = nil) {
        guard let jobChanged else { return }
        var entry = ConversionActivity(id: request.id, date: request.date, originalURL: request.original,
            requestedURL: request.renamed, outputURLs: outputs ?? request.multiple?.targets.map(\.url) ?? [request.renamed],
            state: state, sourceID: request.detectedSourceID ?? engine.catalog.format(for: request.original)?.id,
            recordID: request.id)
        entry.configurations = request.configurations
        entry.message = message
        jobChanged(entry)
    }

    @discardableResult
    public func decide(_ id: UUID, convert: Bool, settings: ConversionSettings? = nil,
                       keepOriginal: Bool? = nil, stageOverrides: [ConversionStageOverride]? = nil) -> Bool {
        if let entry = waiting.first(where: { $0.value.selections?.contains { $0.id == id && $0.pending } == true }),
           var choices = entry.value.selections, let index = choices.firstIndex(where: { $0.id == id }) {
            var request = entry.value
            let rule = rule(for: request, target: choices[index].url, in: rules)
            choices[index].pending = false
            choices[index].settings = convert ? settings ?? rule?.settings ?? self.settings : nil
            choices[index].keepOriginal = keepOriginal ?? rule?.keepOriginal ?? self.keepOriginal
            choices[index].stageOverrides = stageOverrides ?? rule?.stageOverrides ?? []
            request.selections = choices
            if choices.contains(where: \.pending) { waiting[entry.key] = request }
            else {
                waiting.removeValue(forKey: entry.key)
                if events != nil, choices.contains(where: { $0.settings != nil }) {
                    ready.append(request)
                    report(request, state: .queued)
                } else { report(request, state: .cancelled, message: "All outputs were skipped.") }
                pump()
            }
            reportApprovals()
            return true
        }
        guard let entry = waiting.first(where: { $0.value.id == id }) else { return false }
        waiting.removeValue(forKey: entry.key)
        reportApprovals()
        guard convert, events != nil else {
            report(entry.value, state: .cancelled, message: "Skipped before conversion.")
            return true
        }
        var request = entry.value
        request.confirmedSettings = settings ?? rule(for: request, in: rules)?.settings ?? self.settings
        request.confirmedStageOverrides = stageOverrides ?? rule(for: request, in: rules)?.stageOverrides ?? []
        request.confirmedKeepOriginal = keepOriginal ?? rule(for: request, in: rules)?.keepOriginal ?? self.keepOriginal
        ready.append(request)
        report(request, state: .queued)
        pump()
        return true
    }

    private func rule(for request: Request, target: URL? = nil, in rules: [ConversionRule]) -> ConversionRule? {
        guard let source = request.detectedSourceID.flatMap({ id in engine.catalog.formats.first { $0.id == id } })
                ?? engine.catalog.format(for: request.original),
              let target = engine.catalog.format(for: target ?? request.renamed) else { return nil }
        return rules.first { $0.sourceID == source.id && $0.targetID == target.id }
    }

    private func reportApprovals() {
        approvalsChanged?(waiting.values.flatMap { request -> [ConversionApproval] in
            if let choices = request.selections {
                return choices.filter(\.pending).map {
                    ConversionApproval(id: $0.id, originalURL: request.original, renamedURL: $0.url,
                        detectedSourceID: request.detectedSourceID, inputURL: request.renamed)
                }
            }
            return [ConversionApproval(id: request.id, originalURL: request.original, renamedURL: request.renamed,
                               detectedSourceID: request.detectedSourceID)]
        }.sorted { $0.renamedURL.path < $1.renamedURL.path })
    }

    func accept(_ batch: [FileEvent]) {
        guard events != nil else { return }
        if batch.contains(where: \.requiresRescan) {
            recoveries += 1
            if recoveries <= 3, rearm() {
                receive(.failure(ConversionError.message(
                    "Some file events were lost. Monitoring restarted. Renames during that gap were not seen.")))
            } else {
                stop()
                receive(.failure(ConversionError.message("A watched folder changed or file events were lost. Monitoring needs to be restarted.")))
            }
            return
        }
        recoveries = 0
        for event in batch {
            guard let inode = event.inode, let device = deviceForParent(of: event.url) else { continue }
            let key = Key(device: device, inode: inode)
            guard event.isFileRename || event.isDirectoryRename || (convertNewFiles && event.isCreation)
                    || pending[key] != nil else { continue }
            var group = pending[key] ?? Pending()
            group.events[event.url] = event
            group.lastEvent = Date()
            group.canBeArrival = group.canBeArrival || convertNewFiles
            pending[key] = group
        }
        schedule()
    }

    private func schedule() {
        guard timer == nil, !pending.isEmpty else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self else { return }
            timer = nil
            drain()
        }
    }

    private func drain() {
        for (key, var group) in pending {
            let old = group.events.values.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
                .min { $0.id < $1.id }?.url
            let existing = group.events.keys.compactMap { url -> (URL, SourceVersion)? in
                guard let version = try? SourceVersion(url), version.inode == key.inode,
                      version.device == key.device else { return nil }
                return (url, version)
            }
            guard existing.count == 1, let (new, version) = existing.first else {
                if Date().timeIntervalSince(group.lastEvent) > 3 { pending.removeValue(forKey: key) }
                continue
            }
            let previous = running[key]?.request ?? detecting[key]?.request
                ?? ready[queueIndex...].first(where: { $0.key == key }) ?? waiting[key]
            let isNewFile = previous?.isNewFile ?? (old == nil)
            guard old != nil || previous != nil || (convertNewFiles && group.canBeArrival) else {
                if Date().timeIntervalSince(group.lastEvent) > 3 { pending.removeValue(forKey: key) }
                continue
            }
            let origin = previous?.original ?? old ?? new
            let detectedID = previous?.version == version ? previous?.detectedSourceID : nil
            let sourceID = detectedID ?? (isNewFile ? nil : engine.catalog.format(for: origin)?.id)
            let multiple = convertMultipleFormats ? MultipleOutputName(new, catalog: engine.catalog,
                originalExtension: isNewFile ? nil : origin.pathExtension) : nil
            let target = engine.catalog.format(for: new)
            guard multiple != nil || (target != nil && (isNewFile || sourceID != nil)) else {
                pending.removeValue(forKey: key)
                continue
            }
            if multiple == nil, sourceID == target?.id {
                running[key]?.task.cancel()
                detecting[key]?.task.cancel()
                removeQueued(key)
                if let request = waiting.removeValue(forKey: key) { report(request, state: .cancelled, message: "The file was renamed again.") }
                pending.removeValue(forKey: key)
                continue
            }
            guard group.version == version else {
                group.version = version
                pending[key] = group
                continue
            }
            running[key]?.task.cancel()
            detecting[key]?.task.cancel()
            removeQueued(key)
            if let request = waiting.removeValue(forKey: key) { report(request, state: .cancelled, message: "The file was renamed again.") }
            let request = Request(key: key, original: origin, renamed: new, version: version,
                                 isNewFile: isNewFile, detectedSourceID: detectedID, multiple: multiple)
            ready.append(request)
            report(request, state: .queued)
            pending.removeValue(forKey: key)
        }
        pump()
        schedule()
    }

    static let lowSpaceMessage = "The volume is low on free space. Converting needs room beside the original."

    // Converting writes the result beside the original and keeps working files there until the
    // swap, so the volume needs room for about the source size again. A volume that cannot hold
    // that fails deep inside the work, so ask first instead and leave the choice to the person.
    static func isLowOnSpace(available: Int64, source: SourceVersion) -> Bool {
        let size = source.members.values.reduce(source.root.size) { $0 + max(0, $1.size) }
        let margin: Int64 = 128 * 1024 * 1024
        guard size <= (Int64.max - margin) / 2 else { return true }
        return available < size * 2 + margin
    }

    static func availableSpace(beside file: URL) -> Int64? {
        try? file.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private func pump() {
        var remaining = ready.count - queueIndex
        while events != nil, !maintenanceInProgress,
              running.count + detecting.count < cpuProfile.limits().jobs, remaining > 0 {
            var request = ready[queueIndex]
            queueIndex += 1
            remaining -= 1
            if running[request.key] != nil || detecting[request.key] != nil {
                ready.append(request)
                continue
            }
            guard let version = try? SourceVersion(request.renamed), version == request.version else {
                report(request, state: .failed, message: "The file changed while waiting. Its contents were kept.")
                receive(.failure(ConversionError.message("\(request.renamed.lastPathComponent) changed while waiting. Its contents were kept.")))
                continue
            }
            if request.isNewFile && !convertNewFiles { continue }
            if request.multiple != nil && !convertMultipleFormats { continue }
            if let multiple = request.multiple, multiple.targets.isEmpty {
                report(request, state: .failed, message: "No known output extension was selected.")
                receive(.failure(ConversionError.message("No known output extension was selected. Its contents were kept.")))
                continue
            }
            if request.isNewFile || request.multiple != nil {
                if request.detectedSourceID == nil {
                    if action != .doNotConvert || rules.contains(where: { $0.action != .doNotConvert }) {
                        detect(request)
                    } else { report(request, state: .cancelled, message: "The action is Do not convert.") }
                    continue
                }
            }
            let rule = rule(for: request, in: rules)
            let lowSpace = Self.availableSpace(beside: request.renamed)
                .map { Self.isLowOnSpace(available: $0, source: version) } ?? false
            if let multiple = request.multiple {
                if request.selections == nil {
                    request.selections = multiple.targets.compactMap { target in
                        let rule = self.rule(for: request, target: target.url, in: rules)
                        let action = rule?.action ?? self.action
                        guard action != .doNotConvert else { return nil }
                        return Selection(url: target.url, pending: lowSpace || action == .askFirst,
                            settings: action == .immediately && !lowSpace ? rule?.settings ?? settings : nil,
                            keepOriginal: rule?.keepOriginal ?? self.keepOriginal, stageOverrides: rule?.stageOverrides ?? [])
                    }
                }
                if request.selections?.contains(where: \.pending) == true {
                    waiting[request.key] = request
                    report(request, state: .waiting, message: lowSpace ? Self.lowSpaceMessage : nil)
                    continue
                }
                guard request.selections?.contains(where: { $0.settings != nil }) == true else {
                    report(request, state: .cancelled, message: "All outputs were skipped.")
                    continue
                }
            } else if request.confirmedSettings == nil {
                switch rule?.action ?? action {
                case .immediately:
                    if lowSpace {
                        waiting[request.key] = request
                        report(request, state: .waiting, message: Self.lowSpaceMessage)
                        continue
                    }
                case .doNotConvert:
                    report(request, state: .cancelled, message: "The format rule is Do not convert.")
                    continue
                case .askFirst:
                    waiting[request.key] = request
                    report(request, state: .waiting)
                    continue
                }
            }
            let engine = engine
            let history = historyDirectory
            var selected = request.confirmedSettings ?? rule?.settings ?? settings
            selected.mediaOptions.cpuProfile = cpuProfile
            let options = selected
            let stageOverrides = request.confirmedStageOverrides ?? rule?.stageOverrides ?? []
            let keepOriginal = request.confirmedKeepOriginal ?? rule?.keepOriginal ?? keepOriginal
            let destinations = (request.selections ?? []).compactMap { selection -> ConversionDestination? in
                guard var options = selection.settings else { return nil }
                options.mediaOptions.cpuProfile = cpuProfile
                return ConversionDestination(url: selection.url, settings: options, stageOverrides: selection.stageOverrides)
            }
            let groupKeepsOriginal = request.selections?.contains { $0.settings != nil && $0.keepOriginal } == true
            if request.multiple != nil {
                request.configurations = destinations.map { .init(outputURL: $0.url, settings: $0.settings, keepOriginal: groupKeepsOriginal) }
            } else { request.configurations = [.init(outputURL: request.renamed, settings: options, keepOriginal: keepOriginal)] }
            let confirmed = request
            let (progress, continuation) = AsyncStream<(URL, ConversionActivity.Step)>.makeStream()
            let task = Task.detached(priority: cpuProfile == .low ? .utility : .userInitiated) {
                defer { continuation.finish() }
                if let multiple = confirmed.multiple, let sourceID = confirmed.detectedSourceID {
                    return try engine.convertToMultipleFormats(from: confirmed.original, at: confirmed.renamed,
                        destinations: destinations, sourceID: sourceID, historyDirectory: history, keepOriginal: groupKeepsOriginal,
                        issues: multiple.unknownExtensions.map { "Unknown output extension: \($0)." },
                        expectedIdentity: (confirmed.key.device, confirmed.key.inode), id: confirmed.id,
                        progress: { continuation.yield(($0, $1)) })
                }
                return try engine.convertRenamedFile(from: confirmed.original, to: confirmed.renamed,
                    historyDirectory: history, settings: options, keepOriginal: keepOriginal,
                    detectedSourceID: confirmed.detectedSourceID,
                    expectedIdentity: (confirmed.key.device, confirmed.key.inode), id: confirmed.id,
                    stageOverrides: stageOverrides,
                    progress: { continuation.yield(($0, $1)) })
            }
            running[request.key] = Running(request: request, task: task)
            completions[request.id] = Task { [weak self] in
                guard let self else { return }
                var tracked = confirmed
                for await (output, step) in progress {
                    if let index = tracked.configurations.firstIndex(where: { $0.outputURL == output }) {
                        tracked.configurations[index].record(step)
                        report(tracked, state: .running, outputs: tracked.configurations.map(\.outputURL))
                    }
                }
                let result = await task.result
                defer { completions.removeValue(forKey: request.id); pump() }
                running.removeValue(forKey: request.key)
                // A commit can finish just before cancellation. Keep its Undo record visible.
                if case .success(let record) = result {
                    report(tracked, state: .completed, message: record.multipleOutputs?.issues.joined(separator: "\n"), outputs: record.outputURLs)
                    receive(result)
                }
                else if !task.isCancelled {
                    if case .failure(let error) = result { report(tracked, state: .failed, message: error.localizedDescription) }
                    receive(result.mapError { ConversionError.message("\(request.renamed.lastPathComponent): \($0.localizedDescription)") })
                } else { report(tracked, state: .cancelled, message: "Conversion was cancelled.") }
            }
            report(confirmed, state: .running, outputs: request.configurations.map(\.outputURL))
        }
        if queueIndex == ready.count || queueIndex > 1024 {
            ready.removeFirst(queueIndex)
            queueIndex = 0
        }
        reportApprovals()
        reportActivity()
    }

    private func reportActivity() {
        activity?(running.count + detecting.count, ready.count - queueIndex, events != nil)
    }

    private func detect(_ request: Request) {
        let engine = engine
        let generation = generation
        let hint = request.multiple != nil && !request.isNewFile ? engine.catalog.format(for: request.original)?.extensions.first : nil
        let task = Task.detached(priority: .utility) { try engine.detectedFormat(at: request.renamed, sourceExtensionHint: hint) }
        detecting[request.key] = Detecting(request: request, task: task)
        completions[request.id] = Task { [weak self] in
            let result = await task.result
            guard let self else { return }
            detecting.removeValue(forKey: request.key)
            // The conversion callback will use the same job ID after detection finishes.
            defer { completions.removeValue(forKey: request.id); pump() }
            guard self.generation == generation, !task.isCancelled,
                  !request.isNewFile || convertNewFiles,
                  request.multiple == nil || convertMultipleFormats else {
                report(request, state: .cancelled, message: "Source detection was cancelled.")
                return
            }
            switch result {
            case .success(let source):
                guard let source else {
                    report(request, state: .failed, message: "The source format could not be identified.")
                    if request.multiple != nil { receive(.failure(ConversionError.message("The source format could not be identified. Its contents were kept."))) }
                    return
                }
                if request.multiple == nil {
                    guard let target = engine.catalog.format(for: request.renamed), source.id != target.id else {
                        report(request, state: .cancelled, message: "The contents already match the filename.")
                        return
                    }
                }
                var identified = request
                identified.detectedSourceID = source.id
                ready.append(identified)
                report(identified, state: .queued)
            case .failure(let error):
                report(request, state: .failed, message: error.localizedDescription)
                receive(.failure(ConversionError.message("\(request.renamed.lastPathComponent): \(error.localizedDescription)")))
            }
        }
        report(request, state: .running, message: "Identifying the source format.")
    }

    private func removeQueued(_ key: Key) {
        for index in (queueIndex..<ready.count).reversed() where ready[index].key == key {
            report(ready[index], state: .cancelled, message: "The file was renamed again.")
            ready.remove(at: index)
        }
    }
}

private func deviceForParent(of file: URL) -> Int32? {
    var directory = file.deletingLastPathComponent()
    while true {
        var value = stat()
        if lstat(directory.path, &value) == 0 { return value.st_dev }
        guard directory.path != "/" else { return nil }
        directory.deleteLastPathComponent()
    }
}
