import ConversionCore
import SwiftUI

struct HistoryView: View {
    let model: ConversionModel
    @State private var query = ""
    @State private var filter = HistoryFilter.all
    @State private var confirmClear = false
    @State private var settingsEntry: ConversionActivity?

    var body: some View {
        let all = model.visibleHistory
        let entries = all.filter { filter.matches($0, query: query) }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conversion history").font(.title.bold())
                Spacer()
                Button("Clear Finished…") { confirmClear = true }
                    .disabled(model.clearingHistory || !all.contains { model.canClearHistory($0) })
            }
            HStack {
                TextField("Search names, paths, or messages", text: $query)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Search conversion history")
                Picker("Status", selection: $filter) {
                    ForEach(HistoryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 180).accessibilityLabel("Status")
            }
            if let issue = model.historyIssue {
                Text(issue).foregroundStyle(.red).textSelection(.enabled)
            }
            if entries.isEmpty {
                ContentUnavailableView(all.isEmpty ? "No conversions yet" : "No matching conversions",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(all.isEmpty ? "Convert a file or rename one in a watched folder to start."
                        : "Try another search or status filter."))
            } else {
                List(entries) { entry in
                    let record = entry.recordID.flatMap { model.historyByID[$0] }
                    HStack(alignment: .top) {
                        if entry.state == .running { ProgressView().controlSize(.small).padding(.top, 4) }
                        VStack(alignment: .leading, spacing: 5) {
                            let outputs = record?.outputURLs ?? entry.outputURLs
                            let names = (outputs.isEmpty ? [entry.requestedURL] : outputs).map(\.lastPathComponent)
                            Text("\(entry.originalURL.lastPathComponent) → \(names.joined(separator: ", "))")
                                .fontWeight(.medium).lineLimit(2).help(names.joined(separator: "\n"))
                            Text("\(entry.date.formatted()) · \(label(entry, record: record))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(entry.requestedURL.deletingLastPathComponent().path)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                            if entry.state == .running {
                                ForEach(entry.configurations.indices, id: \.self) { index in
                                    let configuration = entry.configurations[index]
                                    if let step = configuration.steps?.last {
                                        Text("\(configuration.outputURL.lastPathComponent) · Step \(step.id + 1) of \(step.count): \(step.sourceID ?? "file") → \(step.targetID) · \(step.state.title)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if let message = entry.message, !message.isEmpty {
                                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if let backup = record?.backupState {
                                Text(backup == .removed ? "Backup removed · Undo unavailable" : "Backup removal needs to finish")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !entry.configurations.isEmpty {
                                Button("Steps and Settings…") { settingsEntry = entry }
                                    .accessibilityLabel("Recorded settings for \(entry.originalURL.lastPathComponent)")
                            }
                        }
                        Spacer()
                        if !entry.state.isFinished {
                            Button("Cancel") { model.cancelJob(entry.id) }
                                .accessibilityLabel("Cancel conversion of \(entry.originalURL.lastPathComponent)")
                        }
                        if let record {
                            if record.canUndo {
                                Button(record.multipleOutputs == nil ? "Undo" : "Undo All") { model.undo(record) }
                                    .disabled(model.busy || model.cleaningBackups)
                                    .accessibilityLabel(record.multipleOutputs == nil
                                        ? "Undo conversion of \(record.originalURL.lastPathComponent)"
                                        : "Undo all outputs of \(record.originalURL.lastPathComponent)")
                            }
                            if record.backupState != .removed {
                                Button("Files") {
                                    let directory = FileManager.default.fileExists(atPath: record.removalDirectory.path)
                                        ? record.removalDirectory : record.recoveryDirectory
                                    NSWorkspace.shared.activateFileViewerSelecting([
                                        record.backupState == .removing ? directory : record.snapshotURL
                                    ])
                                }.help("Show the retained original and recovery files")
                                    .accessibilityLabel("Show recovery files for \(record.originalURL.lastPathComponent)")
                            }
                        }
                    }.padding(.vertical, 6).accessibilityElement(children: .contain)
                }
            }
        }.padding(24)
            .confirmationDialog("Clear all finished history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Finished History", role: .destructive) { Task { await model.clearFinishedHistory() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears completed, failed, and cancelled entries across all filters. Active jobs and recovery that needs review stay visible. Files and backups stay in place. Cleared entries no longer offer Undo here.")
            }
            .sheet(item: $settingsEntry) { HistorySettingsView(model: model, entry: $0) }
    }

    private func label(_ entry: ConversionActivity, record: ConversionRecord?) -> String {
        guard entry.state.isFinished, let record else { return entry.state.title }
        switch record.state {
        case .completed: return "Completed"
        case .undone: return "Undone"
        case .aborted: return entry.state == .cancelled ? "Cancelled" : "Stopped before replacement"
        case .prepared, .undoPrepared, .needsReview: return "Recovery needs review"
        }
    }
}

private struct HistorySettingsView: View {
    let model: ConversionModel
    let entry: ConversionActivity
    @State private var selected = 0
    @State private var selectedStep = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let current = model.historyJobs[entry.id] ?? entry
        VStack(alignment: .leading, spacing: 12) {
            Text("Recorded conversion settings").font(.title.bold())
            if current.configurations.indices.contains(selected) {
                if current.configurations.count > 1 {
                    Picker("Output", selection: $selected) {
                        ForEach(current.configurations.indices, id: \.self) { index in
                            Text(current.configurations[index].outputURL.lastPathComponent).tag(index)
                        }
                    }.onChange(of: selected) { selectedStep = 0 }.accessibilityLabel("Output")
                }
                let configuration = current.configurations[selected]
                let steps = configuration.steps ?? []
                if !steps.isEmpty {
                    Picker("Conversion step", selection: $selectedStep) {
                        ForEach(steps.indices, id: \.self) { index in
                            let step = steps[index]
                            Text("\(step.id + 1) of \(step.count): \(step.sourceID ?? "file") → \(step.targetID) · \(step.state.title)").tag(index)
                        }
                    }.accessibilityLabel("Conversion step")
                }
                let step = steps.indices.contains(selectedStep) ? steps[selectedStep] : nil
                let source = (step?.sourceID ?? current.sourceID).flatMap { id in model.engine?.catalog.formats.first { $0.id == id } }
                    ?? model.engine?.catalog.format(for: current.originalURL)
                let target = step.flatMap { value in model.engine?.catalog.formats.first { $0.id == value.targetID } }
                    ?? model.engine?.catalog.format(for: configuration.outputURL)
                Text(configuration.outputURL.lastPathComponent).textSelection(.enabled)
                LabeledContent("Original file", value: configuration.keepOriginal ? "Kept" : "Retained for Undo")
                if let message = step?.message { Text(message).font(.caption).textSelection(.enabled) }
                if let target {
                    if source?.id == target.id && step?.settings == nil {
                        Text("This output keeps the original contents without re-encoding them.")
                    } else {
                        Form {
                            ConversionOptionsView(settings: .constant(step?.settings ?? configuration.settings), targetID: target.id,
                                source: source.map { URL(fileURLWithPath: "/file." + $0.extensions[0]) }, sourceID: source?.id,
                                category: target.category, sourceCategory: source?.category)
                        }.formStyle(.grouped).disabled(true)
                    }
                }
            } else { Text("No settings were recorded for this conversion.") }
            Text("Each recorded step shows the settings passed to that conversion stage. Older jobs show the original output settings. Current defaults can be different. Completed steps can still be followed by a save or recovery error.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 600, height: 580)
    }
}
