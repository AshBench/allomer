import Foundation

public struct SubtitleOptions: Codable, Equatable, Sendable {
    public var frameRate = 25.0
    public var sourceFrameRate: Double?
    public var removeFormatting = false
    /// One-based subtitle track number. Missing means the first subtitle track.
    public var embeddedTrack: Int?
    public init() {}

    private enum CodingKeys: String, CodingKey { case frameRate, sourceFrameRate, removeFormatting, embeddedTrack }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        frameRate = try values.decodeIfPresent(Double.self, forKey: .frameRate) ?? 25
        sourceFrameRate = try values.decodeIfPresent(Double.self, forKey: .sourceFrameRate)
        removeFormatting = try values.decodeIfPresent(Bool.self, forKey: .removeFormatting) ?? false
        embeddedTrack = try values.decodeIfPresent(Int.self, forKey: .embeddedTrack)
    }
}

public struct EmbeddedSubtitleTrack: Identifiable, Equatable, Sendable {
    public let id: Int
    public let codec: String
    public let language: String?
    public let title: String?
}

struct SubtitleCue: Equatable {
    let start: Int64
    let end: Int64
    let text: String
}

enum SubtitleConverter {
    static let formats: Set<String> = ["srt", "vtt", "ass", "ssa", "sbv", "microdvd"]
    private static let demuxers = ["srt": "srt", "vtt": "webvtt", "ass": "ass", "ssa": "ass",
                                   "sbv": "subviewer", "microdvd": "microdvd"]

    private static func validate(_ options: SubtitleOptions) throws {
        guard options.frameRate.isFinite, (4...99).contains(options.frameRate),
              options.sourceFrameRate.map({ $0.isFinite && (1...240).contains($0) }) ?? true else {
            throw ConversionError.message("Use an output frame rate between 4 and 99, and a source frame rate between 1 and 240.")
        }
        guard options.embeddedTrack.map({ (1...256).contains($0) }) ?? true else {
            throw ConversionError.message("Subtitle track numbers must be between 1 and 256.")
        }
    }

    static func tracks(in info: MediaInfo) throws -> [EmbeddedSubtitleTrack] {
        let streams = info.streams.filter { $0.codec_type == "subtitle" }
        guard streams.count <= 256 else { throw ConversionError.message("The video has more than 256 subtitle tracks.") }
        return streams.enumerated().map { index, stream in
            EmbeddedSubtitleTrack(id: index + 1, codec: stream.codec_name ?? "unknown",
                language: stream.tags?["language"], title: stream.tags?["title"])
        }
    }

    static func extract(_ input: URL, to output: URL, target: FileFormat, media: MediaConverter,
                        catalog: FormatCatalog, options: SubtitleOptions, ocrLanguage: String = "auto") throws {
        try validate(options)
        let work = output.deletingLastPathComponent()
        let info = try media.inspect(input, work: work)
        let tracks = try tracks(in: info)
        guard !tracks.isEmpty else { throw ConversionError.message("The file has no embedded subtitle tracks.") }
        let number = options.embeddedTrack ?? 1
        guard let track = tracks.first(where: { $0.id == number }) else {
            throw ConversionError.message("Subtitle track \(number) is unavailable. This file has \(tracks.count) subtitle tracks.")
        }
        let bitmap = ["dvd_subtitle", "dvb_subtitle", "hdmv_pgs_subtitle", "xsub"].contains(track.codec)
        let format = ["ass": "ass", "ssa": "ass", "webvtt": "vtt"][track.codec] ?? "srt"
        let prepared = work.appendingPathComponent("embedded-\(UUID().uuidString).\(format)")
        defer { try? FileManager.default.removeItem(at: prepared) }
        if bitmap {
            try ExternalTool.run(media.ffmpeg.deletingLastPathComponent().appendingPathComponent("nativeguard"),
                arguments: [input.path, work.path, "subtitle", input.path, prepared.lastPathComponent, String(number), ocrLanguage],
                workDirectory: work, workDirectoryByteLimit: 80 * 1024 * 1024)
        } else {
            var args = ["-hide_banner", "-nostdin", "-v", "error", "-xerror", "-n", "-max_alloc", "67108864",
                        "-threads", "1", "-protocol_whitelist", "file,pipe", "-copyts", "-start_at_zero"]
            if info.format.format_name == "mpegts" { args += ["-f", "mpegts"] }
            args += ["-i", input.path, "-map", "0:s:\(number - 1)", "-an", "-vn", "-dn", "-map_metadata", "-1",
                     "-c:s", ["ass", "ssa", "webvtt", "subrip"].contains(track.codec) ? "copy" : "srt",
                     "-f", demuxers[format]!, prepared.path]
            try ExternalTool.run(media.ffmpeg, arguments: args, workDirectory: work, workDirectoryByteLimit: 80 * 1024 * 1024)
        }
        guard let source = catalog.format(forExtension: format) else { throw ConversionError.message("The subtitle format is missing.") }
        try convert(prepared, to: output, from: source, to: target, tool: media.ffmpeg, options: options)
    }

