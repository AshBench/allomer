import Darwin
import Foundation

public struct ConversionDestination: Sendable {
    public let url: URL
    public var settings: ConversionSettings
    public var stageOverrides: [ConversionStageOverride]
    public init(url: URL, settings: ConversionSettings = ConversionSettings(), stageOverrides: [ConversionStageOverride] = []) {
        self.url = url
        self.settings = settings
        self.stageOverrides = stageOverrides
    }
}

public struct MultipleOutputRecord: Codable, Sendable {
    public struct Output: Codable, Sendable {
        public let url: URL
        public let hash: String
        let inode: UInt64
    }
    public let requestURL: URL
    public let outputs: [Output]
    let sourceInode: UInt64
    let resourceInodes: [String: UInt64]
    let keptOriginal: Output?
    public var keptOriginalURL: URL? { keptOriginal?.url }
    public let issues: [String]
}

public extension ConversionEngine {
    func convertToMultipleFormats(from original: URL, at request: URL, destinations: [ConversionDestination],
                                  sourceID: String, historyDirectory: URL, keepOriginal: Bool = false,
                                  issues initialIssues: [String] = [],
                                  expectedIdentity: (device: Int32, inode: UInt64)? = nil,
                                  id: UUID = UUID(),
                                  progress: (@Sendable (URL, ConversionActivity.Step) -> Void)? = nil) throws -> ConversionRecord {
        guard let source = catalog.formats.first(where: { $0.id == sourceID }), !destinations.isEmpty else {
            throw ConversionError.message("Choose a known source and at least one output format.")
        }
        let parent = request.deletingLastPathComponent()
        let paths = destinations.map { $0.url.standardizedFileURL.path }
        guard original.isFileURL, request.isFileURL, Set(paths).count == paths.count,
              destinations.allSatisfy({ $0.url.isFileURL && $0.url.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path
                  && $0.url.standardizedFileURL.path != request.standardizedFileURL.path }) else {
            throw ConversionError.message("Output names must be distinct files beside the renamed source.")
        }
        let originalCopy: URL?
        if keepOriginal {
            if catalog.format(for: original)?.id == source.id { originalCopy = original }
            else {
                let base = MultipleOutputName(request, catalog: catalog, originalExtension: original.pathExtension)?.baseURL
                    ?? original.deletingPathExtension()
                originalCopy = base.appendingPathExtension(source.extensions[0])
            }
        } else { originalCopy = nil }
        if let copy = originalCopy, try !pathIsAbsent(copy) {
            throw ConversionError.message("The original filename is already in use. Its contents were kept.")
        }
        let manager = FileManager.default
        let work = parent.appendingPathComponent(".allomer-\(id)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var retain = false
        defer { if !retain { try? manager.removeItem(at: work) } }
        let workLock = BackupRetention.lockWorkDirectory(work)
        defer { if workLock >= 0 { close(workLock) } }
        try BackupRetention.markWorkDirectory(work)
        BackupRetention.sweepAbandonedWork(in: parent, historyDirectory: historyDirectory)
        let inputDirectory = work.appendingPathComponent("input")
        try manager.createDirectory(at: inputDirectory, withIntermediateDirectories: false)
        let snapshot = inputDirectory.appendingPathComponent(original.deletingPathExtension()
            .appendingPathExtension(source.extensions[0]).lastPathComponent)
        let initial = try SourceVersion(request)
        if let identity = expectedIdentity, initial.device != identity.device || initial.inode != identity.inode {
            throw ConversionError.message("The renamed file was replaced while waiting. Its contents were kept.")
        }
        try cloneSource(request, to: snapshot)
        guard try SourceVersion(request) == initial else { throw ConversionError.message("The source changed while its snapshot was made.") }
        let sourceHash = try sourceContentHash(snapshot)
        var outputs: [MultipleOutputRecord.Output] = []
        var resources: [OutputResources] = []
        var issues = initialIssues
        for destination in destinations {
            try Task.checkCancellation()
            do {
                guard try pathIsAbsent(destination.url), let target = catalog.format(for: destination.url) else {
                    throw ConversionError.message("The output name is occupied or its format is unknown.")
                }
                if destination.url.standardizedFileURL.path == originalCopy?.standardizedFileURL.path, target.id != source.id {
                    throw ConversionError.message("The output would occupy the kept original's name.")
                }
                let encoded = work.appendingPathComponent("encoded-\(UUID()).\(target.extensions[0])")
                var companions: [OutputResources] = []
                if source.id == target.id {
                    guard destination.stageOverrides.isEmpty else {
                        throw ConversionError.message("A source copy has no configurable conversion stages.")
                    }
                    var step = ConversionActivity.Step(index: 0, count: 1, sourceID: source.id, targetID: target.id, settings: nil)
                    progress?(destination.url, step)
                    do {
                        try Task.checkCancellation()
                        try cloneSource(snapshot, to: encoded)
                        step.state = .completed
                        progress?(destination.url, step)
                    } catch {
                        step.state = Task.isCancelled || error is CancellationError ? .cancelled : .failed
                        step.message = error.localizedDescription
                        progress?(destination.url, step)
                        throw error
                    }
                }
                else {
                    companions = try convert(snapshot, to: encoded, settings: destination.settings,
                        resourceDirectory: parent,
                        stageOverrides: destination.stageOverrides,
                        progress: { _, step in progress?(destination.url, step) })
                    if !initial.isPackage, copyfile(snapshot.path, encoded.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) != 0 {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                }
                let hash = try sourceContentHash(encoded)
                try moveExclusively(encoded, work.appendingPathComponent("output-\(outputs.count)"))
                outputs.append(.init(url: destination.url, hash: hash,
                    inode: try FileVersion(work.appendingPathComponent("output-\(outputs.count)"), allowingDirectories: true).inode))
                resources += companions
            } catch {
                try Task.checkCancellation()
                issues.append("\(destination.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard let first = outputs.first else {
            throw ConversionError.message("No output was created. " + issues.joined(separator: " "))
        }
        var keptOriginal: MultipleOutputRecord.Output?
        if let copy = originalCopy {
            if let output = outputs.first(where: { $0.url.standardizedFileURL == copy.standardizedFileURL }) { keptOriginal = output }
            else {
                let staged = work.appendingPathComponent("kept-original")
                try cloneSource(snapshot, to: staged)
                guard try sourceContentHash(staged) == sourceHash else { throw ConversionError.message("The original copy changed during preparation.") }
                keptOriginal = .init(url: copy, hash: sourceHash, inode: try FileVersion(staged, allowingDirectories: true).inode)
            }
        }
        let resourceInodes = try Dictionary(uniqueKeysWithValues: resources.map {
            ($0.directoryName, try FileVersion(work.appendingPathComponent($0.directoryName), allowingDirectories: true).inode)
        })
        try manager.createDirectory(at: historyDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var record = ConversionRecord(id: id, date: Date(), originalURL: original, convertedURL: first.url,
            backupURL: work.appendingPathComponent("original.\(source.extensions[0])"), snapshotURL: snapshot,
            journalURL: historyDirectory.appendingPathComponent("\(id).json"), sourceHash: sourceHash,
            outputHash: first.hash, state: .prepared)
        record.detectedSourceExtension = source.extensions[0]
        record.keepOriginal = keepOriginal ? true : nil
        record.resources = resources.isEmpty ? nil : resources
        record.multipleOutputs = MultipleOutputRecord(requestURL: request, outputs: outputs, sourceInode: initial.inode,
            resourceInodes: resourceInodes, keptOriginal: keptOriginal, issues: issues)
        try record.validateMultiplePaths()
        try BackupRetention.finishWorkDirectory(work)
        try record.saveNew()
        retain = true
        do {
            try coordinateReplacement(request) {
                try Task.checkCancellation()
                guard try SourceVersion(request) == initial, try sourceContentHash(request) == sourceHash else {
                    throw ConversionError.message("The source changed during conversion. Its contents were kept.")
                }
                try moveExclusively(request, record.backupURL)
                try record.checkFile(record.backupURL, hash: sourceHash, inode: initial.inode)
                try record.placeMultipleOutputs(live: true)
                try record.publishMultipleOriginal()
            }
        } catch {
            record.reconcileMultiple(rollbackConversion: true)
            try? record.save()
            throw error
        }
        record.state = .completed
        try record.save()
        return record
    }
}

extension ConversionRecord {
    private var separateOriginal: URL? {
        guard let group = multipleOutputs, let copy = group.keptOriginalURL,
              !group.outputs.contains(where: { $0.url.standardizedFileURL.path == copy.standardizedFileURL.path }) else { return nil }
        return copy
    }

    private func retainedOutput(_ index: Int) -> URL { recoveryDirectory.appendingPathComponent("output-\(index)") }
    private var retainedCopy: URL { recoveryDirectory.appendingPathComponent("kept-original") }

    func validateMultiplePaths() throws {
        guard let group = multipleOutputs, let first = group.outputs.first,
              first.url == convertedURL, first.hash == outputHash, !group.outputs.isEmpty,
              group.outputs.count <= 256 else { throw ConversionError.message("The output group is invalid.") }
        let parent = group.requestURL.deletingLastPathComponent().standardizedFileURL.path
        let root = recoveryDirectory.standardizedFileURL.path
        let live = group.outputs.map { $0.url.standardizedFileURL.path }
        let expectedSnapshot = recoveryDirectory.appendingPathComponent("input").appendingPathComponent(try snapshotFilename())
        guard [originalURL, group.requestURL, backupURL, snapshotURL, journalURL].allSatisfy(\.isFileURL),
              group.outputs.allSatisfy({ $0.url.isFileURL && $0.url.deletingLastPathComponent().standardizedFileURL.path == parent }),
              Set(live).count == live.count, !live.contains(group.requestURL.standardizedFileURL.path),
              recoveryDirectory.deletingLastPathComponent().standardizedFileURL.path == parent,
              recoveryDirectory.lastPathComponent == ".allomer-\(id)", backupURL.lastPathComponent.hasPrefix("original."),
              snapshotURL.standardizedFileURL.path == expectedSnapshot.standardizedFileURL.path,
              journalURL.lastPathComponent == "\(id).json", !live.contains(journalURL.standardizedFileURL.path),
              group.requestURL.standardizedFileURL != journalURL.standardizedFileURL,
              originalURL.standardizedFileURL != journalURL.standardizedFileURL,
              !(live + [originalURL.standardizedFileURL.path, group.requestURL.standardizedFileURL.path, journalURL.standardizedFileURL.path])
                .contains(where: { $0 == root || $0.hasPrefix(root + "/") }) else {
            throw ConversionError.message("The output group's recovery paths are invalid.")
        }
        if let copy = group.keptOriginalURL {
            let path = copy.standardizedFileURL.path
            guard keepOriginal == true, copy.isFileURL, path != root, !path.hasPrefix(root + "/"),
                  path != group.requestURL.standardizedFileURL.path,
                  path != journalURL.standardizedFileURL.path, group.keptOriginal?.hash == sourceHash,
                  copy.standardizedFileURL == originalURL.standardizedFileURL || copy.deletingLastPathComponent().standardizedFileURL.path == parent,
                  !group.outputs.contains(where: { $0.url.standardizedFileURL.path == path && $0.hash != sourceHash }) else {
                throw ConversionError.message("The kept original's path is invalid.")
            }
        }
        let names = (resources ?? []).map(\.directoryName)
        guard Set(names).count == names.count, Set(names) == Set(group.resourceInodes.keys) else {
            throw ConversionError.message("The output group has invalid resource folders.")
        }
        for resource in resources ?? [] { try resource.validateName() }
    }

    fileprivate func checkFile(_ url: URL, hash: String, inode: UInt64? = nil) throws {
        let before = try FileVersion(url, allowingDirectories: true)
        guard inode == nil || before.inode == inode,
              try sourceContentHash(url, checkCancellation: false) == hash,
              try FileVersion(url, allowingDirectories: true) == before else {
            throw ConversionError.message("\(url.lastPathComponent) changed or is missing. Recovery files were kept.")
        }
    }

    private func placeFile(from: URL, to: URL, hash: String, inode: UInt64, retiring: Bool) throws {
        if try !pathIsAbsent(to) {
            try checkFile(to, hash: hash, inode: inode)
            if !retiring, try !pathIsAbsent(from) { throw ConversionError.message("An output name is occupied. Recovery files were kept.") }
            return
        }
        try checkFile(from, hash: hash, inode: inode)
        try moveExclusively(from, to)
        try checkFile(to, hash: hash, inode: inode)
    }

    fileprivate func placeMultipleOutputs(live: Bool) throws {
        guard let group = multipleOutputs else { return }
        let parent = convertedURL.deletingLastPathComponent()
        for resource in resources ?? [] {
            let source = live ? recoveryDirectory : parent
            let destination = live ? parent : recoveryDirectory
            if try !pathIsAbsent(destination.appendingPathComponent(resource.directoryName)) {
                try verifyMultipleResource(resource, in: destination)
                if live, try !pathIsAbsent(source.appendingPathComponent(resource.directoryName)) {
                    throw ConversionError.message("A resource folder name is occupied. Recovery files were kept.")
                }
            } else {
                try verifyMultipleResource(resource, in: source)
                try resource.move(from: source, to: destination, checkCancellation: false)
                try verifyMultipleResource(resource, in: destination)
            }
        }
        for (index, output) in group.outputs.enumerated() {
            try placeFile(from: live ? retainedOutput(index) : output.url,
                          to: live ? output.url : retainedOutput(index), hash: output.hash, inode: output.inode, retiring: !live)
        }
    }

    fileprivate func publishMultipleOriginal() throws {
        guard let copy = separateOriginal, let original = multipleOutputs?.keptOriginal else { return }
        try placeFile(from: retainedCopy, to: copy, hash: sourceHash, inode: original.inode, retiring: false)
    }

    private func retireMultipleOriginal() throws {
        guard let copy = separateOriginal, let original = multipleOutputs?.keptOriginal else { return }
        try placeFile(from: copy, to: retainedCopy, hash: sourceHash, inode: original.inode, retiring: true)
    }

    private func verifyMultipleResource(_ resource: OutputResources, in parent: URL) throws {
        guard try FileVersion(parent.appendingPathComponent(resource.directoryName), allowingDirectories: true).inode
                == multipleOutputs?.resourceInodes[resource.directoryName] else {
            throw ConversionError.message("A converted resource folder was replaced. Recovery files were kept.")
        }
        try resource.verify(in: parent, checkCancellation: false)
    }

    private func verifyMultipleOutputs(live: Bool) throws {
        guard let group = multipleOutputs else { return }
        for (index, output) in group.outputs.enumerated() {
            try checkFile(live ? output.url : retainedOutput(index), hash: output.hash, inode: output.inode)
        }
        for resource in resources ?? [] { try verifyMultipleResource(resource, in: live ? convertedURL.deletingLastPathComponent() : recoveryDirectory) }
    }

    mutating func reconcileMultiple(rollbackConversion: Bool = false) {
        guard let group = multipleOutputs else { return }
        do {
            try validateMultiplePaths()
            if state == .prepared {
                let published = (try? verifyMultipleOutputs(live: true)) != nil
                    && (try? pathIsAbsent(group.requestURL)) == true
                    && (try? checkFile(backupURL, hash: sourceHash, inode: group.sourceInode)) != nil
                if published && !rollbackConversion {
                    try publishMultipleOriginal()
                    state = .completed
                } else {
                    try placeMultipleOutputs(live: false)
                    try retireMultipleOriginal()
                    if try pathIsAbsent(backupURL) { try checkFile(group.requestURL, hash: sourceHash, inode: group.sourceInode) }
                    else {
                        try checkFile(backupURL, hash: sourceHash, inode: group.sourceInode)
                        try moveExclusively(backupURL, group.requestURL)
                        try checkFile(group.requestURL, hash: sourceHash, inode: group.sourceInode)
                    }
                    state = .aborted
                }
            } else if state == .undoPrepared {
                if try pathIsAbsent(backupURL) {
                    try checkFile(originalURL, hash: sourceHash, inode: group.sourceInode)
                    try verifyMultipleOutputs(live: false)
                    if separateOriginal != nil { try checkFile(retainedCopy, hash: sourceHash, inode: group.keptOriginal?.inode) }
                    state = .undone
                } else {
                    try checkFile(backupURL, hash: sourceHash, inode: group.sourceInode)
                    try placeMultipleOutputs(live: true)
                    try publishMultipleOriginal()
                    state = .completed
                }
            }
        } catch { state = .needsReview }
    }

    func undoMultiple() throws -> ConversionRecord {
        guard canUndo, let group = multipleOutputs else { throw ConversionError.message("This output group cannot be undone.") }
        try validateMultiplePaths()
        try checkFile(backupURL, hash: sourceHash, inode: group.sourceInode)
        try verifyMultipleOutputs(live: true)
        if let copy = separateOriginal { try checkFile(copy, hash: sourceHash, inode: group.keptOriginal?.inode) }
        let originalIsOutput = group.outputs.contains { $0.url.standardizedFileURL.path == originalURL.standardizedFileURL.path }
        guard try originalIsOutput || separateOriginal?.standardizedFileURL.path == originalURL.standardizedFileURL.path || pathIsAbsent(originalURL) else {
            throw ConversionError.message("The original filename is already in use.")
        }
        var record = self
        record.state = .undoPrepared
        try record.save()
        do {
            try coordinateReplacement(originalURL) {
                try record.placeMultipleOutputs(live: false)
                try record.retireMultipleOriginal()
                try record.checkFile(backupURL, hash: sourceHash, inode: group.sourceInode)
                try moveExclusively(backupURL, originalURL)
                try record.checkFile(originalURL, hash: sourceHash, inode: group.sourceInode)
            }
        } catch {
            record.reconcileMultiple()
            try? record.save()
            throw error
        }
        record.state = .undone
        try record.save()
        return record
    }

    func verifyMultipleRetained() throws {
        try validateMultiplePaths()
        try checkFile(snapshotURL, hash: sourceHash)
        if state == .completed { try checkFile(backupURL, hash: sourceHash, inode: multipleOutputs?.sourceInode) }
        else if state == .undone || state == .aborted {
            guard try pathIsAbsent(backupURL) else { throw ConversionError.message("The retained source needs review before cleanup.") }
            try verifyMultipleOutputs(live: false)
            if try !pathIsAbsent(retainedCopy) { try checkFile(retainedCopy, hash: sourceHash) }
        }
    }
}
