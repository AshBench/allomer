import Darwin
import Foundation

public struct BackupRetentionOptions: Codable, Equatable, Sendable {
    public var limitAge = false
    public var maximumAgeDays = 30
    public var limitSize = false
    public var maximumSizeGiB = 10.0
    public init() {}

    public func validate() throws {
        guard maximumSizeGiB.isFinite else { throw ConversionError.message("Enter a finite backup size in GiB.") }
        _ = try byteLimit()
    }

    func byteLimit() throws -> Int64? {
        guard !limitAge || maximumAgeDays > 0 else {
            throw ConversionError.message("The maximum backup age must be at least one day.")
        }
        guard limitSize else { return nil }
        let bytes = maximumSizeGiB * 1_073_741_824
        guard bytes.isFinite, bytes >= 1, bytes < Double(Int64.max) else {
            throw ConversionError.message("Enter a positive backup size in GiB.")
        }
        return Int64(bytes)
    }
}

public struct BackupCleanupResult: Sendable {
    public var records: [ConversionRecord]
    public var retainedBytes: Int64
    public var removedCount: Int
    public var issues: [String]
}

public enum BackupRetention {
    private static let workMarkerName = ".in-progress"
    private static let workMarker = Data("Allomer conversion work v1\n".utf8)

    /// The caller must exclude active conversions and pause new jobs until cleanup finishes.
    // Hold a work directory for as long as a conversion owns it. The kernel releases the lock when
    // the descriptor closes, including when the process dies, which is how the sweep below tells a
    // live directory from one left behind. Best effort: a failed lock never fails a conversion.
    static func lockWorkDirectory(_ directory: URL) -> Int32 {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return -1
        }
        return descriptor
    }

    static func markWorkDirectory(_ directory: URL) throws {
        try workMarker.write(to: directory.appendingPathComponent(workMarkerName), options: .withoutOverwriting)
    }

    static func finishWorkDirectory(_ directory: URL) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(workMarkerName))
    }

    /// Remove conversion work directories beside a file that no journal records and no process holds.
    /// This reclaims crash residue only. A live directory is locked, and a recorded one keeps its
    /// journal, so neither is touched. Cleanup by age and size still works from history alone.
    static func sweepAbandonedWork(in parent: URL, historyDirectory: URL) {
        let prefix = ".allomer-"
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            // A strict identifier keeps the removal directories and any unrelated name out of this.
            guard let id = UUID(uuidString: String(name.dropFirst(prefix.count))),
                  !manager.fileExists(atPath: historyDirectory.appendingPathComponent("\(id).json").path) else { continue }
            let directory = parent.appendingPathComponent(name)
            // lstat, so a symbolic link wearing the name is never followed or removed.
            guard let version = try? FileVersion(directory, allowingDirectories: true), version.isDirectory else { continue }
            let descriptor = lockWorkDirectory(directory)
            guard descriptor >= 0 else { continue }
            if (try? FileVersion(directory, allowingDirectories: true)) == version,
               isUnfinishedWork(directory),
               (try? FileVersion(directory, allowingDirectories: true)) == version {
                try? manager.removeItem(at: directory)
            }
            close(descriptor)
        }
    }

    /// True when a directory is marked as conversion work or has the legacy unfinished shape.
    ///
    /// A retained recovery directory always names its backup `original.<extension>`, and may also
    /// hold `output-<n>`, `kept-original`, `undone-output` or `undone-original`. New work carries an
    /// exact marker until publication, so a crash can leave arbitrary converter temporary files.
    /// Older work holds only the input snapshot folder and at most a partly written
    /// `converted.<extension>`. Judging contents as well as the absent journal means a backup
    /// recorded in some other history location is still never removed.
    private static func isUnfinishedWork(_ directory: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        if entries.contains(workMarkerName) {
            let marker = directory.appendingPathComponent(workMarkerName)
            guard let size = try? FileVersion(marker).size, size == Int64(workMarker.count),
                  (try? Data(contentsOf: marker)) == workMarker else { return false }
            return true
        }
        return entries.allSatisfy { $0 == "input" || $0.hasPrefix("converted.") }
    }

    public static func clean(_ history: [ConversionRecord], options: BackupRetentionOptions,
                             removeAll: Bool = false, now: Date = Date()) throws -> BackupCleanupResult {
        let limit = removeAll ? nil : try options.byteLimit()
        var result = BackupCleanupResult(records: history, retainedBytes: 0, removedCount: 0, issues: [])
        var sizes: [Int: Int64] = [:]
        var sizesKnown = true
        for index in history.indices where history[index].backupState != .removed {
            try Task.checkCancellation()
            let record = history[index]
            var removalError: Error?
            if record.backupState == .removing {
                do {
                    result.records[index] = try remove(record, force: true)
                    result.removedCount += 1
                    continue
                } catch { removalError = error }
            }
            do {
                let size = try remainingSize(record)
                let sum = result.retainedBytes.addingReportingOverflow(size)
                guard !sum.overflow else { throw ConversionError.message("Backup sizes exceed the supported total.") }
                result.retainedBytes = sum.partialValue
                if record.backupState == nil { sizes[index] = size }
                if let removalError { result.issues.append("\(record.originalURL.lastPathComponent): \(removalError.localizedDescription)") }
            } catch {
                sizesKnown = false
                result.issues.append("\(record.originalURL.lastPathComponent): \((removalError ?? error).localizedDescription)")
            }
        }
        for index in sizes.keys.sorted(by: { history[$0].date < history[$1].date }) {
            try Task.checkCancellation()
            let old = history[index]
            let expired = options.limitAge && now.timeIntervalSince(old.date) >= Double(options.maximumAgeDays) * 86_400
            guard removeAll || expired || (sizesKnown && (limit.map { result.retainedBytes > $0 } ?? false)) else { continue }
            do {
                let updated = try remove(old, force: removeAll)
                result.records[index] = updated
                result.retainedBytes -= sizes[index]!
                result.removedCount += 1
            } catch {
                // A failed deletion may already have moved the owned directory. Keep its saved state.
                if let current = try? JSONDecoder().decode(ConversionRecord.self, from: Data(contentsOf: old.journalURL)),
                   current.id == old.id, current.journalURL == old.journalURL { result.records[index] = current }
                if let remaining = try? remainingSize(result.records[index]) {
                    result.retainedBytes -= sizes[index]!
                    let sum = result.retainedBytes.addingReportingOverflow(remaining)
                    if sum.overflow { sizesKnown = false } else { result.retainedBytes = sum.partialValue }
                } else { sizesKnown = false }
                result.issues.append("\(old.originalURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    private static func remainingSize(_ record: ConversionRecord) throws -> Int64 {
        try validatePaths(record)
        if record.backupState == .removed { return 0 }
        if record.backupState == .removing {
            let directory = try pathIsAbsent(record.removalDirectory) ? record.recoveryDirectory : record.removalDirectory
            try verifyIdentity(directory, record: record)
            return try logicalSize(directory)
        }
        return try logicalSize(record.recoveryDirectory)
    }

    private static func validatePaths(_ record: ConversionRecord) throws {
        if record.multipleOutputs != nil { try record.validateMultiplePaths() }
        let root = record.recoveryDirectory.standardizedFileURL
        let parent = record.convertedURL.deletingLastPathComponent().standardizedFileURL
        let snapshot = root.appendingPathComponent("input").appendingPathComponent(try record.snapshotFilename())
        guard [record.originalURL, record.convertedURL, record.backupURL, record.snapshotURL, record.journalURL].allSatisfy(\.isFileURL),
              root.deletingLastPathComponent().path == parent.path, root.lastPathComponent == ".allomer-\(record.id)",
              record.backupURL.lastPathComponent.hasPrefix("original."),
              record.snapshotURL.standardizedFileURL.path == snapshot.standardizedFileURL.path,
              record.journalURL.lastPathComponent == "\(record.id).json",
              ![record.originalURL, record.convertedURL, record.journalURL].contains(where: {
                  $0.standardizedFileURL.path == root.path || $0.standardizedFileURL.path.hasPrefix(root.path + "/")
              }) else { throw ConversionError.message("The backup paths need review before cleanup.") }
    }

    private static func logicalSize(_ directory: URL) throws -> Int64 {
        guard try FileVersion(directory, allowingDirectories: true).isDirectory else {
            throw ConversionError.message("The backup is not a regular directory.")
        }
        var failure: Error?
        guard let entries = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey], errorHandler: { _, error in
                failure = error
                return false
            }) else { throw ConversionError.message("The backup directory could not be read.") }
        var total: Int64 = 0
        for case let file as URL in entries {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if values.isSymbolicLink == true { entries.skipDescendants(); continue }
            if values.isRegularFile == true {
                guard let size = values.fileSize, size >= 0 else { throw ConversionError.message("A backup file has no valid size.") }
                let sum = total.addingReportingOverflow(Int64(size))
                guard !sum.overflow else { throw ConversionError.message("A backup exceeds the supported size.") }
                total = sum.partialValue
            }
        }
        if let failure { throw failure }
        return total
    }

    private static func verifyContents(_ record: ConversionRecord) throws {
        if record.multipleOutputs != nil { try record.verifyMultipleRetained(); return }
        let backupHash = record.state == .completed || (record.state == .undone && record.usesKeptOriginalUndo)
            ? record.sourceHash : record.outputHash
        guard try sourceContentHash(record.backupURL) == backupHash,
              try sourceContentHash(record.snapshotURL) == record.sourceHash else {
            throw ConversionError.message("A backup was edited. Review it or use Clear All Backups.")
        }
        if record.state == .undone, record.usesKeptOriginalUndo {
            guard try sourceContentHash(record.undoneOutputURL) == record.outputHash else {
                throw ConversionError.message("A retained output was edited. Review it before cleanup.")
            }
        }
        if record.state == .undone, record.restoresInPlace, record.keepOriginal == true {
            guard try sourceContentHash(record.undoneOriginalURL) == record.sourceHash else {
                throw ConversionError.message("A retained original copy was edited. Review it before cleanup.")
            }
        }
        if record.state == .undone || record.state == .aborted {
            for resource in record.resources ?? [] { try resource.verify(in: record.recoveryDirectory) }
        }
    }

    private static func volumeID(_ directory: URL) throws -> String {
        guard let value = try directory.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else {
            throw ConversionError.message("The backup volume has no stable identifier for cleanup.")
        }
        return value
    }

    private static func verifyIdentity(_ directory: URL, record: ConversionRecord) throws {
        let version = try FileVersion(directory, allowingDirectories: true)
        guard version.isDirectory, version.inode == record.removalInode,
              try volumeID(directory) == record.removalVolumeID else {
            throw ConversionError.message("The backup directory was replaced. It was not removed.")
        }
    }

    private static func remove(_ saved: ConversionRecord, force: Bool) throws -> ConversionRecord {
        var result = saved
        try coordinateReplacement(saved.journalURL) {
            var record = try JSONDecoder().decode(ConversionRecord.self, from: Data(contentsOf: saved.journalURL))
            guard record.id == saved.id, record.journalURL == saved.journalURL else {
                throw ConversionError.message("The history entry changed before cleanup.")
            }
            try validatePaths(record)
            if record.backupState == .removed { result = record; return }
            if record.backupState == nil {
                guard ![.prepared, .undoPrepared].contains(record.state), force || record.state != .needsReview else {
                    throw ConversionError.message("This backup needs recovery before automatic cleanup.")
                }
                let version = try FileVersion(record.recoveryDirectory, allowingDirectories: true)
                guard version.isDirectory else { throw ConversionError.message("The backup directory was replaced.") }
                if !force { try verifyContents(record) }
                guard try FileVersion(record.recoveryDirectory, allowingDirectories: true) == version else {
                    throw ConversionError.message("The backup directory changed during cleanup checks.")
                }
                try Task.checkCancellation()
                record.removalVolumeID = try volumeID(record.recoveryDirectory)
                record.removalInode = version.inode
                record.backupState = .removing
                try record.save()
            }
            // Finish a committed removal even if the caller cancels. Later backups can still be skipped.
            guard let volume = record.removalVolumeID, record.removalInode != nil,
                  try volumeID(record.recoveryDirectory.deletingLastPathComponent()) == volume else {
                throw ConversionError.message("The backup volume is unavailable. Cleanup will retry later.")
            }
            if try pathIsAbsent(record.removalDirectory), try !pathIsAbsent(record.recoveryDirectory) {
                try verifyIdentity(record.recoveryDirectory, record: record)
                try moveExclusively(record.recoveryDirectory, record.removalDirectory)
            }
            if try !pathIsAbsent(record.removalDirectory) {
                try verifyIdentity(record.removalDirectory, record: record)
                try FileManager.default.removeItem(at: record.removalDirectory)
            }
            record.backupState = .removed
            record.removalInode = nil
            record.removalVolumeID = nil
            try record.save()
            result = record
        }
        return result
    }
}
