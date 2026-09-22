import Foundation

public struct MultipleOutputName: Sendable {
    public struct Target: Sendable {
        public let format: FileFormat
        public let url: URL
    }

    public let baseURL: URL
    public let targets: [Target]
    public let unknownExtensions: [String]

    public init?(_ file: URL, catalog: FormatCatalog, originalExtension: String? = nil) {
        guard file.isFileURL else { return nil }
        let name = file.lastPathComponent
        let commas = name.indices.filter { name[$0] == "," }
        let known = catalog.formats.flatMap(\.extensions)
        let comma = commas.first { index in known.contains { name[..<index].lowercased().hasSuffix("." + $0) } }
            ?? commas.first { name[..<$0].contains(".") }
        guard let comma,
              let dot = name[..<comma].lastIndex(of: ".") else { return nil }
        let prefix = name[..<comma]
        let suffix = known
            .filter { prefix.lowercased().hasSuffix("." + $0) }.max { $0.count < $1.count }
        let start = suffix.map { name.index(comma, offsetBy: -$0.count) } ?? name.index(after: dot)
        let base = String(name[..<name.index(before: start)])
        guard !base.isEmpty else { return nil }
        var extensions = String(name[start...]).split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        guard extensions.count >= 2, extensions.allSatisfy({ !$0.isEmpty }) else { return nil }
        // Finder can append the old extension after a comma-separated target list.
        if let old = originalExtension?.lowercased(), !old.isEmpty,
           let last = extensions.last, catalog.format(forExtension: last) == nil,
           last.lowercased().hasSuffix("." + old) {
            let corrected = String(last.dropLast(old.count + 1))
            if catalog.format(forExtension: corrected) != nil { extensions[extensions.count - 1] = corrected }
        }
        baseURL = file.deletingLastPathComponent().appendingPathComponent(base, isDirectory: false)
        var seen: Set<String> = []
        var targets: [Target] = []
        var unknown: [String] = []
        for ext in extensions {
            guard let format = catalog.format(forExtension: ext) else { unknown.append(ext); continue }
            if seen.insert(format.id).inserted {
                targets.append(Target(format: format, url: baseURL.appendingPathExtension(ext.lowercased())))
            }
        }
        self.targets = targets
        unknownExtensions = unknown
    }
}
