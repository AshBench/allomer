import ConversionCore
import Foundation

extension ConversionModel {
    func requestClearBackups() {
        clearBackupsRequested = true
        retentionStatus = "Backup cleanup is scheduled."
        scheduleBackupCleanup()
    }

    func applyRetention(_ options: BackupRetentionOptions) {
        do {
            try options.validate()
            retention = options
        } catch { retentionStatus = "Limits were not changed. \(error.localizedDescription)" }
    }

    func scheduleBackupCleanup(after delay: TimeInterval = 1) {
        guard !isQuitting, engine != nil else { return }
        guard retention.limitAge || retention.limitSize || clearBackupsRequested
                || history.contains(where: { $0.backupState == .removing }) else {
            cleanupTimer?.invalidate()
            cleanupTimer = nil
            if !cleaningBackups { cleanupWaiting = false; automatic?.maintenanceInProgress = false }
            return
        }
        guard !cleaningBackups, !cleanupWaiting else { return }
        let date = Date().addingTimeInterval(delay)
        if let timer = cleanupTimer, timer.fireDate <= date { return }
        cleanupTimer?.invalidate()
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isQuitting else { return }
                self.cleanupTimer = nil
                self.cleanupWaiting = true
                self.automatic?.maintenanceInProgress = true
                if self.busy || self.activeJobs > 0 {
                    self.retentionStatus = "Waiting for current work before backup cleanup."
                }
                self.startWaitingCleanup()
            }
        }
        cleanupTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func startWaitingCleanup() {
        guard cleanupWaiting, !isQuitting, !busy, activeJobs == 0, !cleaningBackups else { return }
        Task { await cleanupBackups() }
    }

    func cleanupBackups() async {
        guard !isQuitting, engine != nil, !busy, activeJobs == 0, !cleaningBackups else { return }
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        cleanupWaiting = false
        cleaningBackups = true
        automatic?.maintenanceInProgress = true
        let records = history
        let options = retention
        let clearAll = clearBackupsRequested
        clearBackupsRequested = false
        retentionStatus = "Removing expired backups…"
        let task = Task.detached(priority: .utility) {
            try BackupRetention.clean(records, options: options, removeAll: clearAll)
        }
        cleanupWorker = task
        do {
            let result = try await task.value
            let updates = Dictionary(uniqueKeysWithValues: result.records.map { ($0.id, $0) })
            history = history.map { updates[$0.id] ?? $0 }
            let size = ByteCountFormatter.string(fromByteCount: result.retainedBytes, countStyle: .binary)
            retentionStatus = "Removed \(result.removedCount) backups. Known recovery data: \(size)."
            if !result.issues.isEmpty {
                retentionStatus += " \(result.issues.count) backups need review or are unavailable."
                if clearAll { error = result.issues.prefix(3).joined(separator: "\n") }
            }
        } catch is CancellationError {
            retentionStatus = "Backup cleanup stopped. Completed removals stay in effect."
        } catch {
            retentionStatus = error.localizedDescription
        }
        cleanupWorker = nil
        cleaningBackups = false
        automatic?.maintenanceInProgress = false
        scheduleBackupCleanup(after: clearBackupsRequested ? 1 : 3_600)
    }
}
