import ConversionCore
import SwiftUI

struct AutomaticView: View {
    @Bindable var model: ConversionModel
    @State private var editingRule: ConversionRule?
    @State private var addingRule = false
    @State private var selectedApproval: ConversionApproval?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename a file. Convert its contents.").font(.title.bold())
            Text("Add a folder, then change a file extension in Finder. For example, rename photo.png to photo.jpg.")
                .foregroundStyle(.secondary)
            Toggle("Automatic conversion", isOn: Binding(get: { model.monitoring }, set: { model.setMonitoring($0) }))
                .toggleStyle(.switch).disabled(model.engine == nil || !model.canMonitor || model.checkingDiskAccess)
                .accessibilityLabel("Automatic conversion")
            Picker("After an extension change", selection: $model.automaticAction) {
                ForEach(AutomaticConversionAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(model.engine == nil)
                .accessibilityLabel("After an extension change")
            Toggle("Keep the original file after conversion", isOn: $model.keepOriginal)
                .disabled(model.engine == nil)
            Toggle("Convert new files with the wrong extension", isOn: $model.convertNewFiles)
                .disabled(model.engine == nil)
                .help("Check future arrivals in watched folders. Convert their contents to match the filename, using the same actions and rules.")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Toggle("Convert to multiple formats at once", isOn: $model.convertMultipleFormats)
                        .disabled(model.engine == nil)
                    Text("Use comma-separated extensions, such as photo.jpg,webp. Each output uses its format rule. The group waits for all pending decisions.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Watch whole system", isOn: Binding(
                        get: { model.watchWholeSystem },
                        set: { enabled in Task { await model.setWatchWholeSystem(enabled) } }
                    )).disabled(model.engine == nil || model.checkingDiskAccess)
                    Text(model.checkingDiskAccess ? "Checking access…" : model.diskAccess.description)
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Full Disk Access Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    Toggle("Ignore system and cache files", isOn: $model.ignoreSystemFiles)
                        .disabled(model.engine == nil)
                    Divider()
                    if !model.approvals.isEmpty {
                        Text("Waiting for your decision").font(.headline)
                        ForEach(model.approvals) { approval in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(approval.originalURL.lastPathComponent) → \(approval.renamedURL.lastPathComponent)")
                                    .fontWeight(.medium).lineLimit(2)
                                if let id = approval.detectedSourceID {
                                    Text("Detected contents: \(formatName(id))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(approval.renamedURL.deletingLastPathComponent().path)
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                HStack {
                                    Button("Convert") { model.decide(approval, convert: true) }
                                        .accessibilityLabel("Convert \(approval.renamedURL.lastPathComponent)")
                                    Button("Settings…") { selectedApproval = approval }
                                        .accessibilityLabel("Conversion settings for \(approval.renamedURL.lastPathComponent)")
                                    Button("Skip") { model.decide(approval, convert: false) }
                                        .accessibilityLabel("Skip \(approval.renamedURL.lastPathComponent)")
                                }
                            }.accessibilityElement(children: .contain)
                        }
                        Divider()
                    }
                    HStack {
                        Text("Format rules").font(.headline)
                        Spacer()
                        Button("Add Rule…") {
                            addingRule = true
                            editingRule = ConversionRule(sourceID: "png", targetID: "jpeg", action: model.automaticAction)
                        }.disabled(model.engine == nil)
                    }
                    ForEach(model.rules.sorted { $0.id < $1.id }) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(formatName(rule.sourceID)) → \(formatName(rule.targetID))")
                                Text(rule.action.title + (rule.settings == nil ? " · Global settings" : " · Saved settings"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") { addingRule = false; editingRule = rule }
                                .disabled(model.engine == nil)
                                .accessibilityLabel("Edit \(formatName(rule.sourceID)) to \(formatName(rule.targetID)) rule")
                            Button("Remove", systemImage: "minus.circle") { model.removeRule(rule) }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(formatName(rule.sourceID)) to \(formatName(rule.targetID)) rule")
                        }.accessibilityElement(children: .contain)
                    }
                    Text("A matching rule takes priority over the default action. Rules do not add support for a conversion.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Watched folders and their subfolders").font(.headline)
                    if model.watchWholeSystem {
                        Text("Saved watched folders are not used in whole-system mode. Excluded folders still apply.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.folders, id: \.self) { folder in folderRow(folder, excluded: false) }
                    if model.folders.isEmpty { Text("No watched folders").foregroundStyle(.secondary) }
                    Divider()
                    Text("Excluded folders").font(.headline)
                    ForEach(model.exclusions, id: \.self) { folder in folderRow(folder, excluded: true) }
                    if model.exclusions.isEmpty { Text("No excluded folders").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Add Watched Folder…") { model.chooseFolder() }
                Button("Exclude Folder…") { model.chooseFolder(excluded: true) }
            }.disabled(model.engine == nil)
            HStack {
                if model.activeJobs > 0 { ProgressView().controlSize(.small) }
                Text(model.activeJobs > 0 ? "\(model.activeJobs) active · \(model.queuedJobs) waiting" : model.automaticStatus)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Kept originals use their old names, or the detected extension for new arrivals. Originals are also kept for Undo in History.")
                .font(.caption).foregroundStyle(.secondary)
            if model.automaticAction != .immediately {
                Text("Skipped files keep their new names and unchanged contents. Pausing or changing this choice clears pending decisions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24)
            .sheet(item: $editingRule) { rule in
                ConversionRuleView(model: model, rule: rule, originalID: addingRule ? nil : rule.id)
            }
            .sheet(item: $selectedApproval) { approval in
                ConversionApprovalView(model: model, approval: approval)
            }
    }

    private func formatName(_ id: String) -> String {
        model.engine?.catalog.formats.first { $0.id == id }?.name ?? id
    }

    private func folderRow(_ folder: URL, excluded: Bool) -> some View {
        HStack {
            Label(folder.path, systemImage: "folder").lineLimit(2).textSelection(.enabled)
            Spacer()
            Button("Remove \(excluded ? "excluded" : "watched") folder \(folder.path)", systemImage: "minus.circle") {
                model.removeFolder(folder, excluded: excluded)
            }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless).help("Remove \(folder.lastPathComponent)")
                .disabled(model.engine == nil)
        }.accessibilityElement(children: .contain)
    }
}
