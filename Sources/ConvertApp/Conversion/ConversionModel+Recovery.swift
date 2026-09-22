import ConversionCore
import Foundation

extension ConversionModel {
    func undo(_ record: ConversionRecord) {
        guard !busy, !cleaningBackups, record.canUndo else { return }
        busy = true
        workerCanCancel = false
        let task = Task.detached(priority: .utility) { try ConversionEngine.undo(record) }
        let worker = Task { @MainActor in
            let restored = try await task.value
            if let index = history.firstIndex(where: { $0.id == restored.id }) { history[index] = restored }
            automaticStatus = "Restored \(restored.originalURL.lastPathComponent)."
            scheduleBackupCleanup()
        }
        self.worker = worker
        Task {
            do { try await worker.value } catch {
                self.error = error.localizedDescription
                appSettings.failed(error.localizedDescription, undo: true)
            }
            self.worker = nil
            busy = false
        }
    }

}
