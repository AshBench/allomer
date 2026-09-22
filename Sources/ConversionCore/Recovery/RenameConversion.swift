import Darwin
import Foundation

public extension ConversionEngine {
    /// Convert a file after the user has changed its extension. Keep the displaced inode for undo.
    func convertRenamedFile(from originalURL: URL, to renamedURL: URL, historyDirectory: URL,
                            settings: ConversionSettings = ConversionSettings(),
                            keepOriginal: Bool = false,
                            detectedSourceID: String? = nil,
                            expectedIdentity: (device: Int32, inode: UInt64)? = nil,
                            id: UUID = UUID(),
                            stageOverrides: [ConversionStageOverride] = [],
                            progress: (@Sendable (URL, ConversionActivity.Step) -> Void)? = nil) throws -> ConversionRecord {
        let detected = detectedSourceID.flatMap { id in catalog.formats.first { $0.id == id } }
        guard detectedSourceID == nil || detected != nil,
              let input = detected ?? catalog.format(for: originalURL), let target = catalog.format(for: renamedURL),
              input.id != target.id else {
            throw ConversionError.message("This rename does not request a different known format.")
        }
        let inPlace = originalURL.standardizedFileURL.path == renamedURL.standardizedFileURL.path
        let visibleOriginal = inPlace ? originalURL.deletingPathExtension().appendingPathExtension(input.extensions[0]) : originalURL
        if keepOriginal, try !pathIsAbsent(visibleOriginal) {
            throw ConversionError.message("The original filename is already in use. Its contents were kept.")
        }
        let manager = FileManager.default
        let work = renamedURL.deletingLastPathComponent().appendingPathComponent(".allomer-\(id)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var retainRecoveryFiles = false
        defer { if !retainRecoveryFiles { try? manager.removeItem(at: work) } }
        let workLock = BackupRetention.lockWorkDirectory(work)
        defer { if workLock >= 0 { close(workLock) } }
        try BackupRetention.markWorkDirectory(work)
        // Reclaim residue from a conversion this folder never finished. Ours is locked, so it stays.
        BackupRetention.sweepAbandonedWork(in: work.deletingLastPathComponent(), historyDirectory: historyDirectory)
        let inputDirectory = work.appendingPathComponent("input")
        try manager.createDirectory(at: inputDirectory, withIntermediateDirectories: false)
        let snapshotName = detected == nil ? originalURL.lastPathComponent
            : originalURL.deletingPathExtension().appendingPathExtension(input.extensions[0]).lastPathComponent
        let snapshot = inputDirectory.appendingPathComponent(snapshotName)
        let output = work.appendingPathComponent("converted.\(target.extensions[0])")
        let backup = work.appendingPathComponent("original.\(input.extensions[0])")
        let initial = try SourceVersion(renamedURL)
        if let expectedIdentity {
            guard initial.device == expectedIdentity.device, initial.inode == expectedIdentity.inode else {
                throw ConversionError.message("The renamed file was replaced while waiting. Its contents were kept.")
            }
        }
        try cloneSource(renamedURL, to: snapshot)
        guard try SourceVersion(renamedURL) == initial else {
            throw ConversionError.message("The file changed while its backup was being made.")
        }
        let sourceHash = try sourceContentHash(snapshot)
        let resources = try convert(snapshot, to: output, settings: settings,
                    resourceDirectory: renamedURL.deletingLastPathComponent(),
                    stageOverrides: stageOverrides,
                    progress: { _, step in progress?(renamedURL, step) })
        // Directory permissions and Finder package attributes do not belong on a rendered image.
        if !initial.isPackage, copyfile(snapshot.path, output.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) != 0 {
            throw posixError()
        }
        let outputHash = try sourceContentHash(output)
        try manager.moveItem(at: output, to: backup)
        try manager.createDirectory(at: historyDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        var record = ConversionRecord(id: id, date: Date(), originalURL: originalURL, convertedURL: renamedURL,
            backupURL: backup, snapshotURL: snapshot, journalURL: historyDirectory.appendingPathComponent("\(id).json"),
            sourceHash: sourceHash, outputHash: outputHash, state: .prepared)
        record.resources = resources.isEmpty ? nil : resources
        record.keepOriginal = keepOriginal ? true : nil
        record.detectedSourceExtension = detected == nil ? nil : input.extensions[0]
        try BackupRetention.finishWorkDirectory(work)
        try record.saveNew()
        retainRecoveryFiles = true
        do { try coordinateReplacement(renamedURL) {
            try Task.checkCancellation()
            guard try SourceVersion(renamedURL) == initial, try sourceContentHash(renamedURL) == sourceHash else {
                throw ConversionError.message("The file changed during conversion. Its current contents were kept.")
            }
            for resource in resources { try resource.move(from: work, to: renamedURL.deletingLastPathComponent()) }
            try exchange(renamedURL, backup)
            do {
                guard try sourceContentHash(backup, checkCancellation: false) == sourceHash else {
                    throw ConversionError.message("The source changed at replacement time. Recovery files were kept.")
                }
                if keepOriginal { try record.publishOriginal() }
            } catch {
                try exchange(renamedURL, backup)
                throw error
            }
        } } catch {
            if (try? sourceContentHash(renamedURL, checkCancellation: false)) == sourceHash,
               (try? sourceContentHash(backup, checkCancellation: false)) == outputHash {
                for resource in resources {
                    try? resource.move(from: renamedURL.deletingLastPathComponent(), to: work, checkCancellation: false)
                }
            }
            throw error
        }
        record.state = .completed
        try record.save()
        return record
    }

    static func undo(_ saved: ConversionRecord) throws -> ConversionRecord {
        var restored: ConversionRecord?
        try coordinateReplacement(saved.journalURL) {
            let current = try JSONDecoder().decode(ConversionRecord.self, from: Data(contentsOf: saved.journalURL))
            guard current.id == saved.id, current.journalURL == saved.journalURL,
                  saved.canUndo, current.backupState == nil else {
                throw ConversionError.message("This conversion no longer has an available Undo backup.")
            }
            restored = try saved.multipleOutputs == nil ? undoCurrent(saved) : saved.undoMultiple()
        }
        return restored!
    }

    private static func undoCurrent(_ saved: ConversionRecord) throws -> ConversionRecord {
        guard try sourceContentHash(saved.backupURL) == saved.sourceHash else {
            throw ConversionError.message("The retained original has changed. It needs to be reviewed before undo.")
        }
        if saved.keepOriginal == true {
            try saved.validateOriginalPaths()
            guard try sourceContentHash(saved.visibleOriginalURL) == saved.sourceHash else {
                throw ConversionError.message("The visible original has changed. Undo would leave different source contents.")
            }
        } else {
            guard try saved.restoresInPlace || pathIsAbsent(saved.originalURL) else {
                throw ConversionError.message("The original filename is already in use.")
            }
        }
        guard try sourceContentHash(saved.convertedURL) == saved.outputHash else {
            throw ConversionError.message("The converted file has changed. Undo would discard those changes.")
        }
        for resource in saved.resources ?? [] { try resource.verify(in: saved.convertedURL.deletingLastPathComponent()) }
        var record = saved
        record.state = .undoPrepared
        try record.save()
        var retiredOriginal = false
        do { try coordinateReplacement(saved.convertedURL) {
            guard try sourceContentHash(saved.convertedURL) == saved.outputHash else {
                throw ConversionError.message("The converted file has changed. Undo would discard those changes.")
            }
            for resource in saved.resources ?? [] {
                try resource.move(from: saved.convertedURL.deletingLastPathComponent(), to: saved.backupURL.deletingLastPathComponent())
            }
            if saved.usesKeptOriginalUndo {
                try moveExclusively(saved.convertedURL, saved.undoneOutputURL)
                do {
                    guard try sourceContentHash(saved.originalURL, checkCancellation: false) == saved.sourceHash,
                          try sourceContentHash(saved.undoneOutputURL, checkCancellation: false) == saved.outputHash else {
                        throw ConversionError.message("A file changed at undo time. Recovery files were kept.")
                    }
                } catch {
                    try moveExclusively(saved.undoneOutputURL, saved.convertedURL)
                    throw error
                }
            } else {
                if saved.keepOriginal == true {
                    try moveExclusively(saved.visibleOriginalURL, saved.undoneOriginalURL)
                    retiredOriginal = true
                    guard try sourceContentHash(saved.undoneOriginalURL, checkCancellation: false) == saved.sourceHash else {
                        throw ConversionError.message("The original copy changed during Undo. Its contents were kept.")
                    }
                }
                try exchange(saved.convertedURL, saved.backupURL)
                do {
                    guard try sourceContentHash(saved.convertedURL, checkCancellation: false) == saved.sourceHash,
                          try sourceContentHash(saved.backupURL, checkCancellation: false) == saved.outputHash else {
                        throw ConversionError.message("A file changed at undo time. Recovery files were kept.")
                    }
                    if !saved.restoresInPlace { try moveExclusively(saved.convertedURL, saved.originalURL) }
                } catch {
                    try exchange(saved.convertedURL, saved.backupURL)
                    throw error
                }
            }
        } } catch {
            if (try? sourceContentHash(saved.convertedURL, checkCancellation: false)) == saved.outputHash {
                if retiredOriginal { try? moveExclusively(saved.undoneOriginalURL, saved.visibleOriginalURL) }
                for resource in saved.resources ?? [] {
                    try? resource.move(from: saved.backupURL.deletingLastPathComponent(), to: saved.convertedURL.deletingLastPathComponent(), checkCancellation: false)
                }
            }
            throw error
        }
        record.state = .undone
        try record.save()
        return record
    }
}
