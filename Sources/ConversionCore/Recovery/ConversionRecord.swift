import Darwin
import Foundation

public struct ConversionRecord: Codable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case prepared, completed, undoPrepared, undone, aborted, needsReview }
    public enum BackupState: String, Codable, Sendable { case removing, removed }
    public let id: UUID
    public let date: Date
    public let originalURL: URL
    public let convertedURL: URL
    public let backupURL: URL
    public let snapshotURL: URL
    public let journalURL: URL
    public let sourceHash: String
    public let outputHash: String
    public var state: State
    public var resources: [OutputResources]? = nil
    public var keepOriginal: Bool? = nil
    public var detectedSourceExtension: String? = nil
    public var multipleOutputs: MultipleOutputRecord? = nil
    public var backupState: BackupState? = nil
    var removalVolumeID: String? = nil
    var removalInode: UInt64? = nil

    public var canUndo: Bool { state == .completed && backupState == nil }
    public var recoveryDirectory: URL { backupURL.deletingLastPathComponent() }
    public var removalDirectory: URL {
        recoveryDirectory.deletingLastPathComponent().appendingPathComponent(".allomer-removing-\(id)")
    }

    var undoneOutputURL: URL { backupURL.deletingLastPathComponent().appendingPathComponent("undone-output") }
    var undoneOriginalURL: URL { recoveryDirectory.appendingPathComponent("undone-original") }
    var restoresInPlace: Bool { originalURL.standardizedFileURL.path == convertedURL.standardizedFileURL.path }
    var usesKeptOriginalUndo: Bool { keepOriginal == true && !restoresInPlace }
    public var visibleOriginalURL: URL {
        if let copy = multipleOutputs?.keptOriginalURL { return copy }
        if restoresInPlace, let ext = detectedSourceExtension {
            return originalURL.deletingPathExtension().appendingPathExtension(ext)
        }
        return originalURL
    }

    public var outputURLs: [URL] { multipleOutputs?.outputs.map(\.url) ?? [convertedURL] }

    func snapshotFilename() throws -> String {
        guard let ext = detectedSourceExtension else { return originalURL.lastPathComponent }
        guard !ext.isEmpty, ext.utf8.count <= 16, ext.utf8.allSatisfy({
            (48...57).contains($0) || (97...122).contains($0)
        }) else { throw ConversionError.message("The detected source extension is invalid.") }
        return originalURL.deletingPathExtension().appendingPathExtension(ext).lastPathComponent
    }

    func validateOriginalPaths() throws {
        let work = convertedURL.deletingLastPathComponent().appendingPathComponent(".allomer-\(id)")
        let snapshot = work.appendingPathComponent("input").appendingPathComponent(try snapshotFilename())
        guard originalURL.isFileURL, convertedURL.isFileURL, backupURL.isFileURL,
              backupURL.deletingLastPathComponent().standardizedFileURL.path == work.standardizedFileURL.path,
              backupURL.lastPathComponent.hasPrefix("original."),
              snapshotURL.standardizedFileURL.path == snapshot.standardizedFileURL.path,
              ![convertedURL, backupURL, snapshotURL, undoneOutputURL].map({ $0.standardizedFileURL.path })
                .contains(visibleOriginalURL.standardizedFileURL.path) else {
            throw ConversionError.message("The original-file recovery paths are invalid.")
        }
    }

    func publishOriginal() throws {
        try validateOriginalPaths()
        let version = try SourceVersion(backupURL, checkCancellation: false)
        let staged = backupURL.deletingLastPathComponent().appendingPathComponent("kept-original-\(UUID())")
        defer { try? FileManager.default.removeItem(at: staged) }
        try cloneSource(backupURL, to: staged)
        guard try SourceVersion(backupURL, checkCancellation: false) == version,
              try sourceContentHash(staged, checkCancellation: false) == sourceHash else {
            throw ConversionError.message("The original changed while its visible copy was being made.")
        }
        do { try moveExclusively(staged, visibleOriginalURL) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
            throw ConversionError.message("The original filename is now occupied. Its contents were kept.")
        }
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: journalURL, options: .atomic)
        let file = try FileHandle(forWritingTo: journalURL)
        defer { try? file.close() }
        try file.synchronize()
    }

    func saveNew() throws {
        try coordinateReplacement(journalURL) {
            guard try pathIsAbsent(journalURL) else { throw ConversionError.message("This conversion ID already has a history record.") }
            try save()
        }
    }

    /// Reconcile journal state with the files after an interrupted commit. Never discard a file.
    public static func loadHistory(from directory: URL) throws -> [ConversionRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let records = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try loadRecord(from: $0) }.sorted { $0.date > $1.date }
        guard Set(records.map(\.id)).count == records.count else {
            throw ConversionError.message("History contains duplicate conversion IDs.")
        }
        return records
    }

    public static func loadRecord(from url: URL) throws -> ConversionRecord {
        guard url.isFileURL else { throw ConversionError.message("A history journal must be a local file.") }
        var record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        let filenameID = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        guard record.journalURL.standardizedFileURL == url.standardizedFileURL,
              filenameID == nil || filenameID == record.id else {
            throw ConversionError.message("A history entry has an invalid journal path.")
        }
        if record.multipleOutputs != nil {
            try record.validateMultiplePaths()
            if record.backupState == nil, record.state == .prepared || record.state == .undoPrepared {
                record.reconcileMultiple()
                try record.save()
            }
            return record
        }
        if record.keepOriginal == true || record.detectedSourceExtension != nil { try record.validateOriginalPaths() }
        if record.backupState == nil, record.state == .prepared || record.state == .undoPrepared {
            let wasPreparingConversion = record.state == .prepared
            let current = try? sourceContentHash(record.convertedURL)
            let backup = try? sourceContentHash(record.backupURL)
            if current == record.outputHash, backup == record.sourceHash {
                record.state = .completed
            } else if record.state == .undoPrepared, record.restoresInPlace,
                      current == record.sourceHash, backup == record.outputHash {
                record.state = .undone
            } else if record.state == .prepared, current == record.sourceHash, backup == record.outputHash {
                record.state = .aborted
            } else if record.state == .undoPrepared, (try? pathIsAbsent(record.convertedURL)) == true,
                      (try? sourceContentHash(record.originalURL)) == record.sourceHash,
                      backup == (record.usesKeptOriginalUndo ? record.sourceHash : record.outputHash),
                      !record.usesKeptOriginalUndo || (try? sourceContentHash(record.undoneOutputURL)) == record.outputHash {
                record.state = .undone
            } else {
                record.state = .needsReview
            }
            if record.state != .needsReview {
                let live = record.convertedURL.deletingLastPathComponent()
                let retained = record.backupURL.deletingLastPathComponent()
                let expected = record.state == .completed ? live : retained
                let alternate = record.state == .completed ? retained : live
                do {
                    for resource in record.resources ?? [] {
                        if !FileManager.default.fileExists(atPath: expected.appendingPathComponent(resource.directoryName).path) {
                            try resource.move(from: alternate, to: expected)
                        }
                        try resource.verify(in: expected)
                    }
                    if record.state == .completed, record.keepOriginal == true {
                        if try pathIsAbsent(record.visibleOriginalURL) {
                            if wasPreparingConversion { try record.publishOriginal() }
                            else if record.restoresInPlace,
                                    try sourceContentHash(record.undoneOriginalURL) == record.sourceHash {
                                try moveExclusively(record.undoneOriginalURL, record.visibleOriginalURL)
                            }
                        }
                        guard try sourceContentHash(record.visibleOriginalURL) == record.sourceHash else {
                            throw ConversionError.message("The visible original has changed.")
                        }
                    }
                    if record.state == .undone, record.restoresInPlace, record.keepOriginal == true {
                        guard try pathIsAbsent(record.visibleOriginalURL),
                              try sourceContentHash(record.undoneOriginalURL) == record.sourceHash else {
                            throw ConversionError.message("The original copy needs review after Undo.")
                        }
                    }
                } catch { record.state = .needsReview }
            }
            try record.save()
        }
        return record
    }
}
