import ConversionCore
import SwiftUI

struct ConversionRuleView: View {
    let model: ConversionModel
    @State var rule: ConversionRule
    let originalID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ConversionSettings
    @State private var customSettings: Bool
    @State private var stageOverrides: [ConversionStageOverride]
    @State private var editingStages = false

    init(model: ConversionModel, rule: ConversionRule, originalID: String?) {
        self.model = model
        self._rule = State(initialValue: rule)
        self.originalID = originalID
        self._settings = State(initialValue: rule.settings ?? model.settings)
        self._customSettings = State(initialValue: rule.settings != nil)
        self._stageOverrides = State(initialValue: rule.stageOverrides ?? [])
    }

    private var formats: [FileFormat] { model.engine?.catalog.formats.sorted { $0.name < $1.name } ?? [] }
    private var source: FileFormat? { formats.first { $0.id == rule.sourceID } }
    private var target: FileFormat? { formats.first { $0.id == rule.targetID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Format rule").font(.title.bold())
            Form {
                Picker("From", selection: $rule.sourceID) {
                    ForEach(formats, id: \.id) { Text($0.name).tag($0.id) }
                }.accessibilityLabel("Convert from")
                Picker("To", selection: $rule.targetID) {
                    ForEach(formats, id: \.id) { Text($0.name).tag($0.id) }
                }.accessibilityLabel("Convert to")
                Picker("Action", selection: $rule.action) {
                    ForEach(AutomaticConversionAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityLabel("Action")
                if rule.action != .doNotConvert {
                    Picker("Original file", selection: $rule.keepOriginal) {
                        Text("Use the default setting").tag(nil as Bool?)
                        Text("Keep at its original name").tag(Optional(true))
                        Text("Keep only for Undo").tag(Optional(false))
                    }.accessibilityLabel("Original file")
                    Toggle("Save conversion settings for this pair", isOn: $customSettings)
                        .accessibilityLabel("Save conversion settings for this pair")
                    if customSettings, let source, let target {
                        ConversionOptionsView(settings: $settings, targetID: target.id,
                            source: URL(fileURLWithPath: "/file." + source.extensions[0]), sourceID: source.id,
                            showPerformance: false, category: target.category, sourceCategory: source.category)
                    } else {
                        Text("Uses the current global conversion settings.").foregroundStyle(.secondary)
                    }
                    Button("Stage Settings…") { editingStages = true }.disabled(source == nil || target == nil)
                }
            }.formStyle(.grouped)
            Text("The rule applies to future extension changes. Saving replaces any rule for the selected pair.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Rule") {
                    rule.settings = customSettings ? settings : nil
                    rule.stageOverrides = stageOverrides.isEmpty ? nil : stageOverrides
                    model.saveRule(rule, replacing: originalID)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
                    .disabled(source == nil || target == nil || rule.sourceID == rule.targetID)
            }
        }.padding(24).frame(width: 600, height: 600)
            .onChange(of: rule.sourceID) { stageOverrides = [] }
            .onChange(of: rule.targetID) { stageOverrides = [] }
            .sheet(isPresented: $editingStages) {
                if let engine = model.engine, let source, let target {
                    ConversionStageSettingsView(engine: engine, source: source, target: target,
                        baseSettings: customSettings ? settings : model.settings, overrides: $stageOverrides)
                }
            }
    }
}

struct ConversionApprovalView: View {
    let model: ConversionModel
    let approval: ConversionApproval
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ConversionSettings
    @State private var remember = false
    @State private var keepOriginal: Bool
    @State private var stageOverrides: [ConversionStageOverride]
    @State private var editingStages = false

    init(model: ConversionModel, approval: ConversionApproval) {
        self.model = model
        self.approval = approval
        self._settings = State(initialValue: model.settings(for: approval))
        self._keepOriginal = State(initialValue: model.keepOriginal(for: approval))
        self._stageOverrides = State(initialValue: model.stageOverrides(for: approval))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Conversion settings").font(.title.bold())
            Text("\(approval.originalURL.lastPathComponent) → \(approval.renamedURL.lastPathComponent)")
                .lineLimit(2).textSelection(.enabled)
            Form {
                if let source = model.sourceFormat(for: approval),
                   let target = model.engine?.catalog.format(for: approval.renamedURL) {
                    if source.id == target.id {
                        Text("This output keeps the original contents without re-encoding them.")
                    } else {
                        ConversionOptionsView(settings: $settings, targetID: target.id,
                            source: approval.inputURL ?? approval.renamedURL, sourceID: source.id, showPerformance: false,
                            category: target.category, sourceCategory: source.category)
                        Button("Stage Settings…") { editingStages = true }
                    }
                }
            }.formStyle(.grouped)
            Toggle("Keep the original file after conversion", isOn: $keepOriginal)
            Toggle("Remember settings for this pair", isOn: $remember)
                .disabled(model.sourceFormat(for: approval)?.id == model.engine?.catalog.format(for: approval.renamedURL)?.id)
            Text("Remembering settings keeps the current action for this pair. CPU use follows the global setting.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Convert") {
                    model.decide(approval, convert: true, settings: settings, keepOriginal: keepOriginal, remember: remember,
                        stageOverrides: stageOverrides)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
                    .disabled(!model.approvals.contains { $0.id == approval.id })
            }
        }.padding(24).frame(width: 600, height: 600)
            .sheet(isPresented: $editingStages) {
                if let engine = model.engine, let target = engine.catalog.format(for: approval.renamedURL) {
                    ConversionStageSettingsView(engine: engine, source: model.sourceFormat(for: approval), target: target,
                        baseSettings: settings, overrides: $stageOverrides)
                }
            }
            .onChange(of: model.approvals.map(\.id)) {
                if !model.approvals.contains(where: { $0.id == approval.id }) { dismiss() }
            }
    }
}