    static func convert(_ input: URL, to output: URL, from source: FileFormat, to target: FileFormat,
                        tool: URL, options: SubtitleOptions) throws {
        guard formats.contains(source.id), formats.contains(target.id) else {
            throw ConversionError.message("This subtitle conversion is not supported.")
        }
        try validate(options)
        let work = output.deletingLastPathComponent()
        let normalized = work.appendingPathComponent("subtitles-\(UUID().uuidString).srt")
        let check = work.appendingPathComponent("check-\(UUID().uuidString).srt")
        defer {
            try? FileManager.default.removeItem(at: normalized)
            try? FileManager.default.removeItem(at: check)
        }
        let sourceText = try readText(input)
        if source.id == "microdvd", !hasFrameRateHeader(sourceText), options.sourceFrameRate == nil {
            throw ConversionError.message("This MicroDVD file has no frame rate header. Set its source frame rate in Settings.")
        }
        if source.id == "srt" { _ = try parseSRT(sourceText) }
        try transcode(input, to: normalized, source: source.id, target: "srt", tool: tool,
                      frameRate: options.sourceFrameRate, work: work)
        var cues = try parseSRT(readText(normalized))
        if options.removeFormatting {
            cues = cues.map { SubtitleCue(start: $0.start, end: $0.end, text: plainText($0.text)) }
            try writeSRT(cues).write(to: normalized, atomically: false, encoding: .utf8)
        }
        if target.id == "sbv" || target.id == "microdvd" {
            guard options.removeFormatting || cues.allSatisfy({ plainText($0.text) == $0.text }) else {
                throw ConversionError.message("This output cannot keep the subtitle formatting. Enable Remove subtitle formatting to convert it.")
            }
            if target.id == "sbv" {
                let text = cues.map { "\(timestamp($0.start, separator: ".")),\(timestamp($0.end, separator: "."))\n\($0.text)" }
                    .joined(separator: "\n\n") + "\n"
                try text.write(to: output, atomically: false, encoding: .utf8)
            } else {
                guard !cues.contains(where: { $0.text.contains("|") || $0.text.contains("{") || $0.text.contains("}") }) else {
                    throw ConversionError.message("MicroDVD cannot represent these literal pipe or brace characters safely.")
                }
                let lines = cues.map { cue in
                    let start = Int64((Double(cue.start) * options.frameRate / 1000).rounded())
                    let end = max(start + 1, Int64((Double(cue.end) * options.frameRate / 1000).rounded()))
                    return "{\(start)}{\(end)}" + cue.text.replacingOccurrences(of: "\n", with: "|")
                }
                try ("{1}{1}\(options.frameRate)\n" + lines.joined(separator: "\n") + "\n")
                    .write(to: output, atomically: false, encoding: .utf8)
            }
        } else {
            try transcode(options.removeFormatting ? normalized : input, to: output,
                source: options.removeFormatting ? "srt" : source.id, target: target.id, tool: tool,
                frameRate: options.sourceFrameRate, work: work)
            if target.id == "ssa" {
                try ssaDocument(readText(output)).write(to: output, atomically: false, encoding: .utf8)
            }
        }
        try transcode(output, to: check, source: target.id, target: "srt", tool: tool,
                      frameRate: options.frameRate, work: work)
        let decoded = try parseSRT(readText(check))
        let tolerance: Int64 = target.id == "microdvd" ? Int64(ceil(1000 / options.frameRate)) + 1 : 10
        guard decoded.count == cues.count, zip(cues, decoded).allSatisfy({ before, after in
            abs(before.start - after.start) <= tolerance && abs(before.end - after.end) <= tolerance
                && plainText(before.text) == plainText(after.text)
        }) else {
            throw ConversionError.message("The subtitle output did not preserve cue text and timing.")
        }
    }

