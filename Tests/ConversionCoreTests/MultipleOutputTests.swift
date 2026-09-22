import CoreGraphics
import ImageIO
import XCTest
@testable import ConversionCore

final class MultipleOutputTests: XCTestCase {
    func testCompanionResourcesMoveWithTheGroup() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard manager.isExecutableFile(atPath: tools.appendingPathComponent("modeltool").path) else {
            throw XCTSkip("Build the model helper before checking companion resources.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let original = work.appendingPathComponent("shape.obj")
        let request = work.appendingPathComponent("shape.glb,ply")
        let bytes = Data("mtllib colors.mtl\nv 0 0 0\nv 2 0 0\nv 0 3 0\nvt 0 0\nvt 1 0\nvt 0 1\nusemtl colors\nf 1/1 2/2 3/3\n".utf8)
        try bytes.write(to: request)
        try Data("newmtl colors\nKd 1 1 1\nmap_Kd colors.png\n".utf8).write(to: work.appendingPathComponent("colors.mtl"))
        let texture = work.appendingPathComponent("colors.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(texture as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let textureBytes = try Data(contentsOf: texture)
        XCTAssertEqual(try engine.detectedFormat(at: request, sourceExtensionHint: "obj")?.id, "obj")
        var options = ConversionSettings()
        options.modelOptions.embedTextures = false
        options.modelOptions.binaryPLY = false
        let record = try engine.convertToMultipleFormats(from: original, at: request,
            destinations: ["glb", "ply"].map { .init(url: work.appendingPathComponent("shape." + $0), settings: options) },
            sourceID: "obj", historyDirectory: work.appendingPathComponent("history"))
        XCTAssertEqual(record.outputURLs.count, 2, record.multipleOutputs?.issues.description ?? "")
        let resources = record.resources ?? []
        XCTAssertEqual(resources.count, 2)
        for resource in resources { try resource.verify(in: work) }
        let resource = try XCTUnwrap(resources.first)
        let member = work.appendingPathComponent(resource.directoryName).appendingPathComponent(try XCTUnwrap(resource.fileHashes.keys.first))
        let saved = try Data(contentsOf: member)
        try Data("edited resource".utf8).write(to: member)
        XCTAssertThrowsError(try ConversionEngine.undo(record))
        try saved.write(to: member)
        let undone = try ConversionEngine.undo(record)
        for resource in resources {
            try resource.verify(in: undone.recoveryDirectory)
            XCTAssertTrue(try pathIsAbsent(work.appendingPathComponent(resource.directoryName)))
        }
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Data(contentsOf: texture), textureBytes)
    }

    @MainActor
    func testLateOriginalCollisionAndCancellationKeepSource() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let engine = try ConversionEngine()
        let bytes = Data(("[" + Array(repeating: #"{"name":"original","count":3}"#, count: 20_000).joined(separator: ",") + "]").utf8)
        for cancel in [false, true] {
            let folder = work.appendingPathComponent("\(cancel)")
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            let original = folder.appendingPathComponent("file.json")
            let request = folder.appendingPathComponent("file.yaml,json")
            try bytes.write(to: request)
            let inode = try FileVersion(request).inode
            let job = Task.detached {
                try engine.convertToMultipleFormats(from: original, at: request,
                    destinations: ["yaml", "json"].map { .init(url: folder.appendingPathComponent("output." + $0)) },
                    sourceID: "json", historyDirectory: folder.appendingPathComponent("history"), keepOriginal: true)
            }
            let deadline = Date().addingTimeInterval(5)
            while try !manager.contentsOfDirectory(atPath: folder.path).contains(where: { $0.hasPrefix(".allomer-") }), Date() < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            if cancel { job.cancel() }
            else {
                do { try bytes.write(to: original, options: .withoutOverwriting) }
                catch { _ = await job.result; throw error }
            }
            let result = await job.result
            XCTAssertThrowsError(try result.get())
            XCTAssertEqual(try Data(contentsOf: request), bytes)
            XCTAssertEqual(try FileVersion(request).inode, inode)
            XCTAssertTrue(try pathIsAbsent(folder.appendingPathComponent("output.yaml")))
            XCTAssertTrue(try pathIsAbsent(folder.appendingPathComponent("output.json")))
            if !cancel {
                XCTAssertEqual(try Data(contentsOf: original), bytes)
                XCTAssertEqual(try ConversionRecord.loadHistory(from: folder.appendingPathComponent("history")).first?.state, .aborted)
            }
        }
    }

    @MainActor
    func testAutomaticGroupsRespectDecisionsSettingsAndDisable() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watched = work.appendingPathComponent("watched")
        try manager.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let bytes = Data(#"{"name":"Café","count":3}"#.utf8)
        let engine = try ConversionEngine()
        var results: [Result<ConversionRecord, Error>] = []
        var approvals: [ConversionApproval] = []
        let service = AutomaticConverter(engine: engine, historyDirectory: work.appendingPathComponent("history")) { results.append($0) }
        service.approvalsChanged = { approvals = $0 }
        try service.start(folders: [watched])
        defer { service.stop() }
        func rename(_ old: URL, _ name: String) throws -> URL {
            let output = watched.appendingPathComponent(name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/mv")
            process.arguments = [old.path, output.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return output
        }
        func request(_ name: String, oldExtension: String = "json", targets: String = "yaml,toml") throws -> (URL, URL) {
            let original = watched.appendingPathComponent(name + "." + oldExtension)
            try bytes.write(to: original)
            return (original, try rename(original, name + "." + targets))
        }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(condition(), "The group watcher did not reach the expected state")
        }
        XCTAssertFalse(service.convertMultipleFormats)
        let disabled = try request("disabled").1
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(try Data(contentsOf: disabled), bytes)
        service.convertMultipleFormats = true
        service.rules = [ConversionRule(sourceID: "json", targetID: "toml", action: .askFirst),
                         ConversionRule(sourceID: "json", targetID: "plist", action: .askFirst)]
        let (original, renamed) = try request("mixed", oldExtension: "png", targets: "yaml,toml,plist,unknown")
        try await waitFor { approvals.count == 2 }
        XCTAssertTrue(approvals.allSatisfy { $0.detectedSourceID == "json" && $0.inputURL == renamed && $0.originalURL == original })
        XCTAssertTrue(try pathIsAbsent(watched.appendingPathComponent("mixed.yaml")))
        service.convertNewFiles = true
        service.convertNewFiles = false
        XCTAssertEqual(approvals.count, 2, "Disabling arrivals must preserve a rename group's decisions")
        var options = ConversionSettings()
        options.configOptions.binaryPlist = true
        let plist = try XCTUnwrap(approvals.first { $0.renamedURL.pathExtension == "plist" })
        XCTAssertTrue(service.decide(plist.id, convert: true, settings: options, keepOriginal: true))
        XCTAssertEqual(approvals.count, 1)
        XCTAssertTrue(results.isEmpty)
        service.maintenanceInProgress = true
        XCTAssertTrue(service.decide(try XCTUnwrap(approvals.first).id, convert: false))
        XCTAssertTrue(approvals.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(try Data(contentsOf: renamed), bytes)
        service.maintenanceInProgress = false
        try await waitFor { results.count == 1 }
        let record = try results[0].get()
        XCTAssertEqual(record.outputURLs.map(\.pathExtension), ["yaml", "plist"])
        XCTAssertEqual(record.multipleOutputs?.issues.count, 1)
        XCTAssertEqual(try Data(contentsOf: record.visibleOriginalURL), bytes)
        XCTAssertEqual(record.visibleOriginalURL.lastPathComponent, "mixed.json")
        XCTAssertTrue(try Data(contentsOf: plist.renamedURL).starts(with: Data("bplist00".utf8)))
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: original), bytes)

        service.rules = []
        service.action = .askFirst
        let (_, pending) = try request("again")
        try await waitFor { approvals.count == 2 }
        let previous = approvals.map(\.id)
        let next = try rename(pending, "again.plist,yaml.json")
        try await waitFor { approvals.count == 2 && approvals.allSatisfy { $0.inputURL == next } }
        for id in previous { XCTAssertFalse(service.decide(id, convert: true)) }
        service.convertMultipleFormats = false
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertEqual(try Data(contentsOf: next), bytes)

        // The switch only clears multiple-format requests.
        let (_, single) = try request("single", targets: "yaml")
        try await waitFor { approvals.count == 1 }
        service.convertMultipleFormats = true
        service.convertMultipleFormats = false
        let singleApproval = try XCTUnwrap(approvals.first)
        XCTAssertEqual(singleApproval.renamedURL, single)
        XCTAssertTrue(service.decide(singleApproval.id, convert: true))
        try await waitFor { results.count == 2 }
        XCTAssertNil(try results[1].get().multipleOutputs)

        service.convertMultipleFormats = true
        let (_, changed) = try request("changed")
        try await waitFor { approvals.count == 2 }
        let edit = Data(#"{"changed":true}"#.utf8)
        try edit.write(to: changed)
        for approval in approvals { service.decide(approval.id, convert: true) }
        try await waitFor { results.count == 3 }
        XCTAssertThrowsError(try results[2].get())
        XCTAssertEqual(try Data(contentsOf: changed), edit)
        XCTAssertTrue(try pathIsAbsent(watched.appendingPathComponent("changed.yaml")))

        service.convertNewFiles = true
        service.action = .immediately
        let arrival = watched.appendingPathComponent("arrival.json,yaml")
        let input = work.appendingPathComponent("incoming")
        try bytes.write(to: input)
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/bin/cp")
        copy.arguments = [input.path, arrival.path]
        try copy.run()
        copy.waitUntilExit()
        XCTAssertEqual(copy.terminationStatus, 0)
        try await waitFor { results.count == 4 }
        let arrived = try results[3].get()
        XCTAssertEqual(arrived.originalURL, arrival)
        XCTAssertEqual(arrived.outputURLs.map(\.pathExtension), ["json", "yaml"])
        _ = try ConversionEngine.undo(arrived)
        XCTAssertEqual(try Data(contentsOf: arrival), bytes)
        await service.stopAndWait()
    }

    func testGroupUndoRecoveryCollisionsAndRetention() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let engine = try ConversionEngine()
        let bytes = Data(#"{"name":"Café 東京","count":3}"#.utf8)
        let edit = Data("A later edit".utf8)
        var age = BackupRetentionOptions()
        age.limitAge = true
        age.maximumAgeDays = 1
        for keep in [false, true] {
            for includeSource in [false, true] {
                let folder = work.appendingPathComponent("\(keep)-\(includeSource)")
                try manager.createDirectory(at: folder, withIntermediateDirectories: false)
                let original = folder.appendingPathComponent("before.json")
                let request = folder.appendingPathComponent("after.yaml,toml,json")
                let history = folder.appendingPathComponent("history")
                try bytes.write(to: request)
                try manager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: request.path)
                let sourceInode = try FileVersion(request).inode
                var destinations = ["yaml", "toml"].map { ConversionDestination(url: folder.appendingPathComponent("after." + $0)) }
                if includeSource { destinations.append(.init(url: original)) }
                let record = try engine.convertToMultipleFormats(from: original, at: request,
                    destinations: destinations, sourceID: "json", historyDirectory: history, keepOriginal: keep)
                XCTAssertEqual(record.state, .completed)
                XCTAssertEqual(record.outputURLs, destinations.map(\.url))
                XCTAssertTrue(try XCTUnwrap(record.multipleOutputs).issues.isEmpty)
                XCTAssertTrue(try pathIsAbsent(request))
                XCTAssertEqual(try Data(contentsOf: record.backupURL), bytes)
                XCTAssertEqual(try FileVersion(record.backupURL).inode, sourceInode)
                for output in record.outputURLs {
                    XCTAssertEqual(try manager.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int, 0o640)
                }
                if keep || includeSource { XCTAssertEqual(try Data(contentsOf: original), bytes) }
                var interrupted = record
                interrupted.state = .prepared
                try interrupted.save()
                XCTAssertEqual(try ConversionRecord.loadHistory(from: history).first?.state, .completed)

                let first = record.outputURLs[0]
                let encoded = try Data(contentsOf: first)
                try edit.write(to: first)
                XCTAssertThrowsError(try ConversionEngine.undo(record))
                XCTAssertEqual(try Data(contentsOf: first), edit)
                try encoded.write(to: first)
                let retained = record.recoveryDirectory.appendingPathComponent("output-0")
                try moveExclusively(first, retained)
                try encoded.write(to: first, options: .withoutOverwriting)
                XCTAssertThrowsError(try ConversionEngine.undo(record), "A same-content replacement is not an owned output")
                try manager.removeItem(at: first)
                interrupted.state = .undoPrepared
                try interrupted.save()
                XCTAssertEqual(try ConversionRecord.loadHistory(from: history).first?.state, .completed)
                XCTAssertEqual(try Data(contentsOf: first), encoded)

                let undone = try ConversionEngine.undo(record)
                XCTAssertEqual(undone.state, .undone)
                XCTAssertEqual(try Data(contentsOf: original), bytes)
                XCTAssertEqual(try FileVersion(original).inode, sourceInode)
                XCTAssertTrue(try pathIsAbsent(request))
                for output in record.outputURLs where output != original { XCTAssertTrue(try pathIsAbsent(output)) }
                try interrupted.save()
                XCTAssertEqual(try ConversionRecord.loadHistory(from: history).first?.state, .undone)
                try edit.write(to: retained)
                let refused = try BackupRetention.clean([undone], options: age, now: undone.date.addingTimeInterval(86_400))
                XCTAssertEqual(refused.removedCount, 0)
                XCTAssertEqual(refused.issues.count, 1)
                try encoded.write(to: retained)
                let clean = try BackupRetention.clean([undone], options: age, now: undone.date.addingTimeInterval(86_400))
                XCTAssertEqual(clean.removedCount, 1, clean.issues.description)
                XCTAssertEqual(try Data(contentsOf: original), bytes)
            }
        }

        // Each unfinished publication rolls back only files whose staged identities match.
        for published in 0...2 {
            let folder = work.appendingPathComponent("interrupted-\(published)")
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            let original = folder.appendingPathComponent("file.json")
            let request = folder.appendingPathComponent("file.yaml,toml")
            let history = folder.appendingPathComponent("history")
            try bytes.write(to: request)
            let targets = ["yaml", "toml"].map { ConversionDestination(url: folder.appendingPathComponent("file." + $0)) }
            var record = try engine.convertToMultipleFormats(from: original, at: request,
                destinations: targets, sourceID: "json", historyDirectory: history, keepOriginal: true)
            for index in published..<targets.count {
                try moveExclusively(targets[index].url, record.recoveryDirectory.appendingPathComponent("output-\(index)"))
            }
            try moveExclusively(original, record.recoveryDirectory.appendingPathComponent("kept-original"))
            try bytes.write(to: original, options: .withoutOverwriting)
            let foreignInode = try FileVersion(original).inode
            record.state = .prepared
            if published == 0 { try moveExclusively(record.backupURL, request) }
            try record.save()
            // A fully published group waits for review when the kept source name is occupied.
            // Partial groups return the original source to the comma-separated request name.
            let recovered = try XCTUnwrap(ConversionRecord.loadHistory(from: history).first)
            XCTAssertEqual(recovered.state, published == 2 ? .needsReview : .aborted)
            XCTAssertEqual(try FileVersion(original).inode, foreignInode)
            XCTAssertEqual(try Data(contentsOf: original), bytes)
            if published < 2 {
                XCTAssertEqual(try Data(contentsOf: request), bytes)
                let clean = try BackupRetention.clean([recovered], options: age, now: record.date.addingTimeInterval(86_400))
                XCTAssertEqual(clean.removedCount, 1, clean.issues.description)
                XCTAssertEqual(try Data(contentsOf: request), bytes)
            }
        }
    }

    func testFailedTargetsAndArrivalNamesPreserveSources() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let engine = try ConversionEngine()
        let request = work.appendingPathComponent("arrival.json,toml,png,yaml")
        let bytes = Data(#"{"value":3}"#.utf8)
        try bytes.write(to: request)
        let parsed = try XCTUnwrap(MultipleOutputName(request, catalog: engine.catalog))
        let occupied = work.appendingPathComponent("arrival.yaml")
        try manager.createSymbolicLink(at: occupied, withDestinationURL: work.appendingPathComponent("missing"))
        let record = try engine.convertToMultipleFormats(from: request, at: request,
            destinations: parsed.targets.map { .init(url: $0.url) }, sourceID: "json",
            historyDirectory: work.appendingPathComponent("history"), keepOriginal: true)
        XCTAssertEqual(record.outputURLs.map(\.pathExtension), ["json", "toml"])
        XCTAssertEqual(record.multipleOutputs?.issues.count, 2)
        XCTAssertEqual(try Data(contentsOf: record.visibleOriginalURL), bytes)
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: request), bytes)
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: occupied.path), work.appendingPathComponent("missing").path)
        XCTAssertThrowsError(try engine.convertToMultipleFormats(from: request, at: request,
            destinations: [.init(url: work.appendingPathComponent("arrival.png"))], sourceID: "json",
            historyDirectory: work.appendingPathComponent("failed-history")))
        XCTAssertEqual(try Data(contentsOf: request), bytes)
        XCTAssertTrue(try pathIsAbsent(work.appendingPathComponent("failed-history")))
    }

    func testCommaSeparatedNamesAndFinderSuffix() throws {
        let catalog = try FormatCatalog()
        func parsed(_ name: String, old: String? = nil) throws -> MultipleOutputName {
            try XCTUnwrap(MultipleOutputName(URL(fileURLWithPath: "/Folder/" + name), catalog: catalog, originalExtension: old))
        }
        let ordinary = try parsed("Café ' photo.jpeg, webp,PNG,jpg")
        XCTAssertEqual(ordinary.baseURL.lastPathComponent, "Café ' photo")
        XCTAssertEqual(ordinary.targets.map(\.format.id), ["jpeg", "webp", "png"])
        XCTAssertEqual(ordinary.targets.map(\.url.lastPathComponent), ["Café ' photo.jpeg", "Café ' photo.webp", "Café ' photo.png"])
        XCTAssertTrue(ordinary.unknownExtensions.isEmpty)
        let commas = try parsed("Family, notes.v1,2.png,webp")
        XCTAssertEqual(commas.baseURL.lastPathComponent, "Family, notes.v1,2")
        XCTAssertEqual(commas.targets.map(\.format.id), ["png", "webp"])
        let archives = try parsed("backup.tar.gz,zip")
        XCTAssertEqual(archives.baseURL.lastPathComponent, "backup")
        XCTAssertEqual(archives.targets.map(\.format.id), ["tgz", "zip"])
        XCTAssertEqual(archives.targets.first?.url.lastPathComponent, "backup.tar.gz")
        let finder = try parsed("changed.yaml,toml.json", old: "json")
        XCTAssertEqual(finder.targets.map(\.format.id), ["yaml", "toml"])
        XCTAssertEqual(finder.targets.last?.url.lastPathComponent, "changed.toml")
        let compound = try parsed("changed.yaml,tar.gz", old: "gz")
        XCTAssertEqual(compound.targets.map(\.format.id), ["yaml", "tgz"])
        let unknown = try parsed("file.unknown,png")
        XCTAssertEqual(unknown.unknownExtensions, ["unknown"])
        XCTAssertEqual(unknown.targets.map(\.format.id), ["png"])
        for name in ["ordinary.png", "file.png,,webp", "file.png,", ".png,webp"] {
            XCTAssertNil(MultipleOutputName(URL(fileURLWithPath: "/Folder/" + name), catalog: catalog), name)
        }
    }
}
