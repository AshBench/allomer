import AppKit
import ConversionCore
import UniformTypeIdentifiers

extension ConversionModel {
    func chooseFile() {
        guard !busy, !cleaningBackups, engine != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let file = panel.url { select(file) }
    }

    func select(_ file: URL) {
        guard !busy, !cleaningBackups, let engine, file.isFileURL else { return }
        source = file
        embeddedSubtitleTracks = []
        savedFile = nil
        busy = true
        status = "Reading file…"
        Task {
            let (formats, tracks) = await Task.detached(priority: .utility) {
                (engine.availableOutputs(for: file), (try? engine.subtitleTracks(in: file)) ?? [])
            }.value
            targets = formats
            embeddedSubtitleTracks = tracks
            targetID = formats.contains(where: { $0.id == targetID }) ? targetID : (formats.first?.id ?? "")
            status = formats.isEmpty ? "Conversion for this file is not available yet." : "Ready to save a converted copy."
            busy = false
        }
    }

    func save() {
        guard !busy, !cleaningBackups, let engine, let source, let target else { return }
        let panel = NSSavePanel()
        panel.title = "Save Converted Copy"
        panel.prompt = "Convert"
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".converted." + target.extensions[0]
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: target.extensions[0]) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // The panel offers to replace an existing file, but conversion always refuses to overwrite one.
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            error = "That name is already in use. Choose a different name."
            return
        }
        let conversionSettings = settings
        let stageOverrides = manualStageOverrides
        busy = true
        savedFile = nil
        status = "Converting \(source.lastPathComponent)…"
        var job = ConversionActivity(originalURL: source, requestedURL: destination, outputURLs: [destination],
            state: .running, sourceID: engine.catalog.format(for: source)?.id)
        job.configurations = [.init(outputURL: destination, settings: settings, keepOriginal: true)]
        manualJobID = job.id
        recordJob(job)
        let (progress, continuation) = AsyncStream<(URL, ConversionActivity.Step)>.makeStream()
        let task = Task.detached(priority: .utility) {
            defer { continuation.finish() }
            _ = try engine.convert(source, to: destination, settings: conversionSettings,
                               stageOverrides: stageOverrides,
                               progress: { continuation.yield(($0, $1)) })
        }
        worker = task
        workerCanCancel = true
        manualCompletion = Task {
            for await (output, step) in progress {
                job.record(step, for: output)
                recordJob(job)
                status = "Step \(step.id + 1) of \(step.count): \(step.sourceID ?? "file") → \(step.targetID) · \(step.state.title)"
            }
            do {
                try await task.value
                savedFile = destination
                status = "Saved \(destination.lastPathComponent)."
                appSettings.converted(destination, manual: true)
                job.state = .completed
            } catch is CancellationError {
                status = "Conversion cancelled."
                job.state = .cancelled
            } catch {
                self.error = error.localizedDescription
                status = "Conversion failed."
                appSettings.failed(error.localizedDescription, manual: true)
                job.state = .failed
                job.message = error.localizedDescription
            }
            recordJob(job)
            manualJobID = nil
            worker = nil
            busy = false
            manualCompletion = nil
        }
    }

    func cancel() {
        worker?.cancel()
        status = "Stopping conversion…"
    }

    func cancelJob(_ id: UUID) {
        if manualJobID == id { cancel() }
        else { _ = automatic?.cancel(id) }
    }

}