    private static func transcode(_ input: URL, to output: URL, source: String, target: String,
                                  tool: URL, frameRate: Double? = nil, work: URL) throws {
        var args = ["-nostdin", "-v", "error", "-xerror", "-n", "-max_alloc", "67108864", "-threads", "1",
                    "-protocol_whitelist", "file,pipe", "-f", demuxers[source]!]
        if source == "microdvd", let frameRate { args += ["-subfps", String(frameRate)] }
        args += ["-i", input.path, "-map", "0:s:0", "-c:s", source == target ? "copy" : (target == "vtt" ? "webvtt" : (["ass", "ssa"].contains(target) ? "ass" : "srt")),
                 "-f", target == "vtt" ? "webvtt" : (["ass", "ssa"].contains(target) ? "ass" : "srt"), output.path]
        try ExternalTool.run(tool, arguments: args, workDirectory: work, workDirectoryByteLimit: 80 * 1024 * 1024)
    }

    static func parseSRT(_ text: String) throws -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}\n \t"))
        let pattern = try NSRegularExpression(pattern: #"^(\d{1,6}):(\d{2}):(\d{2}),(\d{3})\s+-->\s+(\d{1,6}):(\d{2}):(\d{2}),(\d{3})$"#)
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") where !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var lines = block.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
            if let first = lines.first, Int(first) != nil { lines.removeFirst() }
            guard let timing = lines.first,
                  let match = pattern.firstMatch(in: timing, range: NSRange(timing.startIndex..., in: timing)), lines.count >= 2 else {
                throw ConversionError.message("The subtitle file has an invalid cue.")
            }
            let fields = (1...8).map { Int64((timing as NSString).substring(with: match.range(at: $0)))! }
            guard fields[1] < 60, fields[2] < 60, fields[5] < 60, fields[6] < 60 else {
                throw ConversionError.message("The subtitle file has an invalid timestamp.")
            }
            let start = ((fields[0] * 60 + fields[1]) * 60 + fields[2]) * 1000 + fields[3]
            let end = ((fields[4] * 60 + fields[5]) * 60 + fields[6]) * 1000 + fields[7]
            guard end > start else { throw ConversionError.message("Subtitle cues must end after they start.") }
            cues.append(SubtitleCue(start: start, end: end, text: lines.dropFirst().joined(separator: "\n")))
            guard cues.count <= 100_000 else { throw ConversionError.message("The subtitle file exceeds 100,000 cues.") }
        }
        guard !cues.isEmpty else { throw ConversionError.message("The file contains no subtitle cues.") }
        return cues
    }

    private static func writeSRT(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    private static func timestamp(_ milliseconds: Int64, separator: String = ",") -> String {
        String(format: "%02lld:%02lld:%02lld%@%03lld", milliseconds / 3_600_000,
               milliseconds / 60_000 % 60, milliseconds / 1000 % 60, separator, milliseconds % 1000)
    }

    private static func readText(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 16 * 1024 * 1024 else { throw ConversionError.message("Subtitle text exceeds 16 MiB.") }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw ConversionError.message("Subtitle input must be UTF-8 text.")
        }
        return text
    }

    private static func plainText(_ text: String) -> String {
        text.replacingOccurrences(of: #"</?(?:b|i|u|s|font)(?:\s[^>]*)?>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\an[1-9]\}"#, with: "", options: .regularExpression)
    }

    private static func hasFrameRateHeader(_ text: String) -> Bool {
        text.range(of: #"(?m)^\{[01]\}\{[01]?\}[0-9]+(?:\.[0-9]+)?\s*$"#, options: .regularExpression) != nil
    }

    /// Convert the generated ASS default style to the older SSA field layout.
    private static func ssaDocument(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            if line.hasPrefix("ScriptType:") { return "ScriptType: v4.00" }
            if line == "[V4+ Styles]" { return "[V4 Styles]" }
            if line.hasPrefix("Format: Name, Fontname") {
                return "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding"
            }
            if line.hasPrefix("Style: ") {
                let fields = line.dropFirst(7).split(separator: ",", omittingEmptySubsequences: false)
                if fields.count == 23 {
                    var values = [0, 1, 2, 3, 4, 5, 6, 7, 8, 15, 16, 17, 18, 19, 20, 21].map { String(fields[$0]) }
                    let alignment = Int(values[12]) ?? 2
                    values[12] = String([4: 9, 5: 10, 6: 11, 7: 5, 8: 6, 9: 7][alignment] ?? alignment)
                    return "Style: " + (values + ["0", String(fields[22])]).joined(separator: ",")
                }
            }
            if line.hasPrefix("Format: Layer,") { return line.replacingOccurrences(of: "Format: Layer,", with: "Format: Marked,") }
            if line.hasPrefix("Dialogue: "), !line.hasPrefix("Dialogue: Marked=") {
                return "Dialogue: Marked=" + line.dropFirst(10)
            }
            return line
        }.joined(separator: "\n")
    }
}
