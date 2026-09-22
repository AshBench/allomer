import Darwin
import Foundation

public struct ConversionEngine: Sendable {
    public let catalog: FormatCatalog
    public let toolsDirectory: URL?
    let media: MediaConverter?
    private var capabilities: [String: [String]] = [:]

    public static var bundledToolsDirectory: URL? { toolsDirectory(in: Bundle.main.bundleURL) }

    /// Whether a directory holds every helper and resource the engine needs for its full set of
    /// routes. Startup checks this once so an incomplete directory is refused instead of accepted
    /// with routes quietly missing.
    public static func isCompleteToolsDirectory(_ tools: URL) -> Bool {
        guard ["carta", "ffmpeg", "ffprobe", "tabular", "mobitool", "fontconvert", "fontguard", "mailfile", "modeltool", "gs", "postscript", "pdftops", "psguard", "mutool", "pdfguard", "nativeconvert", "nativeguard", "webconvert", "webguard", "cwebp", "webpguard", "webpanim", "webpanimguard", "cjxl", "jxlguard", "tiffcp", "tiffguard", "vectortrace", "traceguard"].allSatisfy({
            FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path)
        }) else { return false }
        // Two capabilities also need resource files, and the engine already tests for exactly these
        // below. Without them here, a bundle holding every executable but no resources would pass
        // this gate and then quietly drop presentation and PostScript output instead of refusing.
        let resources = [PresentationConverter.resources(tools: tools).appendingPathComponent("renderer.js"),
                         WordLayoutConverter.resources(tools: tools).appendingPathComponent("renderer.js"),
                         PostScriptConverter.resources(tools: tools).appendingPathComponent("fonts/n019003l.pfb")]
        return resources.allSatisfy { (try? FileVersion($0).size).map { $0 > 0 } == true }
    }

    /// The helpers directory of a bundle, or nil when anything it needs is missing.
    static func toolsDirectory(in bundle: URL) -> URL? {
        let tools = bundle.appendingPathComponent("Contents/Helpers")
        return isCompleteToolsDirectory(tools) ? tools : nil
    }

    public init(toolsDirectory: URL? = nil) throws {
        catalog = try FormatCatalog()
        self.toolsDirectory = toolsDirectory
        if let toolsDirectory, ["ffmpeg", "ffprobe"].allSatisfy({
            FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent($0).path)
        }) {
            media = try MediaConverter(toolsDirectory: toolsDirectory)
        } else {
            media = nil
        }
        for format in catalog.formats { capabilities[format.id] = detectCapabilities(for: format) }
    }

    public func outputCapabilities(for format: FileFormat) -> [String] {
        capabilities[format.id] ?? []
    }

    public func detectedFormat(at file: URL, sourceExtensionHint: String? = nil) throws -> FileFormat? {
        try Task.checkCancellation()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("format-\(UUID())")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        return try FormatDetection.detect(file, catalog: catalog, media: media, work: work, sourceExtensionHint: sourceExtensionHint)
    }

    private func detectCapabilities(for format: FileFormat) -> [String] {
        var capabilities: [String] = []
        if DocumentConverter.nativeOutputs.contains(format.id), let toolsDirectory,
           ["nativeconvert", "nativeguard"].allSatisfy({ FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent($0).path) }) {
            capabilities.append("Native document")
        }
        if format.id == "svg", let toolsDirectory,
           ["vectortrace", "traceguard"].allSatisfy({ FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent($0).path) }) {
            capabilities.append("Vector tracing")
        }
        if format.id == "jxl", let toolsDirectory,
           ["cjxl", "jxlguard"].allSatisfy({ FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent($0).path) }) {
            capabilities.append("JPEG XL")
        }
        if format.id == "webp", let toolsDirectory,
           ["cwebp", "webpguard", "webpanim", "webpanimguard"].allSatisfy({ FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent($0).path) }) {
            capabilities.append("WebP")
        }
        if format.id == "avif", let media, AVIFConverter.isAvailable(in: media) {
            capabilities.append("AVIF")
        }
        if format.id == "pdf", let toolsDirectory,
           ["webconvert", "webguard", "mutool", "pdfguard"].allSatisfy({ FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent($0).path) }) {
            capabilities.append("Document PDF")
            if FileManager.default.fileExists(atPath: PresentationConverter.resources(tools: toolsDirectory).appendingPathComponent("renderer.js").path) {
                capabilities.append("Presentation PDF")
            }
            if FileManager.default.fileExists(atPath: WordLayoutConverter.resources(tools: toolsDirectory).appendingPathComponent("renderer.js").path) {
                capabilities.append("Word layout")
            }
        }
        if SVGConverter.outputs.contains(format.id), let toolsDirectory,
           ["webconvert", "webguard"].allSatisfy({ FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent($0).path) }) {
            capabilities.append("SVG conversion")
        }
        if OCRConverter.outputs.contains(format.id), let toolsDirectory,
           (["nativeconvert", "nativeguard"] + (format.id == "pdf" ? ["mutool", "pdfguard"] : [])).allSatisfy({ FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent($0).path) }) {
            capabilities.append("Native OCR")
        }
        if PDFConverter.outputs.contains(format.id), let toolsDirectory,
           ["mutool", "pdfguard"].allSatisfy({ FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent($0).path) }) {
            capabilities.append("PDF conversion")
        }
        if PostScriptConverter.outputs.contains(format.id), let toolsDirectory,
           ["gs", "postscript", "pdftops", "psguard"].allSatisfy({ FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent($0).path) }),
           FileManager.default.fileExists(atPath: PostScriptConverter.resources(tools: toolsDirectory).appendingPathComponent("fonts/n019003l.pfb").path) {
            capabilities.append("PostScript conversion")
        }
        if ModelConverter.outputs.contains(format.id), let toolsDirectory,
           FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent("modeltool").path) {
            capabilities.append("Model conversion")
        }
        if ["eml", "emlx", "msg", "html"].contains(format.id), let toolsDirectory,
           FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent("mailfile").path) {
            capabilities.append("Email conversion")
        }
        if ArchiveConverter.formats.contains(format.id) { capabilities.append("macOS libarchive") }
        if FontConverter.formats.contains(format.id), let toolsDirectory,
           FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent("fontguard").path) {
            capabilities.append("Font conversion")
        }
        if format.id == "epub", let toolsDirectory,
           FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent("mobitool").path) {
            capabilities.append("libmobi")
        }
        if ConfigConverter.formats.contains(format.id) { capabilities.append("Native configuration") }
        if SpreadsheetConverter.outputFormats.contains(format.id), let toolsDirectory,
           FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent("tabular").path) {
            capabilities.append("Spreadsheet conversion")
        }
        if format.id == "gif", let toolsDirectory,
           FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent("ffmpeg").path) {
            capabilities.append("GIF")
        } else if format.id != "gif", let type = format.typeIdentifier, ImageConverter.outputTypes.contains(type) {
            capabilities.append("ImageIO")
        }
        if DocumentConverter.outputFormats.contains(format.id), let toolsDirectory,
           FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent("carta").path) {
            capabilities.append("carta")
        }
        if media?.supports(format.id) == true { capabilities.append("FFmpeg") }
        if SubtitleConverter.formats.contains(format.id), let toolsDirectory,
           FileManager.default.isExecutableFile(atPath: toolsDirectory.appendingPathComponent("ffmpeg").path) {
            capabilities.append("FFmpeg subtitles")
        }
        return capabilities
    }

    public func availableOutputs(for source: URL) -> [FileFormat] {
        let routes = conversionRoutes(for: source)
        let primary = catalog.formats.filter { routes[$0.id] != nil }
        let archives = (try? FileVersion(source)) != nil ? catalog.formats.filter { ArchiveConverter.formats.contains($0.id) } : []
        return primary + archives
    }

    public func subtitleTracks(in source: URL) throws -> [EmbeddedSubtitleTrack] {
        guard catalog.format(for: source)?.category == "video", let media else { return [] }
        let version = try FileVersion(source)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("subtitles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let tracks = try SubtitleConverter.tracks(in: media.inspect(source, work: work))
        guard try FileVersion(source) == version else { throw ConversionError.message("The file changed while reading subtitle tracks.") }
        return tracks
    }

    public func conversionRoute(from source: URL, to target: FileFormat) -> [FileFormat]? {
        if ArchiveConverter.formats.contains(target.id) { return (try? FileVersion(source)) != nil ? [target] : nil }
        let direct = conversionOutputs(for: source)
        if direct.contains(target) { return [target] }
        return conversionRoutes(for: source, direct: direct)[target.id]
    }

    /// Preview a format pair without inspecting a file. Actual contents can change its route.
    public func conversionRoute(from source: FileFormat, to target: FileFormat) -> [FileFormat]? {
        if ArchiveConverter.formats.contains(target.id) { return [target] }
        if source.category == "image", let type = source.typeIdentifier, ImageConverter.inputTypes.contains(type) {
            return conversionRoutes(direct: conversionOutputs(forImage: (type, 1)))[target.id]
        }
        return conversionRoutes(direct: conversionOutputs(for: source))[target.id]
    }

    private func conversionRoutes(for source: URL, direct: [FileFormat]? = nil) -> [String: [FileFormat]] {
        var routes = conversionRoutes(direct: direct ?? conversionOutputs(for: source))
        if let image = ImageConverter.inspect(source), image.type != "com.adobe.pdf", image.frames > 1,
           !IconImageConverter.inputTypes.contains(image.type) {
            // A document intermediate must not select one frame for bitmap tracing.
            routes.removeValue(forKey: "svg")
            routes.removeValue(forKey: "svgz")
            if AnimationFrames.keys(image.type) == nil {
                for format in catalog.formats where format.category == "video" {
                    routes.removeValue(forKey: format.id)
                }
            }
        }
        return routes
    }

    private func conversionRoutes(direct: [FileFormat]) -> [String: [FileFormat]] {
        var routes = Dictionary(uniqueKeysWithValues: direct.map { ($0.id, [$0]) })
        // These intermediates connect the readers that do not share a direct writer.
        let intermediates = ["tsv", "json", "csv", "epub", "eml", "html", "rtf", "ply", "glb", "svg", "pdf", "docx", "png", "gif"]
        let preferred: (FileFormat, FileFormat) -> Bool = {
            (intermediates.firstIndex(of: $0.id) ?? Int.max, $0.id)
                < (intermediates.firstIndex(of: $1.id) ?? Int.max, $1.id)
        }
        var queue = direct.sorted(by: preferred)
        var index = 0
        while index < queue.count {
            let input = queue[index]
            index += 1
            guard intermediates.contains(input.id), let path = routes[input.id] else { continue }
            for output in conversionOutputs(for: input).sorted(by: preferred) where routes[output.id] == nil {
                routes[output.id] = path + [output]
                queue.append(output)
            }
        }
        return routes
    }

    private func conversionOutputs(for source: URL) -> [FileFormat] {
        if IconProjectConverter.matches(source), let format = catalog.format(forExtension: "icon") {
            return conversionOutputs(for: format)
        }
        if let image = ImageConverter.inspect(source) { return conversionOutputs(forImage: image) }
        guard let input = catalog.format(for: source) else { return [] }
        return conversionOutputs(for: input)
    }

    private func conversionOutputs(forImage image: (type: String, frames: Int)) -> [FileFormat] {
        if IconImageConverter.inputTypes.contains(image.type) {
            return catalog.formats.filter { $0.id == "png" && ImageConverter.outputTypes.contains("public.png") }
        }
        if image.type == "public.svg-image", let svg = catalog.format(forExtension: "svg") {
            return conversionOutputs(for: svg)
        }
        if image.type == "com.adobe.pdf", let pdf = catalog.format(forExtension: "pdf"),
           capabilities["docx"]?.contains("PDF conversion") == true {
            return conversionOutputs(for: pdf)
        }
        return catalog.formats.filter { target in
            if image.frames == 1, image.type != "com.adobe.pdf",
               outputCapabilities(for: target).contains("Vector tracing") { return true }
            if image.frames == 1, image.type != "com.adobe.pdf",
               outputCapabilities(for: target).contains("JPEG XL") { return true }
            if (image.frames == 1 || AnimationFrames.keys(image.type) != nil), image.type != "com.adobe.pdf",
               outputCapabilities(for: target).contains("WebP") { return true }
            if image.frames == 1, image.type != "com.adobe.pdf", target.id == "avif",
               outputCapabilities(for: target).contains("AVIF") { return true }
            if image.type == "com.adobe.pdf", PostScriptConverter.routes["pdf"]?.contains(target.id) == true,
               outputCapabilities(for: target).contains("PostScript conversion") { return true }
            if (target.id != "gif" || outputCapabilities(for: target).contains("GIF")), let type = target.typeIdentifier,
               ImageConverter.supports(sourceType: image.type, frames: image.frames, outputType: type) { return true }
            if image.frames == 1, image.type != "com.adobe.pdf", ["txt", "html"].contains(target.id),
               outputCapabilities(for: target).contains("Native OCR") { return true }
            return image.type == "com.compuserve.gif" && target.category == "video"
                && media?.supports(target.id) == true
        }
    }

    private func conversionOutputs(for input: FileFormat) -> [FileFormat] {
        if input.id == "icon_composer" {
            return catalog.formats.filter { $0.id == "png" && outputCapabilities(for: $0).contains("SVG conversion") }
        }
        if input.id == "pptx" {
            return catalog.formats.filter { outputCapabilities(for: $0).contains("Presentation PDF") }
        }
        if ["svg", "svgz"].contains(input.id) {
            let targets: Set<String> = input.id == "svgz" ? ["svg"] : ["png", "pdf", "svgz"]
            return catalog.formats.filter { targets.contains($0.id) && outputCapabilities(for: $0).contains("SVG conversion") }
        }
        if input.id == "pdf" {
            return catalog.formats.filter { target in
                (PDFConverter.outputs.contains(target.id) && outputCapabilities(for: target).contains("PDF conversion"))
                    || (PostScriptConverter.routes["pdf"]!.contains(target.id) && outputCapabilities(for: target).contains("PostScript conversion"))
            }
        }
        if input.id == "png" {
            return catalog.formats.filter {
                (($0.category == "image" || $0.id == "pdf") && $0.typeIdentifier.map(ImageConverter.outputTypes.contains) == true
                    && ($0.id != "gif" || outputCapabilities(for: $0).contains("GIF")))
                    || outputCapabilities(for: $0).contains("WebP")
                    || outputCapabilities(for: $0).contains("AVIF")
                    || outputCapabilities(for: $0).contains("JPEG XL")
                    || outputCapabilities(for: $0).contains("Vector tracing")
                    || (["txt", "html"].contains($0.id) && outputCapabilities(for: $0).contains("Native OCR"))
            }
        }
        if input.id == "gif" {
            return catalog.formats.filter { $0.category == "video" && media?.supports($0.id) == true }
        }
        if let routes = PostScriptConverter.routes[input.id] {
            return catalog.formats.filter { routes.contains($0.id) && outputCapabilities(for: $0).contains("PostScript conversion") }
        }
        if let routes = ModelConverter.routes[input.id] {
            return catalog.formats.filter { routes.contains($0.id) && outputCapabilities(for: $0).contains("Model conversion") }
        }
        if let routes = EmailConverter.routes[input.id] {
            return catalog.formats.filter { routes.contains($0.id) && outputCapabilities(for: $0).contains("Email conversion") }
        }
        if FontConverter.formats.contains(input.id) {
            return catalog.formats.filter { outputCapabilities(for: $0).contains("Font conversion") }
        }
        if EbookConverter.inputFormats.contains(input.id) {
            return catalog.formats.filter { outputCapabilities(for: $0).contains("libmobi") }
        }
        if ConfigConverter.formats.contains(input.id) {
            return catalog.formats.filter { target in
                ConfigConverter.formats.contains(target.id) || (["json", "xml"].contains(input.id)
                    && outputCapabilities(for: target).contains("Spreadsheet conversion"))
            }
        }
        if SpreadsheetConverter.inputFormats.contains(input.id) {
            return catalog.formats.filter { target in
                outputCapabilities(for: target).contains("Spreadsheet conversion")
                    || (DocumentConverter.inputFormats.contains(input.id) && outputCapabilities(for: target).contains("carta"))
            }
        }
        if SubtitleConverter.formats.contains(input.id) {
            return catalog.formats.filter { outputCapabilities(for: $0).contains("FFmpeg subtitles") }
        }
        if ["audio", "video"].contains(input.category) {
            return catalog.formats.filter { target in
                if input.category == "video", outputCapabilities(for: target).contains("FFmpeg subtitles") { return true }
                if input.category == "video", media?.supportsAnimation(target.id) == true,
                   (target.id == "gif" && outputCapabilities(for: target).contains("GIF")
                    || target.id == "webp" && outputCapabilities(for: target).contains("WebP")) { return true }
                return media?.supports(target.id) == true && (input.category == "video"
                    || target.category == "audio" || MediaConverter.audioOnlyVideoFormats.contains(target.id))
            }
        }
        if DocumentConverter.inputFormats.contains(input.id) || DocumentConverter.nativeRoutes[input.id] != nil {
            return catalog.formats.filter {
                (DocumentConverter.inputFormats.contains(input.id) && outputCapabilities(for: $0).contains("carta"))
                    || (DocumentConverter.nativeRoutes[input.id]?.contains($0.id) == true && outputCapabilities(for: $0).contains("Native document"))
                    || (["html", "markdown"].contains(input.id) && outputCapabilities(for: $0).contains("Document PDF")
                        && (input.id == "html" || capabilities["html"]?.contains("carta") == true))
                    || (input.id == "docx" && outputCapabilities(for: $0).contains("Word layout"))
            }
        }
        return []
    }

}
