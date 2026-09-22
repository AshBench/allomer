import CoreGraphics
import Foundation

public struct PostScriptOptions: Codable, Equatable, Sendable {
    public enum PDFPreset: String, Codable, CaseIterable, Sendable {
        case `default`, screen, ebook, printer, prepress
    }
    public var languageLevel = 3
    public var epsPage = 1
    public var cropEPS = true
    public var pdfPreset = PDFPreset.prepress
    public init() {}

    private enum CodingKeys: String, CodingKey { case languageLevel, epsPage, cropEPS, pdfPreset }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        languageLevel = try values.decodeIfPresent(Int.self, forKey: .languageLevel) ?? languageLevel
        epsPage = try values.decodeIfPresent(Int.self, forKey: .epsPage) ?? epsPage
        cropEPS = try values.decodeIfPresent(Bool.self, forKey: .cropEPS) ?? cropEPS
        pdfPreset = try values.decodeIfPresent(PDFPreset.self, forKey: .pdfPreset) ?? pdfPreset
    }
}

enum PostScriptConverter {
    static let routes: [String: Set<String>] = ["pdf": ["postscript", "eps"], "postscript": ["pdf"], "eps": ["pdf"]]
    static let outputs: Set<String> = ["pdf", "postscript", "eps"]
    static let byteLimit = 512 * 1024 * 1024

    static func resources(tools: URL) -> URL {
        tools.appendingPathComponent("psguard").resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Poppler")
    }

