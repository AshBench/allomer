import Darwin
import Foundation

extension ConversionEngine {
    /// Write a new file. The source and any existing destination remain unchanged.
    @discardableResult
    public func convert(_ source: URL, to destination: URL,
                        settings: ConversionSettings = ConversionSettings(),
                        resourceDirectory: URL? = nil,
                        stageOverrides: [ConversionStageOverride] = [],
                        progress: (@Sendable (URL, ConversionActivity.Step) -> Void)? = nil) throws -> [OutputResources] {
        try Task.checkCancellation()
        let sourceVersion = try SourceVersion(source)
        guard let format = catalog.format(for: destination) else {
            throw ConversionError.message("The output extension is unknown.")
        }
        guard let route = conversionRoute(from: source, to: format), !route.isEmpty else {
            throw ConversionError.message("This build has no conversion route for those file formats.")
        }
        let sources = [catalog.format(for: source)?.id] + route.dropLast().map { Optional($0.id) }
        guard stageOverrides.count <= route.count, Set(stageOverrides.map(\.id)).count == stageOverrides.count,
              stageOverrides.allSatisfy({ override in
                  route.indices.contains { sources[$0] == override.sourceID && route[$0].id == override.targetID }
              }) else {
            throw ConversionError.message("A stage override is duplicated or no longer matches this conversion route. Review the stage settings.")
        }
        let manager = FileManager.default
        var existing = stat()
        if lstat(destination.path, &existing) == 0 {
            throw ConversionError.message("The output name is already in use.")
        }
        guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let parent = destination.deletingLastPathComponent()
        let work = parent.appendingPathComponent(".allomer-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        // Manual conversion has no journal. The lock protects live work, and the marker lets a
        // later conversion reclaim this directory if the process exits before cleanup.
        let workLock = BackupRetention.lockWorkDirectory(work)
        defer { if workLock >= 0 { close(workLock) } }
        var keepRecoveryFiles = false
        defer { if !keepRecoveryFiles { try? manager.removeItem(at: work) } }
        try BackupRetention.markWorkDirectory(work)
        let temporary = work.appendingPathComponent("output.\(destination.pathExtension)")
        var stepInput = source
        var resources: [OutputResources] = []
        for (index, step) in route.enumerated() {
            try Task.checkCancellation()
            let stepOutput = index == route.count - 1 ? temporary
                : work.appendingPathComponent("step-\(index).\(step.extensions[0])")
            var selected = settings
            if index > 0 { selected.spreadsheetOptions.sheetIndex = 0 }
            let override = stageOverrides.first(where: { $0.sourceID == sources[index] && $0.targetID == step.id })
            if let override {
                selected = override.settings
            }
            selected.mediaOptions.cpuProfile = settings.mediaOptions.cpuProfile
            var activity = ConversionActivity.Step(index: index, count: route.count,
                sourceID: sources[index], targetID: step.id, settings: selected)
            progress?(destination, activity)
            do {
                try Task.checkCancellation()
                let compressPNG = step.id == "png" && (index == route.count - 1 || override != nil)
                if compressPNG, !(0...9).contains(selected.imageOptions.pngCompressionLevel) {
                    throw ConversionError.message("PNG compression must be between 0 and 9.")
                }
                resources = try convertStep(stepInput, to: stepOutput, format: step, settings: selected,
                    resourceDirectory: index == 0 ? resourceDirectory ?? source.deletingLastPathComponent() : stepInput.deletingLastPathComponent())
                if stepInput != source { try manager.removeItem(at: stepInput) }
                stepInput = stepOutput
                if compressPNG {
                    try PNGCompression.recompress(stepOutput, level: selected.imageOptions.pngCompressionLevel)
                }
                activity.state = .completed
                progress?(destination, activity)
            } catch {
                activity.state = Task.isCancelled || error is CancellationError ? .cancelled : .failed
                activity.message = error.localizedDescription
                progress?(destination, activity)
                throw error
            }
        }
        try Task.checkCancellation()
        guard try SourceVersion(source) == sourceVersion else {
            throw ConversionError.message("The source changed during conversion.")
        }
        var published: [OutputResources] = []
        do {
            for resource in resources {
                try resource.move(from: work, to: parent)
                published.append(resource)
            }
        } catch {
            for resource in published.reversed() { try? resource.move(from: parent, to: work, checkCancellation: false) }
            // Retain generated files if a resource publication was interrupted.
            keepRecoveryFiles = !published.isEmpty
            throw error
        }
        // link() publishes atomically and refuses to overwrite a file created during conversion.
        let result = temporary.withUnsafeFileSystemRepresentation { temporaryPath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                Darwin.link(temporaryPath!, destinationPath!)
            }
        }
        guard result == 0 else {
            let code = errno
            for resource in published.reversed() { try? resource.move(from: parent, to: work, checkCancellation: false) }
            keepRecoveryFiles = !published.isEmpty
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "The output could not be saved. Its name may already be in use."
            ])
        }
        return resources
    }

    private func convertStep(_ originalSource: URL, to temporary: URL, format: FileFormat,
                             settings: ConversionSettings,
                             resourceDirectory: URL) throws -> [OutputResources] {
        var source = originalSource
        var image = ImageConverter.inspect(source)
        let prepared = !ArchiveConverter.formats.contains(format.id)
            ? try ImageConverter.prepareInput(source, type: image?.type, work: temporary.deletingLastPathComponent()) : nil
        defer { if let prepared { try? FileManager.default.removeItem(at: prepared) } }
        if let prepared { source = prepared; image = ImageConverter.inspect(prepared) }
        var sourceFormat = catalog.format(for: source)
        let isPDF = image?.type == "com.adobe.pdf" || (image == nil && sourceFormat?.id == "pdf")
        if image?.type == "public.jpeg", !ArchiveConverter.formats.contains(format.id) {
            guard let toolsDirectory else { throw ConversionError.message("The bundled JPEG validator is missing.") }
            try ImageConverter.validateJPEG(source, tools: toolsDirectory, work: temporary.deletingLastPathComponent())
        }
        let gifMetadata: GIFMetadata?
        if image?.type == "com.compuserve.gif", !ArchiveConverter.formats.contains(format.id) {
            guard let toolsDirectory else { throw ConversionError.message("The bundled GIF validator is missing.") }
            gifMetadata = try ImageConverter.validateGIF(source, tools: toolsDirectory, work: temporary.deletingLastPathComponent())
        } else { gifMetadata = nil }
        let gifInput: URL?
        if let gifMetadata, let toolsDirectory {
            gifInput = format.category == "video"
                ? try GIFPreparation.prepareVideo(source, metadata: gifMetadata, work: temporary.deletingLastPathComponent())
                : try GIFPreparation.prepare(source, tools: toolsDirectory, work: temporary.deletingLastPathComponent())
        } else { gifInput = nil }
        defer { if let gifInput { try? FileManager.default.removeItem(at: gifInput) } }
        if let gifInput {
            source = gifInput
            image = ImageConverter.inspect(gifInput)
            sourceFormat = catalog.format(for: gifInput)
        }
        if IconProjectConverter.matches(source), format.id == "png", toolsDirectory != nil {
            try IconProjectConverter.convert(source, to: temporary, engine: self)
        } else if ArchiveConverter.formats.contains(format.id) {
            try ArchiveConverter.convert(source, to: temporary, from: sourceFormat, to: format,
                options: settings.archiveOptions)
        } else if image == nil, format.id == "pdf", sourceFormat?.id == "pptx", let toolsDirectory {
            try PresentationConverter.convert(source, to: temporary, tools: toolsDirectory)
        } else if image == nil, format.id == "pdf", sourceFormat?.id == "docx", let toolsDirectory,
                  outputCapabilities(for: format).contains("Word layout") {
            try WordLayoutConverter.convert(source, to: temporary, tools: toolsDirectory)
        } else if image == nil, format.id == "pdf", let input = sourceFormat,
                  ["html", "markdown"].contains(input.id), let toolsDirectory {
            try DocumentConverter.makePDF(source, to: temporary, from: input, tools: toolsDirectory,
                options: settings.documentOptions, resources: resourceDirectory, catalog: catalog)
        } else if (image == nil || image?.type == "public.svg-image"), let input = sourceFormat,
                  ["svg", "svgz"].contains(input.id), SVGConverter.outputs.contains(format.id), let toolsDirectory {
            try SVGConverter.convert(source, to: temporary, from: input, format: format, options: settings.imageOptions,
                tool: toolsDirectory.appendingPathComponent("webguard"), resources: resourceDirectory, catalog: catalog)
        } else if isPDF, PDFConverter.outputs.contains(format.id), let toolsDirectory {
            try PDFConverter.convert(source, to: temporary, format: format.id,
                tool: toolsDirectory.appendingPathComponent("pdfguard"), options: settings.pdfOptions)
        } else if let input = isPDF ? catalog.format(forExtension: "pdf") : sourceFormat,
                  PostScriptConverter.routes[input.id]?.contains(format.id) == true,
                  let toolsDirectory {
            try PostScriptConverter.convert(source, to: temporary, from: input, to: format,
                tools: toolsDirectory, options: settings.postScriptOptions)
        } else if let input = sourceFormat, ModelConverter.routes[input.id]?.contains(format.id) == true,
                  let toolsDirectory {
            return try ModelConverter.convert(source, to: temporary, from: input, to: format,
                tool: toolsDirectory.appendingPathComponent("modeltool"), options: settings.modelOptions,
                resourceDirectory: resourceDirectory)
        } else if let input = sourceFormat, EmailConverter.routes[input.id]?.contains(format.id) == true,
                  let toolsDirectory {
            try EmailConverter.convert(source, to: temporary, from: input, to: format,
                tool: toolsDirectory.appendingPathComponent("mailfile"), options: settings.emailOptions)
        } else if FontConverter.formats.contains(format.id), let toolsDirectory {
            try FontConverter.convert(source, to: temporary, format: format.id,
                                      tool: toolsDirectory.appendingPathComponent("fontguard"))
        } else if format.id == "epub", let input = sourceFormat,
                  EbookConverter.inputFormats.contains(input.id), let toolsDirectory {
            try EbookConverter.convert(source, to: temporary, tool: toolsDirectory.appendingPathComponent("mobitool"))
        } else if SpreadsheetConverter.outputFormats.contains(format.id), let sourceFormat,
                  SpreadsheetConverter.inputFormats.contains(sourceFormat.id), let toolsDirectory,
                  !(ConfigConverter.formats.contains(sourceFormat.id) && ConfigConverter.formats.contains(format.id)) {
            try SpreadsheetConverter.convert(source, to: temporary, from: sourceFormat, to: format,
                tool: toolsDirectory.appendingPathComponent("tabular"), options: settings.spreadsheetOptions,
                configOptions: settings.configOptions)
        } else if ConfigConverter.formats.contains(format.id), let sourceFormat,
           ConfigConverter.formats.contains(sourceFormat.id) {
            try ConfigConverter.convert(source, to: temporary, from: sourceFormat, to: format,
                options: settings.configOptions)
        } else if format.category == "subtitle", let sourceFormat, let toolsDirectory {
            if sourceFormat.category == "video", let media {
                try SubtitleConverter.extract(source, to: temporary, target: format, media: media,
                    catalog: catalog, options: settings.subtitleOptions, ocrLanguage: settings.pdfOptions.ocrLanguage)
            } else {
                try SubtitleConverter.convert(source, to: temporary, from: sourceFormat, to: format,
                    tool: toolsDirectory.appendingPathComponent("ffmpeg"), options: settings.subtitleOptions)
            }
        } else if ["audio", "video"].contains(format.category), let media {
            try media.convert(source, to: temporary, format: format, options: settings.mediaOptions)
        } else if image == nil, ["gif", "webp"].contains(format.id),
                  sourceFormat?.category == "video", let media, let toolsDirectory {
            try media.convertAnimation(source, to: temporary, format: format.id, tools: toolsDirectory,
                options: settings.imageOptions)
        } else if image != nil {
            if IconImageConverter.inputTypes.contains(image!.type), format.id == "png" {
                try IconImageConverter.convert(source, to: temporary, format: format, options: settings.imageOptions)
            } else if format.id == "svg", let toolsDirectory {
                try SVGTracingConverter.convert(source, to: temporary, options: settings.imageOptions.tracing,
                                                tool: toolsDirectory.appendingPathComponent("traceguard"))
            } else if format.id == "jxl", let toolsDirectory {
                try JPEGXLConverter.convert(source, to: temporary, tool: toolsDirectory.appendingPathComponent("jxlguard"),
                    options: settings.imageOptions)
            } else if format.id == "webp", let toolsDirectory {
                try WebPConverter.convert(source, to: temporary, tool: toolsDirectory.appendingPathComponent("webpguard"),
                    options: settings.imageOptions)
            } else if format.id == "avif", !ImageConverter.outputTypes.contains("public.avif"), let media {
                try AVIFConverter.convert(source, to: temporary, media: media, options: settings.imageOptions)
            } else if ["txt", "html"].contains(format.id) || (format.id == "pdf" && settings.pdfOptions.imageOCR) {
                guard let toolsDirectory else { throw ConversionError.message("The native OCR tool is missing.") }
                try OCRConverter.convert(source, to: temporary, format: format,
                    tools: toolsDirectory, language: settings.pdfOptions.ocrLanguage, options: settings.imageOptions)
            } else {
                try ImageConverter.convert(source, to: temporary, format: format, options: settings.imageOptions,
                                           animationDecoder: toolsDirectory?.appendingPathComponent("ffmpeg"),
                                           tiffEncoder: toolsDirectory?.appendingPathComponent("tiffguard"))
            }
        } else if let sourceFormat, let toolsDirectory,
                  DocumentConverter.nativeRoutes[sourceFormat.id]?.contains(format.id) == true {
            try DocumentConverter.convertNative(source, to: temporary, from: sourceFormat, to: format,
                                                tool: toolsDirectory.appendingPathComponent("nativeguard"))
        } else if let sourceFormat,
                  let toolsDirectory,
                  FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent("carta").path) {
            var documentSource = source
            var documentFormat = sourceFormat
            let normalized = temporary.deletingLastPathComponent().appendingPathComponent("table-\(UUID().uuidString).tsv")
            defer { try? FileManager.default.removeItem(at: normalized) }
            if sourceFormat.id == "csv", settings.spreadsheetOptions.csvDelimiter != .comma {
                guard let tsv = catalog.format(forExtension: "tsv") else {
                    throw ConversionError.message("The TSV format is missing from the catalog.")
                }
                try SpreadsheetConverter.convert(source, to: normalized, from: sourceFormat, to: tsv,
                    tool: toolsDirectory.appendingPathComponent("tabular"), options: settings.spreadsheetOptions,
                    configOptions: settings.configOptions)
                documentSource = normalized
                documentFormat = tsv
            }
            try DocumentConverter.convert(documentSource, to: temporary, from: documentFormat, to: format,
                tool: toolsDirectory.appendingPathComponent("carta"), options: settings.documentOptions,
                resourceDirectory: resourceDirectory)
        } else {
            throw ConversionError.message("No installed converter can handle this input. This build is incomplete.")
        }
        return []
    }
}
