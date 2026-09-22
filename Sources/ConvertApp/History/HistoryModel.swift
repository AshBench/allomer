import ConversionCore
import Foundation

enum HistoryFilter: String, CaseIterable {
    case all = "All", active = "Active", completed = "Completed", failed = "Failed", cancelled = "Cancelled"

    func matches(_ entry: ConversionActivity, query: String) -> Bool {
        let stateMatches: Bool
        switch self {
        case .all: stateMatches = true
        case .active: stateMatches = !entry.state.isFinished
        case .completed: stateMatches = entry.state == .completed
        case .failed: stateMatches = entry.state == .failed
        case .cancelled: stateMatches = entry.state == .cancelled
        }
        guard stateMatches else { return false }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return ([entry.originalURL.path, entry.requestedURL.path, entry.message ?? ""] + entry.outputURLs.map(\.path))
            .contains { $0.localizedStandardContains(query) }
    }
}

extension ConversionModel {
    var jobHistoryDirectory: URL { historyDirectory.appendingPathComponent("Activity", isDirectory: true) }

    var visibleHistory: [ConversionActivity] {
        let legacy = history.filter { historyJobs[$0.id] == nil }.map { record in
            var entry = ConversionActivity(id: record.id, date: record.date, originalURL: record.originalURL,
                requestedURL: record.multipleOutputs?.requestURL ?? record.convertedURL, outputURLs: record.outputURLs,
                state: record.state == .completed || record.state == .undone ? .completed : .failed, recordID: record.id)
            entry.message = record.multipleOutputs?.issues.joined(separator: "\n")
            return entry
        }
        return (Array(historyJobs.values) + legacy).filter { !hiddenHistoryIDs.contains($0.id) }.sorted { $0.date > $1.date }
    }

    func canClearHistory(_ entry: ConversionActivity) -> Bool {
        guard entry.state.isFinished else { return false }
        guard let id = entry.recordID, let record = historyByID[id] else { return true }
        return ![.prepared, .undoPrepared, .needsReview].contains(record.state) && record.backupState != .removing
    }

    func loadJobHistory() async throws {
        let directory = jobHistoryDirectory
        let contents = try await Task.detached(priority: .utility) { try HistoryStore.load(from: directory) }.value
        hiddenHistoryIDs = contents.hiddenIDs
        historyJobs = Dictionary(uniqueKeysWithValues: contents.entries.map { ($0.id, $0) })
        for var entry in contents.entries where !entry.state.isFinished {
            if let id = entry.recordID, let record = historyByID[id], record.state == .completed || record.state == .undone {
                entry.state = .completed
                entry.outputURLs = record.outputURLs
            } else {
                entry.state = .failed
                entry.message = "The app stopped before this job finished. Review any recovery files."
            }
            for index in entry.configurations.indices {
                if var steps = entry.configurations[index].steps {
                    for step in steps.indices where steps[step].state == .running {
                        let saved = entry.state == .completed && entry.outputURLs.contains(entry.configurations[index].outputURL)
                        steps[step].state = saved ? .completed : .failed
                        if !saved { steps[step].message = "The app stopped before this step's result was recorded." }
                    }
                    entry.configurations[index].steps = steps
                }
            }
            recordJob(entry)
        }
    }

    func recordJob(_ entry: ConversionActivity) {
        historyJobs[entry.id] = entry
        let previous = historyWriter
        let directory = jobHistoryDirectory
        let journal = entry.recordID.map { historyDirectory.appendingPathComponent("\($0).json") }
        historyWriter = Task { @MainActor [weak self] in
            await previous?.value
            do {
                let recovered = try await Task.detached(priority: .utility) { () throws -> ConversionRecord? in
                    try HistoryStore.save(entry, in: directory)
                    if entry.state == .failed || entry.state == .cancelled, let journal,
                       FileManager.default.fileExists(atPath: journal.path) {
                        return try ConversionRecord.loadRecord(from: journal)
                    }
                    return nil
                }.value
                if let self, let recovered {
                    if let index = history.firstIndex(where: { $0.id == recovered.id }) { history[index] = recovered }
                    else { history.insert(recovered, at: 0) }
                    scheduleBackupCleanup()
                }
            } catch { self?.historyIssue = "History could not be saved: \(error.localizedDescription)" }
        }
    }

    func clearFinishedHistory() async {
        guard !clearingHistory else { return }
        clearingHistory = true
        let selected = Set(visibleHistory.filter(canClearHistory).map(\.id))
        let previous = historyWriter
        let directory = jobHistoryDirectory
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            // A failed job's journal may have been recovered by the preceding write.
            let ids = Set(visibleHistory.filter { selected.contains($0.id) && canClearHistory($0) }.map(\.id))
            let hidden = hiddenHistoryIDs
            do {
                hiddenHistoryIDs = try await Task.detached(priority: .utility) {
                    try HistoryStore.clear(ids, previouslyHidden: hidden, in: directory)
                }.value
                for id in ids { historyJobs.removeValue(forKey: id) }
            } catch {
                historyIssue = "History could not be fully cleared: \(error.localizedDescription)"
                // The hidden-ID file can already be committed when file removal fails.
                if let saved = try? await Task.detached(priority: .utility, operation: { try HistoryStore.load(from: directory) }).value {
                    hiddenHistoryIDs = saved.hiddenIDs
                }
            }
        }
        historyWriter = task
        await task.value
        clearingHistory = false
    }
}
