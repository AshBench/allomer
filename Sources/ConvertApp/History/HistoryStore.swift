import ConversionCore
import Foundation

enum HistoryStore {
    struct Contents: Sendable {
        var entries: [ConversionActivity]
        var hiddenIDs: Set<UUID>
    }

    static func load(from directory: URL) throws -> Contents {
        guard FileManager.default.fileExists(atPath: directory.path) else { return Contents(entries: [], hiddenIDs: []) }
        let hidden = directory.appendingPathComponent("hidden.json")
        let hiddenIDs = FileManager.default.fileExists(atPath: hidden.path)
            ? try JSONDecoder().decode(Set<UUID>.self, from: read(hidden)) : []
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "hidden.json" }
            .compactMap { url -> ConversionActivity? in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                    throw ConversionError.message("A history entry has an invalid filename.")
                }
                if hiddenIDs.contains(id) { return nil }
                let entry = try JSONDecoder().decode(ConversionActivity.self, from: read(url))
                guard entry.id == id, url.lastPathComponent == "\(entry.id).json", entry.originalURL.isFileURL, entry.requestedURL.isFileURL,
                      entry.outputURLs.count <= 256, entry.outputURLs.allSatisfy(\.isFileURL),
                      entry.configurations.count <= 256, entry.configurations.allSatisfy({ configuration in
                          let steps = configuration.steps ?? []
                          return configuration.outputURL.isFileURL && steps.count <= 256
                              && Set(steps.map(\.id)).count == steps.count
                              && steps.allSatisfy { $0.count > 0 && $0.count <= 256 && $0.id >= 0 && $0.id < $0.count
                                  && [.running, .completed, .failed, .cancelled].contains($0.state) }
                      }) else {
                    throw ConversionError.message("A history entry has invalid file information.")
                }
                return entry
            }
        return Contents(entries: entries, hiddenIDs: hiddenIDs)
    }

    static func save(_ entry: ConversionActivity, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try write(JSONEncoder().encode(entry), to: directory.appendingPathComponent("\(entry.id).json"))
    }

    static func clear(_ ids: Set<UUID>, previouslyHidden: Set<UUID>, in directory: URL) throws -> Set<UUID> {
        let hidden = previouslyHidden.union(ids)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Record the hidden IDs first. A stopped clear cannot expose old journal rows again.
        try write(JSONEncoder().encode(hidden), to: directory.appendingPathComponent("hidden.json"))
        for id in ids {
            let file = directory.appendingPathComponent("\(id).json")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        return hidden
    }

    private static func read(_ file: URL) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 16 * 1024 * 1024 else {
            throw ConversionError.message("History metadata must be a regular file of at most 16 MiB.")
        }
        return try Data(contentsOf: file)
    }

    private static func write(_ data: Data, to file: URL) throws {
        guard data.count <= 16 * 1024 * 1024 else { throw ConversionError.message("History metadata exceeds 16 MiB.") }
        try data.write(to: file, options: .atomic)
    }
}
