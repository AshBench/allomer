import CArchive
import Darwin
import Foundation
import UniformTypeIdentifiers

enum FormatDetection {
    static func detect(_ file: URL, catalog: FormatCatalog, media: MediaConverter?, work: URL,
                       sourceExtensionHint: String? = nil) throws -> FileFormat? {
        let version = try SourceVersion(file)
        let result = try identify(file, version: version, catalog: catalog, media: media, work: work, sourceExtensionHint: sourceExtensionHint)
        guard try SourceVersion(file) == version else {
            throw ConversionError.message("The file changed while its format was being identified.")
        }
        return result.flatMap { catalog.format(forExtension: $0) }
    }

    private static func identify(_ file: URL, version: SourceVersion, catalog: FormatCatalog,
                                 media: MediaConverter?, work: URL, sourceExtensionHint: String?) throws -> String? {
        if version.isPackage { return "icon_composer" }
        guard version.root.size > 0 else { return nil }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard try FileVersion(opened) == version.root else {
            throw ConversionError.message("The file changed before its format could be identified.")
        }
        let data = try input.read(upToCount: 1_048_576) ?? Data()
        let hintFormat = sourceExtensionHint.flatMap { catalog.format(forExtension: $0) } ?? catalog.format(for: file)
        let hint = hintFormat?.id
        if let image = ImageConverter.inspect(file) {
            if let raw = ImageConverter.rawTypes.first(where: { $0.0 == image.type }) { return raw.1 }
            if let format = catalog.formats.first(where: { $0.typeIdentifier == image.type }) { return format.id }
            if let ext = UTType(image.type)?.preferredFilenameExtension,
               let format = catalog.format(forExtension: ext) { return format.id }
        }
        let signatures: [(Data, String)] = [
            (Data([0x49, 0x49, 0x55, 0]), "rw2"), (Data([0xff, 0x0a]), "jxl"),
            (Data([0, 0, 0, 12, 0x4a, 0x58, 0x4c, 0x20, 13, 10, 0x87, 10]), "jxl"),
            (Data("glTF".utf8), "glb"), (Data("PXR-USDC".utf8), "usdc"),
            (Data("Kaydara FBX Binary  \0".utf8), "fbx"),
            (Data("wOFF".utf8), "woff"), (Data("wOF2".utf8), "woff2"),
            (Data("OTTO".utf8), "otf"), (Data("bplist00".utf8), "plist")
        ]
        if let match = signatures.first(where: { data.starts(with: $0.0) }) { return match.1 }
        let bytes = try ExternalTool.run(URL(fileURLWithPath: "/usr/bin/file"), arguments: [
            "-b", "-h", "-E", "-P", "bytes=1048576", "--mime-type", "--", file.path
        ], workDirectory: work, timeout: 5, captureOutput: true, outputLimit: 4096)
        let mime = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if data.starts(with: [0x50, 0x4b]) || data.starts(with: [0x1f, 0x8b]) {
            if let archive = try archiveType(file) { return archive }
        }
        let mediaHeader = ["caff", "TTA1", "wvpk"].contains { data.starts(with: Data($0.utf8)) }
            || MediaConverter.transportPacketStride(data) != nil
        if let media, mime.hasPrefix("audio/") || mime.hasPrefix("video/") || mime == "application/mxf" || mediaHeader {
            let info = try media.inspect(file, work: work)
            let formats = Set(info.format.format_name.split(separator: ",").map(String.init))
            let video = !info.video.isEmpty
            let codec = info.audio.first?.codec_name
            if formats.contains("mov") {
                if mime == "video/quicktime" { return "mov" }
                if mime == "video/3gpp" || mime == "video/3gpp2" { return "3gp" }
                if !video {
                    if codec == "alac", hint != "m4a" { return "alac" }
                    return hint == "mp4" ? "mp4" : "m4a"
                }
                return "mp4"
            }
            if formats.contains("matroska") || formats.contains("webm") {
                if mime.contains("webm") { return "webm" }
                return video || hint == "mkv" ? "mkv" : "mka"
            }
            if formats.contains("ogg") { return codec == "opus" && hint != "ogg" ? "opus" : "ogg" }
            if formats.contains("asf") { return video || hint == "wmv" ? "wmv" : "wma" }
            if formats.contains("mpegts") { return MediaConverter.transportPacketStride(data) == 192 ? "m2ts" : "ts" }
            if formats.contains("mpeg") { return hint == "vob" ? "vob" : "mpeg" }
            if formats.contains("eac3") || codec == "eac3" { return "eac3" }
            if formats.contains("ac3") { return "ac3" }
            if formats.contains("wv") || formats.contains("wavpack") { return "wv" }
            for id in ["mp3", "aac", "wav", "aiff", "flac", "caf", "au", "tta", "avi", "mxf", "flv"] {
                if formats.contains(id) { return id }
            }
        }
        // A partial read cannot distinguish these JSON documents from plain text.
        if data.count < version.root.size, ["text/plain", "application/json"].contains(mime),
           let hint, ["ipynb", "gltf"].contains(hint) { return hint }
        if mime == "application/json", data.count == version.root.size,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if object["nbformat"] is NSNumber, object["cells"] is [Any] { return "ipynb" }
            if let asset = object["asset"] as? [String: Any], asset["version"] is String { return "gltf" }
        }
        if mime == "application/xml" || mime == "text/xml" || mime == "image/svg+xml" || mime == "text/plain" {
            let root = XMLRoot(data).name
            if let id = ["svg": "svg", "opml": "opml", "COLLADA": "dae", "plist": "plist", "html": "html"][root ?? ""] { return id }
            if mime != "text/plain" { return "xml" }
        }
        let known = [
            "image/jpeg": "jpeg", "image/png": "png", "image/gif": "gif", "image/webp": "webp",
            "image/heic": "heic", "image/heif": "heic", "image/avif": "avif", "image/jxl": "jxl",
            "image/tiff": "tiff", "image/bmp": "bmp", "image/x-ms-bmp": "bmp", "image/x-icon": "ico",
            "image/vnd.microsoft.icon": "ico", "image/x-icns": "icns", "image/vnd.adobe.photoshop": "psd",
            "image/x-canon-cr2": "cr2", "image/x-fuji-raf": "raf", "image/x-olympus-orf": "orf",
            "application/pdf": "pdf", "application/rtf": "rtf", "text/rtf": "rtf", "text/html": "html",
            "application/json": "json", "text/csv": "csv", "text/tab-separated-values": "tsv",
            "application/x-tar": "tar", "application/zip": "zip", "application/x-7z-compressed": "7z",
            "application/epub+zip": "epub", "application/msword": "doc", "application/vnd.ms-excel": "xls",
            "application/vnd.ms-outlook": "msg", "message/rfc822": "eml", "font/ttf": "ttf", "font/otf": "otf",
            "font/woff": "woff", "font/woff2": "woff2", "application/x-font-ttf": "ttf",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
            "application/vnd.oasis.opendocument.text": "odt", "application/x-subrip": "srt", "text/vtt": "vtt"
        ]
        if mime == "application/postscript" {
            return data.prefix(256).range(of: Data("EPSF-".utf8)) != nil ? "eps" : "postscript"
        }
        if let id = known[mime] { return id }
        if mime != "text/plain", let type = UTType(mimeType: mime),
           let format = catalog.formats.first(where: { $0.typeIdentifier == type.identifier }) {
            return format.id
        }
        if mime == "text/plain", let text = String(data: data, encoding: .utf8) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("#usda ") { return "usda" }
            if text.hasPrefix("ply\n") || text.hasPrefix("ply\r\n") { return "ply" }
            if text.hasPrefix("WEBVTT") { return "vtt" }
            if text.hasPrefix("; FBX ") { return "fbx" }
            if text.hasPrefix("[Script Info]") {
                return text.contains("[V4+ Styles]") || text.contains("ScriptType: v4.00+") ? "ass" : "ssa"
            }
            // These text formats have no unique signature. Keep a compatible filename hint.
            if let hint, ["txt", "markdown", "rst", "org", "mediawiki", "asciidoc", "typst", "latex", "man"].contains(hint) { return hint }
            if data.count == version.root.size {
                for id in ["toml", "yaml"] {
                    if let value = try? ConfigConverter.read(data, format: id) {
                        switch value {
                        case .object(let fields) where !fields.isEmpty: return id
                        case .array(let values) where !values.isEmpty: return id
                        default: break
                        }
                    }
                }
            }
            if let format = hintFormat, ["document", "config", "subtitle", "spreadsheet", "model"].contains(format.category) {
                return format.id
            }
            return "txt"
        }
        return nil
    }

    private static func archiveType(_ file: URL) throws -> String? {
        guard let reader = archive_read_new() else { throw ConversionError.message("The archive reader could not start.") }
        defer { archive_read_free(reader) }
        archive_read_support_filter_gzip(reader)
        archive_read_support_format_zip(reader)
        archive_read_support_format_tar(reader)
        archive_read_support_format_raw(reader)
        guard archive_read_open_filename(reader, file.path, 65_536) == ARCHIVE_OK else { return nil }
        var parts: Set<String> = []
        var mimetype: String?
        var finished = false
        for _ in 0..<4096 {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let result = archive_read_next_header(reader, &entry)
            if result == ARCHIVE_EOF { finished = true; break }
            guard result == ARCHIVE_OK, let entry else { return nil }
            let format = archive_format(reader) & ARCHIVE_FORMAT_BASE_MASK
            if format == ARCHIVE_FORMAT_TAR { return archive_filter_code(reader, 0) == ARCHIVE_FILTER_GZIP ? "tgz" : "tar" }
            if format == ARCHIVE_FORMAT_RAW {
                guard archive_filter_code(reader, 0) == ARCHIVE_FILTER_GZIP else { return nil }
                var bytes = [UInt8](repeating: 0, count: 65_536)
                let count = archive_read_data(reader, &bytes, bytes.count)
                guard count >= 0 else { return nil }
                return XMLRoot(Data(bytes.prefix(count))).name == "svg" ? "svgz" : "gzip"
            }
            guard format == ARCHIVE_FORMAT_ZIP, let pointer = archive_entry_pathname_utf8(entry) else { return nil }
            let name = String(cString: pointer)
            if ["[Content_Types].xml", "word/document.xml", "xl/workbook.xml", "ppt/presentation.xml", "content.xml", "META-INF/container.xml"].contains(name) {
                parts.insert(name)
            }
            if name == "mimetype", (0...4096).contains(archive_entry_size(entry)) {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = archive_read_data(reader, &bytes, bytes.count)
                if count >= 0 { mimetype = String(decoding: bytes.prefix(count), as: UTF8.self) }
            }
            guard archive_read_data_skip(reader) == ARCHIVE_OK else { return nil }
        }
        guard finished else { return nil }
        if mimetype == "application/epub+zip", parts.contains("META-INF/container.xml") { return "epub" }
        if mimetype == "application/vnd.oasis.opendocument.text", parts.contains("content.xml") { return "odt" }
        if parts.contains("[Content_Types].xml") {
            let candidates = [("word/document.xml", "docx"), ("xl/workbook.xml", "xlsx"), ("ppt/presentation.xml", "pptx")]
                .filter { parts.contains($0.0) }
            if candidates.count == 1 { return candidates[0].1 }
        }
        return "zip"
    }
}

private final class XMLRoot: NSObject, XMLParserDelegate {
    var name: String?
    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        parser.parse()
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        name = elementName
        parser.abortParsing()
    }
}
