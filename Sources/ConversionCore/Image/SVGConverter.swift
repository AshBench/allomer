import Foundation
import ImageIO

enum SVGConverter {
    static let outputs: Set<String> = ["png", "pdf", "svg", "svgz"]
    static func convert(_ input: URL, to output: URL, from sourceFormat: FileFormat, format: FileFormat,
                        options: ImageOptions, tool: URL, resources: URL, catalog: FormatCatalog) throws {
        let version = try FileVersion(input)
        let limit: Int64 = (sourceFormat.id == "svgz" ? 65 : 64) * 1024 * 1024
        guard version.size > 0, version.size <= limit else {
            throw ConversionError.message("Use an SVG up to 64 MiB or SVGZ up to 65 MiB.")
        }
        let work = output.deletingLastPathComponent()
        var source = input
        defer { if source != input { try? FileManager.default.removeItem(at: source) } }
        if sourceFormat.id == "svgz" {
            source = work.appendingPathComponent("svg-\(UUID().uuidString).svg")
            try ExternalTool.run(URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-cd", "--", input.path],
                workDirectory: work, outputFile: source, outputLimit: 64 * 1024 * 1024)
        }
        try DocumentConverter.validateXML(source, root: "svg", namespace: "http://www.w3.org/2000/svg")
        switch format.id {
        case "svg":
            try FileManager.default.copyItem(at: source, to: output)
        case "svgz":
            guard let gzip = catalog.formats.first(where: { $0.id == "gzip" }) else {
                throw ConversionError.message("The GZIP writer is missing.")
            }
            try ArchiveConverter.convert(source, to: output, from: nil, to: gzip)
        case "png", "pdf":
            try ExternalTool.run(tool, arguments: [source.path, work.path, resources.path, "svg", source.path,
                output.lastPathComponent, format.id, String(options.svgWidth), String(options.svgHeight), String(options.svgScale)], workDirectory: work)
            if format.id == "pdf" {
                guard try PostScriptConverter.pageSizes(output).count == 1 else {
                    throw ConversionError.message("SVG export must produce one PDF page.")
                }
            } else {
                guard let image = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetCount(image) == 1,
                      CGImageSourceGetType(image) as String? == "public.png",
                      let pixels = CGImageSourceCreateImageAtIndex(image, 0, nil),
                      pixels.width > 0, pixels.height > 0, pixels.width <= 32_000_000 / pixels.height else {
                    throw ConversionError.message("The SVG export is not a valid PNG within the image-size limit.")
                }
            }
        default: throw ConversionError.message("Unsupported SVG output format.")
        }
        guard try FileVersion(input) == version else { throw ConversionError.message("The SVG source changed during conversion.") }
    }
}