    static func convert(_ input: URL, to output: URL, from source: FileFormat, to target: FileFormat,
                        tools: URL, options: PostScriptOptions) throws {
        guard routes[source.id]?.contains(target.id) == true,
              [2, 3].contains(options.languageLevel), (1...10_000).contains(options.epsPage) else {
            throw ConversionError.message("The PostScript format, language level, or EPS page is invalid.")
        }
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= byteLimit else {
            throw ConversionError.message("PostScript and PDF input must be between 1 byte and 512 MiB.")
        }
        var expected: [CGSize] = []
        var arguments: [String] = []
        let tool = tools.appendingPathComponent("postscript")
        let work = output.deletingLastPathComponent()
        let normalized = work.appendingPathComponent("scaled-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: normalized) }
        if source.id == "pdf" {
            let geometry = try pageGeometry(input)
            expected = geometry.sizes
            var prepared = input
            if options.languageLevel == 2 || geometry.scaled {
                // Check the original drawing commands before the PDF interpreter can repair them.
                try ExternalTool.run(tools.appendingPathComponent("psguard"), arguments:
                    [input.path, work.path, resources(tools: tools).path, "-validate-only", input.path, "-"],
                    workDirectory: work)
            }
            if options.languageLevel == 3, geometry.scaled {
                // PDF 1.5 expresses the physical page size without UserUnit, which this writer ignores.
                try run(input, to: normalized, tool: tool, device: "pdfwrite",
                        arguments: ["-dCompatibilityLevel=1.5", "-dUseCropBox"])
                let normalizedGeometry = try pageGeometry(normalized)
                guard !normalizedGeometry.scaled, sameSizes(expected, normalizedGeometry.sizes) else {
                    throw ConversionError.message("The PDF coordinate scale could not be preserved.")
                }
                prepared = normalized
            }
            if target.id == "eps" {
                guard options.epsPage <= expected.count else {
                    throw ConversionError.message("The selected EPS page is outside the PDF.")
                }
                arguments += ["-eps", "-f", String(options.epsPage), "-l", String(options.epsPage)]
                expected = [expected[options.epsPage - 1]]
            }
            if options.languageLevel == 2 {
                try run(input, to: output, tool: tool, device: target.id == "eps" ? "eps2write" : "ps2write",
                        arguments: ["-dUseCropBox"] + (target.id == "eps"
                            ? ["-dFirstPage=\(options.epsPage)", "-dLastPage=\(options.epsPage)"] : []))
            } else {
                try ExternalTool.run(tools.appendingPathComponent("psguard"), arguments:
                    [prepared.path, work.path, resources(tools: tools).path, "-level3",
                     "-origpagesizes", "-noshrink", "-nocenter", "-r", "300", "-aaRaster", "yes"]
                    + arguments + [prepared.path, "-"], workDirectory: work, outputFile: output, outputLimit: byteLimit)
            }
        } else {
            let file = try FileHandle(forReadingFrom: input)
            defer { try? file.close() }
            guard try file.read(upToCount: 2) == Data("%!".utf8) else {
                throw ConversionError.message("The input does not have a PostScript header.")
            }
            arguments += ["-dPDFSETTINGS=/\(options.pdfPreset.rawValue)"]
            if source.id == "eps", options.cropEPS { arguments += ["-dEPSCrop"] }
            try run(input, to: output, tool: tool, device: "pdfwrite", arguments: arguments)
        }
        var validationPDF = output
        let restored = output.deletingLastPathComponent().appendingPathComponent("check-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: restored) }
        if target.id != "pdf" {
            let file = try FileHandle(forReadingFrom: output)
            defer { try? file.close() }
            let header = String(decoding: try file.read(upToCount: 64) ?? Data(), as: UTF8.self)
            guard header.hasPrefix("%!PS-Adobe-"), target.id != "eps" || header.contains("EPSF-") else {
                throw ConversionError.message("The PostScript writer produced an invalid header.")
            }
            try run(output, to: restored, tool: tool, device: "pdfwrite",
                    arguments: target.id == "eps" ? ["-dEPSCrop"] : [])
            validationPDF = restored
        }
        let actual = try pageSizes(validationPDF)
        if !expected.isEmpty {
            guard actual.count == expected.count else {
                throw ConversionError.message("The PostScript output changed the number of pages.")
            }
            // EPS bounds may trim unused margins. Ordinary PostScript must keep the visible page size.
            if target.id == "postscript" {
                guard sameSizes(expected, actual) else {
                    throw ConversionError.message("The PostScript output changed the page size.")
                }
            }
        }
        guard try FileVersion(input) == version else {
            throw ConversionError.message("The source changed during PostScript conversion.")
        }
    }

    private static func sameSizes(_ left: [CGSize], _ right: [CGSize]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy {
            abs($0.width - $1.width) < 1 && abs($0.height - $1.height) < 1
        }
    }

    private static func run(_ input: URL, to output: URL, tool: URL, device: String, arguments: [String]) throws {
        let work = output.deletingLastPathComponent()
        try ExternalTool.run(tool, arguments: [input.path, work.path, "-q", "-dSAFER", "-dBATCH", "-dNOPAUSE",
            "-dPDFSTOPONERROR", "-dPDFSTOPONWARNING", "-dPDFNOCIDFALLBACK", "-dAutoRotatePages=/None", "-dNumRenderingThreads=1",
            "-dMaxBitmap=16777216", "-dBufferSpace=16777216", "-sDEVICE=\(device)",
            "-sstdout=%stderr", "-sOutputFile=%stdout"] + arguments + ["-f", input.path],
            workDirectory: work, outputFile: output, outputLimit: byteLimit)
        let size = try FileVersion(output).size
        guard size > 0, size <= byteLimit else {
            throw ConversionError.message("The PostScript writer produced an empty or oversized output.")
        }
    }

    static func pageSizes(_ file: URL) throws -> [CGSize] {
        try pageGeometry(file).sizes
    }

    private static func pageGeometry(_ file: URL) throws -> (sizes: [CGSize], scaled: Bool) {
        guard let document = CGPDFDocument(file as CFURL), !document.isEncrypted,
              (1...10_000).contains(document.numberOfPages) else {
            throw ConversionError.message("The PDF is unreadable, encrypted, empty, or exceeds 10,000 pages.")
        }
        var scaled = false
        let sizes = try (1...document.numberOfPages).map { index in
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw ConversionError.message("A PDF page could not be read.")
            }
            var unit: CGPDFReal = 1
            var value: CGPDFObjectRef?
            if let dictionary = page.dictionary, CGPDFDictionaryGetObject(dictionary, "UserUnit", &value) {
                guard CGPDFDictionaryGetNumber(dictionary, "UserUnit", &unit), unit.isFinite, unit > 0, unit <= 75_000 else {
                    throw ConversionError.message("A PDF page has an invalid coordinate scale.")
                }
            }
            scaled = scaled || unit != 1
            let visible = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
            let size = CGSize(width: visible.width * unit, height: visible.height * unit)
            guard size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0, size.width <= 144_000, size.height <= 144_000,
                  page.rotationAngle % 90 == 0 else {
                throw ConversionError.message("A PDF page has invalid or excessive dimensions.")
            }
            return page.rotationAngle % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
        }
        return (sizes, scaled)
    }
}
