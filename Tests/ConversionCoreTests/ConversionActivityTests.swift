import AppKit
import XCTest
@testable import ConversionCore

final class ConversionActivityTests: XCTestCase {
    @MainActor
    func testStageOverridesChangeSelectedStagesAndRejectStaleRoutes() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        let required = ["carta", "tabular", "cwebp", "webpguard", "webpanim", "webpanimguard", "webconvert", "webguard"]
        guard required.allSatisfy({ manager.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the document, spreadsheet, WebP, and native helpers before checking staged routes.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let source = work.appendingPathComponent("source.yaml")
        let bytes = Data("- code: '00123'\n  enabled: 'true'\n  amount: '1e2'\n".utf8)
        try bytes.write(to: source)
        let target = try XCTUnwrap(engine.catalog.format(forExtension: "docx"))
        for suffix in ["jpg", "png", "heic", "tiff", "bmp"] {
            let image = try XCTUnwrap(engine.catalog.format(forExtension: suffix))
            let webp = try XCTUnwrap(engine.catalog.format(forExtension: "webp"))
            XCTAssertEqual(engine.conversionRoute(from: image, to: webp)?.map(\.id), ["webp"], suffix)
        }
        let ico = try XCTUnwrap(engine.catalog.format(forExtension: "ico"))
        let tiff = try XCTUnwrap(engine.catalog.format(forExtension: "tiff"))
        XCTAssertEqual(engine.conversionRoute(from: ico, to: tiff)?.map(\.id), ["png", "tiff"])
        let route = try XCTUnwrap(engine.conversionRoute(from: source, to: target))
        XCTAssertEqual(route.map(\.id), ["json", "tsv", "docx"])
        XCTAssertEqual(engine.conversionRoute(from: engine.catalog.format(for: source)!, to: target), route)
        let standard = work.appendingPathComponent("default.docx")
        try engine.convert(source, to: standard)
        func text(_ file: URL) throws -> String {
            try NSAttributedString(url: file, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
        }
        XCTAssertTrue(try text(standard).contains("00123"))
        XCTAssertTrue(try text(standard).contains("1e2"))
        var selected = ConversionSettings()
        selected.configOptions.inferStringTypes = true
        selected.configOptions.prettyPrint = false
        selected.mediaOptions.cpuProfile = .low
        let override = ConversionStageOverride(sourceID: "yaml", targetID: "json", settings: selected)
        var media = MediaOptions()
        media.cpuProfile = .high
        let renamed = work.appendingPathComponent("custom.docx")
        let original = work.appendingPathComponent("custom.yaml")
        try bytes.write(to: renamed)
        let (stream, continuation) = AsyncStream<ConversionActivity.Step>.makeStream()
        let record = try engine.convertRenamedFile(from: original, to: renamed, historyDirectory: work.appendingPathComponent("history"),
            settings: .init(mediaOptions: media), stageOverrides: [override], progress: { _, step in continuation.yield(step) })
        continuation.finish()
        var completed: [ConversionActivity.Step] = []
        for await step in stream where step.state == .completed { completed.append(step) }
        XCTAssertEqual(completed.count, 3)
        XCTAssertEqual(completed.map { $0.settings?.configOptions.inferStringTypes }, [true, false, false])
        XCTAssertEqual(completed.map { $0.settings?.configOptions.prettyPrint }, [false, true, true])
        XCTAssertTrue(completed.allSatisfy { $0.settings?.mediaOptions.cpuProfile == .high })
        XCTAssertTrue(try text(renamed).contains("00123"))
        XCTAssertFalse(try text(renamed).contains("1e2"))
        XCTAssertTrue(try text(renamed).contains("100.0"))
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: original), bytes)

        for overrides in [[override, override], [.init(sourceID: "yaml", targetID: "png", settings: selected)]] {
            let rejected = work.appendingPathComponent("rejected.docx")
            XCTAssertThrowsError(try engine.convert(source, to: rejected, stageOverrides: overrides))
            XCTAssertFalse(manager.fileExists(atPath: rejected.path))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }

        let svg = work.appendingPathComponent("image.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><rect width="2" height="2" fill="red"/></svg>"#.utf8).write(to: svg)
        selected.imageOptions.pngCompressionLevel = 0
        var invalid = ImageOptions()
        invalid.pngCompressionLevel = 42
        let png = work.appendingPathComponent("image.png")
        try engine.convert(svg, to: png, settings: .init(imageOptions: invalid),
            stageOverrides: [.init(sourceID: "svg", targetID: "png", settings: selected)])
        XCTAssertTrue(manager.fileExists(atPath: png.path), "The stage's valid PNG option replaces the output default")
        selected.imageOptions.pngCompressionLevel = 42
        XCTAssertThrowsError(try engine.convert(svg, to: work.appendingPathComponent("invalid.png"),
            stageOverrides: [.init(sourceID: "svg", targetID: "png", settings: selected)]))
    }

    @MainActor
    func testStepSettingsResultsAndCancellationAcrossIntermediateFormats() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["carta", "tabular"].allSatisfy({ manager.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the document and spreadsheet helpers before checking staged activity.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let original = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/sheet-values.xls"))
        var options = SpreadsheetOptions()
        options.sheetIndex = 1
        let selected = options
        for mode in ["complete", "fail", "cancel"] {
            let source = work.appendingPathComponent(mode + ".xls")
            let output = work.appendingPathComponent(mode + ".docx")
            let bytes = mode == "fail" ? Data("Invalid workbook".utf8) : original
            try bytes.write(to: source)
            XCTAssertEqual(engine.conversionRoute(from: source, to: engine.catalog.format(forExtension: "docx")!)?.map(\.id), ["tsv", "docx"])
            let (stream, continuation) = AsyncStream<(URL, ConversionActivity.Step)>.makeStream()
            let task = Task.detached {
                defer { continuation.finish() }
                return try engine.convert(source, to: output, settings: .init(spreadsheetOptions: selected), progress: { url, step in
                    continuation.yield((url, step))
                    if mode == "cancel", step.id == 1, step.state == .running {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            }
            var steps: [ConversionActivity.Step] = []
            for await (url, step) in stream {
                XCTAssertEqual(url, output)
                steps.append(step)
            }
            let result = await task.result
            XCTAssertEqual(steps.first?.settings?.spreadsheetOptions.sheetIndex, 1)
            XCTAssertEqual(steps.first?.sourceID, "xls")
            XCTAssertEqual(steps.first?.targetID, "tsv")
            XCTAssertTrue(steps.allSatisfy { $0.count == 2 })
            if mode == "complete" {
                _ = try result.get()
                XCTAssertEqual(steps.map(\.state), [.running, .completed, .running, .completed])
                XCTAssertEqual(steps.last?.sourceID, "tsv")
                XCTAssertEqual(steps.last?.targetID, "docx")
                XCTAssertEqual(steps.last?.settings?.spreadsheetOptions.sheetIndex, 0)
                let text = try NSAttributedString(url: output,
                    options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
                XCTAssertTrue(text.contains("offset"), text)
            } else {
                XCTAssertThrowsError(try result.get())
                XCTAssertEqual(steps.last?.state, mode == "cancel" ? .cancelled : .failed)
                XCTAssertEqual(steps.map(\.id), mode == "cancel" ? [0, 0, 1, 1] : [0, 0])
                XCTAssertFalse(steps.last?.message?.isEmpty ?? true)
                XCTAssertFalse(manager.fileExists(atPath: output.path))
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertFalse(try manager.contentsOfDirectory(atPath: work.path).contains { $0.hasPrefix(".allomer-") })
        }
    }

    @MainActor
    func testGroupStepsUseFinalNamesAndSourceCopiesHaveNoEncoderSettings() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let engine = try ConversionEngine()
        let request = work.appendingPathComponent("file.json,yaml,toml")
        let bytes = Data(#"{"value":3}"#.utf8)
        try bytes.write(to: request)
        var compact = ConversionSettings()
        compact.configOptions.prettyPrint = false
        let override = ConversionStageOverride(sourceID: "json", targetID: "yaml", settings: compact)
        let destinations = ["json", "yaml", "toml"].map {
            ConversionDestination(url: work.appendingPathComponent("file." + $0), stageOverrides: $0 == "yaml" ? [override] : [])
        }
        let (stream, continuation) = AsyncStream<(URL, ConversionActivity.Step)>.makeStream()
        let task = Task.detached {
            defer { continuation.finish() }
            return try engine.convertToMultipleFormats(from: request, at: request, destinations: destinations,
                sourceID: "json", historyDirectory: work.appendingPathComponent("history"), progress: { continuation.yield(($0, $1)) })
        }
        var steps: [(URL, ConversionActivity.Step)] = []
        for await step in stream { steps.append(step) }
        let record = try await task.value
        XCTAssertEqual(steps.map { $0.0 }, destinations.flatMap { [$0.url, $0.url] })
        XCTAssertEqual(steps.map { $0.1.state }, [.running, .completed, .running, .completed, .running, .completed])
        XCTAssertTrue(steps.prefix(2).allSatisfy { $0.1.settings == nil && $0.1.sourceID == $0.1.targetID })
        XCTAssertTrue(steps.dropFirst(2).allSatisfy { $0.1.settings != nil })
        XCTAssertEqual(steps[2].1.settings?.configOptions.prettyPrint, false)
        XCTAssertEqual(steps[4].1.settings?.configOptions.prettyPrint, true)
        XCTAssertTrue(try String(contentsOf: destinations[1].url, encoding: .utf8).contains("{"))
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: request), bytes)
    }

    func testJournalIDsCannotReplaceAnotherConversion() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let bytes = Data(#"{"value":3}"#.utf8)
        let engine = try ConversionEngine()
        let history = work.appendingPathComponent("history")
        let first = work.appendingPathComponent("first.yaml")
        try bytes.write(to: first)
        let record = try engine.convertRenamedFile(from: work.appendingPathComponent("first.json"), to: first, historyDirectory: history)
        let saved = try Data(contentsOf: record.journalURL)
        for multiple in [false, true] {
            let folder = work.appendingPathComponent("\(multiple)")
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            let original = folder.appendingPathComponent("other.json")
            let request = folder.appendingPathComponent(multiple ? "other.yaml,toml" : "other.yaml")
            try bytes.write(to: request)
            if multiple {
                XCTAssertThrowsError(try engine.convertToMultipleFormats(from: original, at: request,
                    destinations: ["yaml", "toml"].map { .init(url: folder.appendingPathComponent("other." + $0)) },
                    sourceID: "json", historyDirectory: history, id: record.id))
            } else {
                XCTAssertThrowsError(try engine.convertRenamedFile(from: original, to: request, historyDirectory: history, id: record.id))
            }
            XCTAssertEqual(try Data(contentsOf: request), bytes)
            XCTAssertEqual(try Data(contentsOf: record.journalURL), saved)
        }
        var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        invalid["id"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: invalid).write(to: record.journalURL)
        XCTAssertThrowsError(try ConversionRecord.loadHistory(from: history))
        try saved.write(to: record.journalURL)
        let duplicate = history.appendingPathComponent("legacy-copy.json")
        invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        invalid["journalURL"] = duplicate.absoluteString
        try JSONSerialization.data(withJSONObject: invalid).write(to: duplicate)
        XCTAssertThrowsError(try ConversionRecord.loadHistory(from: history))
        try manager.removeItem(at: duplicate)
        _ = try ConversionEngine.undo(record)
    }

    @MainActor
    func testJobStatesCancellationAndJournalIdentity() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watched = work.appendingPathComponent("watched")
        try manager.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let bytes = Data(#"{"name":"Café","count":3}"#.utf8)
        var jobs: [UUID: ConversionActivity] = [:]
        var transitions: [UUID: [ConversionActivity.State]] = [:]
        var results: [Result<ConversionRecord, Error>] = []
        var approvals: [ConversionApproval] = []
        var cancelOnStart = false
        var callbackCancellations: [UUID: Bool] = [:]
        let service = AutomaticConverter(engine: try ConversionEngine(), historyDirectory: work.appendingPathComponent("history")) { results.append($0) }
        service.jobChanged = { job in
            jobs[job.id] = job
            if transitions[job.id]?.last != job.state { transitions[job.id, default: []].append(job.state) }
            if cancelOnStart, job.state == .running, !job.configurations.isEmpty {
                callbackCancellations[job.id] = service.cancel(job.id)
            }
        }
        service.approvalsChanged = { approvals = $0 }
        try service.start(folders: [watched])
        defer { service.stop() }
        func rename(_ name: String, target: String, data: Data? = nil) throws -> URL {
            let original = watched.appendingPathComponent(name + ".json")
            let destination = watched.appendingPathComponent(name + "." + target)
            try (data ?? bytes).write(to: original)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/mv")
            process.arguments = [original.path, destination.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return destination
        }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(condition(), "The conversion job did not reach its expected state")
        }
        for state: ConversionActivity.State in [.queued, .waiting, .running] {
            service.maintenanceInProgress = state == .queued
            service.action = state == .waiting ? .askFirst : .immediately
            let contents = state == .running
                ? Data(("[" + Array(repeating: #"{"value":3}"#, count: 100_000).joined(separator: ",") + "]").utf8) : bytes
            let file = try rename(state.rawValue, target: "yaml", data: contents)
            try await waitFor { jobs.values.contains { $0.requestedURL == file && $0.state == state } }
            let job = try XCTUnwrap(jobs.values.first { $0.requestedURL == file })
            XCTAssertTrue(service.cancel(job.id))
            try await waitFor { jobs[job.id]?.state == .cancelled }
            XCTAssertEqual(try Data(contentsOf: file), contents)
            XCTAssertFalse(service.cancel(job.id))
            XCTAssertTrue(approvals.isEmpty)
            service.maintenanceInProgress = false
        }
        XCTAssertTrue(results.isEmpty, "Cancelled jobs remain quiet in the error-notification callback")

        service.action = .askFirst
        let file = try rename("success", target: "plist")
        try await waitFor { approvals.count == 1 }
        let approval = try XCTUnwrap(approvals.first)
        let settings = ConversionSettings()
        var stage = settings
        stage.configOptions.binaryPlist = true
        XCTAssertTrue(service.decide(approval.id, convert: true, settings: settings, keepOriginal: true,
            stageOverrides: [.init(sourceID: "json", targetID: "plist", settings: stage)]))
        try await waitFor { results.count == 1 }
        let record = try results[0].get()
        XCTAssertEqual(record.id, approval.id)
        let job = try XCTUnwrap(jobs[record.id])
        XCTAssertEqual(job.recordID, record.id)
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(job.outputURLs, [file])
        XCTAssertEqual(job.configurations.first?.settings.configOptions.binaryPlist, false)
        XCTAssertTrue(try Data(contentsOf: file).starts(with: Data("bplist00".utf8)))
        XCTAssertEqual(job.configurations.first?.keepOriginal, true)
        XCTAssertEqual(job.configurations.first?.steps?.map(\.state), [.completed])
        XCTAssertEqual(job.configurations.first?.steps?.first?.settings?.configOptions.binaryPlist, true)
        XCTAssertEqual(transitions[job.id], [.queued, .waiting, .queued, .running, .completed])
        let decoded = try JSONDecoder().decode(ConversionActivity.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(decoded.id, job.id)
        XCTAssertEqual(decoded.configurations.first?.settings, job.configurations.first?.settings)
        _ = try ConversionEngine.undo(record)

        service.action = .immediately
        let failed = try rename("failed", target: "png")
        try await waitFor { results.count == 2 }
        XCTAssertThrowsError(try results[1].get())
        let failure = try XCTUnwrap(jobs.values.first { $0.requestedURL == failed })
        XCTAssertEqual(failure.state, .failed)
        XCTAssertFalse(failure.message?.isEmpty ?? true)
        XCTAssertEqual(try Data(contentsOf: failed), bytes)

        service.action = .askFirst
        service.convertMultipleFormats = true
        let group = try rename("group", target: "yaml,toml")
        try await waitFor { approvals.count == 2 }
        let groupJob = try XCTUnwrap(jobs.values.first { $0.requestedURL == group })
        XCTAssertTrue(service.cancel(groupJob.id))
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertEqual(jobs[groupJob.id]?.state, .cancelled)
        XCTAssertEqual(try Data(contentsOf: group), bytes)

        service.action = .immediately
        cancelOnStart = true
        let large = Data(("[" + Array(repeating: #"{"value":3}"#, count: 100_000).joined(separator: ",") + "]").utf8)
        let stopping = try rename("stopping", target: "yaml,toml", data: large)
        try await waitFor { jobs.values.contains { $0.requestedURL == stopping && callbackCancellations[$0.id] != nil } }
        let stoppingID = try XCTUnwrap(jobs.values.first { $0.requestedURL == stopping }?.id)
        XCTAssertEqual(callbackCancellations[stoppingID], true)
        await service.stopAndWait()
        XCTAssertTrue(jobs.values.allSatisfy { $0.state.isFinished }, "Stopping waits for final status callbacks")
        XCTAssertEqual(try Data(contentsOf: stopping), large)
    }
}
