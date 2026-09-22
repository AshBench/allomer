import ConversionCore
import Foundation

/// Startup has to land on a complete helper set. One source is chosen and refused by name when it
/// is incomplete, rather than falling through to the next one, so a damaged install stops instead
/// of running on whatever tools happen to sit elsewhere on the machine.
func resolveToolsDirectory() throws -> URL {
    // Inside an app, only that app's own helpers count. A development override is ignored here
    // because a complete external directory would otherwise hide a damaged install behind a
    // working command.
    if Bundle.main.bundleURL.pathExtension == "app" {
        guard let tools = ConversionEngine.bundledToolsDirectory else {
            throw ConversionError.message("Conversion tools are missing. Reinstall the app.")
        }
        return tools
    }
    if let path = ProcessInfo.processInfo.environment["ALLOMER_TOOLS_DIR"] {
        let tools = URL(fileURLWithPath: path)
        guard ConversionEngine.isCompleteToolsDirectory(tools) else {
            throw ConversionError.message("Conversion tools are missing from ALLOMER_TOOLS_DIR: \(tools.path)")
        }
        return tools
    }
    let tools = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".tools/bin")
    guard ConversionEngine.isCompleteToolsDirectory(tools) else {
        throw ConversionError.message("Conversion tools are missing from \(tools.path). Build them or set ALLOMER_TOOLS_DIR.")
    }
    return tools
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    let engine = try ConversionEngine(toolsDirectory: try resolveToolsDirectory())
    switch arguments.first {
    case "formats":
        for format in engine.catalog.formats {
            let capabilities = engine.outputCapabilities(for: format)
            print("\(format.id)\t\(format.extensions.joined(separator: ","))\t\(capabilities.isEmpty ? "no output writer" : capabilities.joined(separator: ", ") + " output")")
        }
    case "convert" where arguments.count == 3 || (arguments.count == 5 && ["--image-options", "--postscript-options", "--subtitle-options", "--media-options"].contains(arguments[3])):
        var settings = ConversionSettings()
        if arguments.count == 5 {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: arguments[4]))
            defer { try? file.close() }
            let data = try file.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else { throw ConversionError.message("Conversion options exceed 64 KiB.") }
            if arguments[3] == "--image-options" {
                settings.imageOptions = try JSONDecoder().decode(ImageOptions.self, from: data)
            } else if arguments[3] == "--subtitle-options" {
                settings.subtitleOptions = try JSONDecoder().decode(SubtitleOptions.self, from: data)
            } else if arguments[3] == "--media-options" {
                settings.mediaOptions = try JSONDecoder().decode(MediaOptions.self, from: data)
            } else {
                settings.postScriptOptions = try JSONDecoder().decode(PostScriptOptions.self, from: data)
            }
        }
        try engine.convert(URL(fileURLWithPath: arguments[1]), to: URL(fileURLWithPath: arguments[2]),
                           settings: settings)
        print(URL(fileURLWithPath: arguments[2]).path)
    default:
        print("""
        Usage:
          allomer formats
          allomer convert INPUT OUTPUT [--image-options FILE.json]
          allomer convert INPUT OUTPUT [--postscript-options FILE.json]
          allomer convert INPUT OUTPUT [--subtitle-options FILE.json]
          allomer convert INPUT OUTPUT [--media-options FILE.json]

        Early build: images, OCR, documents, media, subtitles, configuration files, archives, spreadsheets, ebooks, fonts, email, models, PostScript, and PDF.
        Existing files are never overwritten. See docs/index.md for current limitations.
        """)
        if !arguments.isEmpty { exit(2) }
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
