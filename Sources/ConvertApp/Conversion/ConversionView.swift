import SwiftUI

struct ConversionView: View {
    @Bindable var model: ConversionModel
    @State private var editingStages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Convert a file").font(.largeTitle.bold())
            HStack {
                Label(model.source?.lastPathComponent ?? "No file selected", systemImage: "doc")
                    .lineLimit(2)
                    .help(model.source?.path ?? "Drop a file into this window.")
                Spacer()
                Button("Choose File…") { model.chooseFile() }
                    .disabled(model.busy || model.cleaningBackups || model.engine == nil)
            }
            Form {
                Picker("Convert to", selection: $model.targetID) {
                    if model.targets.isEmpty { Text("Choose a file first").tag("") }
                    ForEach(model.targets, id: \.id) { format in
                        Text("\(format.name) (.\(format.extensions[0]))").tag(format.id)
                    }
                }.accessibilityLabel("Convert to")
                if let format = model.target {
                    ConversionOptionsView(settings: $model.settings, targetID: model.targetID,
                        source: model.source, sourceID: model.source.flatMap { model.engine?.catalog.format(for: $0)?.id },
                        embeddedSubtitleTracks: model.embeddedSubtitleTracks, category: format.category,
                        sourceCategory: model.source.flatMap { model.engine?.catalog.format(for: $0)?.category })
                    Button("Stage Settings…") { editingStages = true }
                }
            }
            .formStyle(.grouped)
            .disabled(model.busy || model.cleaningBackups)
            Spacer(minLength: 0)
            HStack {
                if model.busy || model.cleaningBackups { ProgressView().controlSize(.small) }
                Text(model.cleaningBackups ? "Cleaning up backups…" : model.status)
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
            }
            HStack {
                Text("Preview build").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let saved = model.savedFile {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                }
                if model.canCancel {
                    Button("Cancel") { model.cancel() }
                } else {
                    Button("Save Converted Copy…") { model.save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || model.cleaningBackups || model.target == nil)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 580, minHeight: 540)
        .sheet(isPresented: $editingStages) {
            if let engine = model.engine, let target = model.target {
                ConversionStageSettingsView(engine: engine, source: model.source.flatMap { engine.catalog.format(for: $0) },
                    target: target, sourceURL: model.source, baseSettings: model.settings, overrides: $model.manualStageOverrides)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let file = urls.first, file.isFileURL,
                  !model.busy, !model.cleaningBackups, model.engine != nil else { return false }
            model.select(file)
            return true
        }
    }
}
