import ConversionCore
import SwiftUI

struct BackupSettingsView: View {
    let model: ConversionModel
    @State private var options: BackupRetentionOptions
    @State private var confirmingClear = false

    init(model: ConversionModel) {
        self.model = model
        self._options = State(initialValue: model.retention)
    }

    var body: some View {
        Section("Backups") {
            Toggle("Delete backups older than a set age", isOn: $options.limitAge)
                .accessibilityLabel("Delete backups older than a set age")
            TextField("Maximum age in days", value: $options.maximumAgeDays, format: .number)
                .disabled(!options.limitAge)
                .accessibilityLabel("Maximum age in days")
            Toggle("Limit total backup size", isOn: $options.limitSize)
                .accessibilityLabel("Limit total backup size")
            TextField("Maximum size in GiB", value: $options.maximumSizeGiB, format: .number)
                .disabled(!options.limitSize)
                .accessibilityLabel("Maximum size in GiB")
            Text("1 GiB is 1,073,741,824 bytes. Size counts recovery file contents, including clones. It does not measure shared disk blocks.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Apply Limits") { model.applyRetention(options) }
                .disabled(options == model.retention || model.cleaningBackups)
            Text("Expired backups cannot be used for Undo. Converted files and visible originals stay in place. Unfinished or edited backups need review.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.cleaningBackups { ProgressView().controlSize(.small) }
                Text(model.retentionStatus).font(.caption).foregroundStyle(.secondary)
            }
            Button("Clear All Backups…", role: .destructive) { confirmingClear = true }
                .disabled(model.cleaningBackups || model.history.allSatisfy { $0.backupState == .removed })
                .confirmationDialog("Clear All Backups?", isPresented: $confirmingClear) {
                    Button("Clear All Backups", role: .destructive) { model.requestClearBackups() }
                } message: {
                    Text("This permanently removes recovery files, including edited backups. Undo will no longer be available. Converted files, visible originals, and history entries stay in place. Cleanup waits for running conversions to finish.")
                }
        }
    }
}
