import Foundation
import PDFKit

enum OCRConverter {
    static let outputs: Set<String> = ["txt", "html", "pdf"]

    static func preparePDF(_ input: URL, pages: [Int], work: URL, tools: URL, language: String = "auto") throws -> URL {
        guard let source = PDFDocument(url: input) else { throw ConversionError.message("The PDF text could not be read.") }
        var scanned: [Int] = []
        for number in pages {
            try Task.checkCancellation()
            if autoreleasepool(invoking: { (source.page(at: number - 1)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                scanned.append(number)
            }
        }
        if scanned.isEmpty { return input }
        let identifier = UUID().uuidString
        let overlay = work.appendingPathComponent("ocr-layer-\(identifier).pdf")
        let output = work.appendingPathComponent("ocr-prepared-\(identifier).pdf")
        defer { try? FileManager.default.removeItem(at: overlay) }
        do {
            try ExternalTool.run(tools.appendingPathComponent("nativeguard"),
                arguments: [input.path, work.path, "pdf-overlay", input.path, overlay.lastPathComponent,
                            scanned.map(String.init).joined(separator: ","), language], workDirectory: work)
            try addTextLayer(input, overlay: overlay, to: output, pages: pages, tools: tools)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func addTextLayer(_ input: URL, overlay: URL, to output: URL, pages: [Int], tools: URL) throws {
        let work = output.deletingLastPathComponent()
        try ExternalTool.run(tools.appendingPathComponent("pdfguard"),
            arguments: [input.path, work.path, "overlay", input.path, overlay.path, output.lastPathComponent], workDirectory: work)
        let actualSizes = try PostScriptConverter.pageSizes(output)
        let expectedSizes = try PostScriptConverter.pageSizes(input)
        guard actualSizes == expectedSizes, let source = PDFDocument(url: input),
              let combined = PDFDocument(url: output), let layer = PDFDocument(url: overlay) else {
            throw ConversionError.message("The searchable PDF changed the page count or bounds.")
        }
        for number in pages {
            try Task.checkCancellation()
            let kept = autoreleasepool {
                var expected: [UInt32: Int] = [:], actual: [UInt32: Int] = [:]
                addPDFCharacters((source.page(at: number - 1)?.string ?? "") + (layer.page(at: number - 1)?.string ?? ""), to: &expected)
                addPDFCharacters(combined.page(at: number - 1)?.string ?? "", to: &actual)
                return expected.allSatisfy { actual[$0.key, default: 0] >= $0.value }
            }
            guard kept else { throw ConversionError.message("The searchable PDF did not preserve its text layer.") }
        }
    }

    static func convert(_ input: URL, to output: URL, format: FileFormat, tools: URL,
                        language: String, options: ImageOptions) throws {
        let version = try FileVersion(input)
        let work = output.deletingLastPathComponent()
        if format.id == "pdf" {
            let identifier = UUID().uuidString
            let base = work.appendingPathComponent("ocr-image-\(identifier).pdf")
            let overlay = work.appendingPathComponent("ocr-layer-\(identifier).pdf")
            defer {
                try? FileManager.default.removeItem(at: base)
                try? FileManager.default.removeItem(at: overlay)
            }
            try ExternalTool.run(tools.appendingPathComponent("nativeguard"),
                arguments: [input.path, work.path, "image", input.path, overlay.lastPathComponent, "pdf-layer", language],
                workDirectory: work)
            try ImageConverter.convert(input, to: base, format: format, options: options)
            try addTextLayer(base, overlay: overlay, to: output, pages: [1], tools: tools)
        } else {
            try ExternalTool.run(tools.appendingPathComponent("nativeguard"),
                arguments: [input.path, work.path, "image", input.path, output.lastPathComponent, format.id, language],
                workDirectory: work)
        }
        let size = try FileVersion(output).size
        guard size > 0, size <= 512 * 1024 * 1024 else {
            throw ConversionError.message("The OCR output is empty or too large.")
        }
        if format.id == "pdf" {
            guard try PostScriptConverter.pageSizes(output).count == 1 else {
                throw ConversionError.message("The OCR output must contain one PDF page.")
            }
        } else {
            try DocumentConverter.validate(output, format: format.id)
        }
        guard try FileVersion(input) == version else {
            throw ConversionError.message("The image changed during text recognition.")
        }
    }
}
