import ConversionCore
import SwiftUI

struct ConversionStageSettingsView: View {
    let engine: ConversionEngine
    let source: FileFormat?
    let target: FileFormat
    var sourceURL: URL?
    let baseSettings: ConversionSettings
    @Binding var overrides: [ConversionStageOverride]
    @State private var route: [FileFormat] = []
    @State private var loading = true
    @State private var selected = 0
    @Environment(\.dismiss) private var dismiss

    private func input(at index: Int) -> FileFormat? { index == 0 ? source : route[index - 1] }
    private func key(at index: Int) -> String { (input(at: index)?.id ?? "file") + ":" + route[index].id }
    private var inheritedSettings: ConversionSettings {
        var settings = baseSettings
        if selected > 0 { settings.spreadsheetOptions.sheetIndex = 0 }
        return settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stage settings").font(.title.bold())
            if loading { ProgressView("Reading the conversion route…") }
            else if route.isEmpty { Text("No conversion route is available for this pair.") }
            else if route.indices.contains(selected) {
                let input = input(at: selected)
                let output = route[selected]
                let id = key(at: selected)
                let defaults = inheritedSettings
                Picker("Conversion stage", selection: $selected) {
                    ForEach(route.indices, id: \.self) { index in
                        Text("\(index + 1): \(self.input(at: index)?.name ?? "File") → \(route[index].name)").tag(index)
                    }
                }.accessibilityLabel("Conversion stage")
                Toggle("Override settings for this stage", isOn: Binding(
                    get: { overrides.contains { $0.id == id } },
                    set: { enabled in
                        overrides.removeAll { $0.id == id }
                        if enabled { overrides.append(.init(sourceID: input?.id, targetID: output.id, settings: defaults)) }
                    }))
                Form {
                    ConversionOptionsView(settings: Binding(
                        get: { overrides.first { $0.id == id }?.settings ?? defaults },
                        set: { value in
                            if let index = overrides.firstIndex(where: { $0.id == id }) { overrides[index].settings = value }
                        }), targetID: output.id,
                        source: input.map { URL(fileURLWithPath: "/file." + $0.extensions[0]) }, sourceID: input?.id,
                        showPerformance: false, category: output.category, sourceCategory: input?.category)
                }.formStyle(.grouped).disabled(!overrides.contains { $0.id == id })
            }
            let keys = Set(route.indices.map { key(at: $0) })
            if !loading, overrides.contains(where: { !keys.contains($0.id) }) {
                Text("Some saved overrides do not match this route. Conversion will stop until they are reviewed.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Remove Unused Overrides") { overrides.removeAll { !keys.contains($0.id) } }
            }
            Text("Other stages use the output defaults. CPU use follows the global setting. Format-only previews can differ from a file's actual route; mismatched overrides stop conversion.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Use Defaults for All Stages") { overrides = [] }.disabled(overrides.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 600, height: 620)
            .task(id: [sourceURL?.absoluteString ?? "", source?.id ?? "", target.id]) {
                loading = true
                route = []
                selected = 0
                let planned = await Task.detached(priority: .utility) { [engine, sourceURL, source, target] in
                    if let sourceURL { return engine.conversionRoute(from: sourceURL, to: target) ?? [] }
                    if let source { return engine.conversionRoute(from: source, to: target) ?? [] }
                    return []
                }.value
                guard !Task.isCancelled else { return }
                route = planned
                loading = false
            }
    }
}
