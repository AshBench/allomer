import ConversionCore

extension ConversionModel {
    func rule(sourceID: String, targetID: String) -> ConversionRule? {
        rules.first { $0.sourceID == sourceID && $0.targetID == targetID }
    }

    func saveRule(_ rule: ConversionRule, replacing id: String? = nil) {
        rules = rules.filter { $0.id != rule.id && $0.id != id } + [rule]
    }

    func removeRule(_ rule: ConversionRule) {
        rules.removeAll { $0.id == rule.id }
    }

    func settings(for approval: ConversionApproval) -> ConversionSettings {
        guard let source = sourceFormat(for: approval),
              let target = engine?.catalog.format(for: approval.renamedURL) else { return settings }
        return rule(sourceID: source.id, targetID: target.id)?.settings ?? settings
    }

    func keepOriginal(for approval: ConversionApproval) -> Bool {
        guard let source = sourceFormat(for: approval),
              let target = engine?.catalog.format(for: approval.renamedURL) else { return keepOriginal }
        return rule(sourceID: source.id, targetID: target.id)?.keepOriginal ?? keepOriginal
    }

    func stageOverrides(for approval: ConversionApproval) -> [ConversionStageOverride] {
        guard let source = sourceFormat(for: approval), let target = engine?.catalog.format(for: approval.renamedURL) else { return [] }
        return rule(sourceID: source.id, targetID: target.id)?.stageOverrides ?? []
    }

    func sourceFormat(for approval: ConversionApproval) -> FileFormat? {
        if let id = approval.detectedSourceID { return engine?.catalog.formats.first { $0.id == id } }
        return engine?.catalog.format(for: approval.originalURL)
    }

    func decide(_ approval: ConversionApproval, convert: Bool,
                settings: ConversionSettings? = nil, keepOriginal: Bool? = nil, remember: Bool = false,
                stageOverrides: [ConversionStageOverride]? = nil) {
        let selected = settings ?? self.settings(for: approval)
        let keepOriginal = keepOriginal ?? self.keepOriginal(for: approval)
        let stages = stageOverrides ?? self.stageOverrides(for: approval)
        guard automatic?.decide(approval.id, convert: convert, settings: selected, keepOriginal: keepOriginal, stageOverrides: stages) == true,
              convert, remember,
              let source = sourceFormat(for: approval),
              let target = engine?.catalog.format(for: approval.renamedURL), source.id != target.id else { return }
        let action = rule(sourceID: source.id, targetID: target.id)?.action ?? automaticAction
        saveRule(ConversionRule(sourceID: source.id, targetID: target.id, action: action,
                               settings: selected, keepOriginal: keepOriginal, stageOverrides: stages.isEmpty ? nil : stages))
    }

}
