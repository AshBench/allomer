import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Vision

enum Failure: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case let .message(text): return text } }
}

func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

func characters(_ text: String) -> [UInt32: Int] {
    var result: [UInt32: Int] = [:]
    for value in text.decomposedStringWithCompatibilityMapping.unicodeScalars
        where !CharacterSet.whitespacesAndNewlines.contains(value) {
        result[value.value, default: 0] += 1
    }
    return result
}

func imageTransform(_ orientation: CGImagePropertyOrientation) -> CGAffineTransform {
    switch orientation {
    case .up: return .identity
    case .upMirrored: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)
    case .down: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
    case .downMirrored: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
    case .leftMirrored: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1, ty: 1)
    case .right: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
    case .rightMirrored: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
    case .left: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
    @unknown default: return .identity
    }
}

typealias OCRLine = (text: VNRecognizedText, bounds: VNRectangleObservation)

func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation = .up, language: String) throws -> [OCRLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = language == "auto"
    if language != "auto" {
        guard try request.supportedRecognitionLanguages().contains(language) else {
            throw Failure.message("The selected OCR language is not supported by this Mac.")
        }
        request.recognitionLanguages = [language]
    }
    request.usesLanguageCorrection = true
    request.preferBackgroundProcessing = true
    try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
    let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
        guard let text = observation.topCandidates(1).first, !text.string.isEmpty else { return nil }
        let bounds = (try? text.boundingBox(for: text.string.startIndex..<text.string.endIndex)) ?? observation
        return (text, bounds)
    }
    guard lines.count <= 100_000 else { throw Failure.message("The OCR result has too many text lines.") }
    let text = lines.map { $0.text.string }.joined(separator: "\n")
    guard text.utf8.count <= 16 * 1024 * 1024,
          !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else {
        throw Failure.message("The OCR result is too large or contains invalid text.")
    }
    return lines
}

func drawText(_ lines: [OCRLine], in context: CGContext, transform: CGAffineTransform) {
    context.setTextDrawingMode(.invisible)
    for (text, bounds) in lines {
        let attributed = NSAttributedString(string: text.string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 1, nil)])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        guard advance > 0, ascent + descent > 0 else { continue }
        let left = bounds.bottomLeft.applying(transform), right = bounds.bottomRight.applying(transform)
        let top = bounds.topLeft.applying(transform)
        context.saveGState()
        context.concatenate(CGAffineTransform(
            a: (right.x - left.x) / advance, b: (right.y - left.y) / advance,
            c: (top.x - left.x) / (ascent + descent), d: (top.y - left.y) / (ascent + descent),
            tx: left.x, ty: left.y))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

func pdfTextLayer(_ input: URL, to output: URL, pages: String, language: String) throws {
    let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 512 * 1024 * 1024,
          let document = CGPDFDocument(input as CFURL), !document.isEncrypted,
          (1...10_000).contains(document.numberOfPages), let reader = PDFDocument(url: input) else {
        throw Failure.message("OCR needs a readable, unencrypted PDF up to 512 MiB and 10,000 pages.")
    }
    let numbers = pages.split(separator: ",", omittingEmptySubsequences: false)
    let selected = Set(numbers.compactMap { Int($0) })
    guard numbers.count <= 10_000, selected.count == numbers.count,
          selected.allSatisfy({ (1...document.numberOfPages).contains($0) }),
          let context = CGContext(output as CFURL, mediaBox: nil, nil) else {
        throw Failure.message("The OCR page selection or output path is invalid.")
    }
    var expected: [UInt32: Int] = [:]
    for number in 1...document.numberOfPages {
        try autoreleasepool {
            guard let page = document.page(at: number) else { throw Failure.message("An OCR page could not be read.") }
            var media = page.getBoxRect(.mediaBox)
            let crop = page.getBoxRect(.cropBox).intersection(media)
            guard [media.minX, media.minY, media.width, media.height, crop.width, crop.height].allSatisfy(\.isFinite),
                  media.width > 0, media.height > 0, crop.width > 0, crop.height > 0,
                  media.width <= 144_000, media.height <= 144_000 else {
                throw Failure.message("An OCR page has invalid bounds.")
            }
            context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            if selected.contains(number), (reader.page(at: number - 1)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var width = crop.width, height = crop.height
                if abs(page.rotationAngle) % 180 == 90 { swap(&width, &height) }
                let scale = min(300.0 / 72, sqrt(31_000_000 / (width * height)))
                let pixels = CGRect(x: 0, y: 0, width: ceil(width * scale), height: ceil(height * scale))
                guard pixels.width >= 1, pixels.height >= 1, pixels.width <= 100_000, pixels.height <= 100_000,
                      pixels.width * pixels.height <= 32_000_000,
                      let bitmap = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw Failure.message("The PDF OCR render buffer could not be created within its size limit.")
                }
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                bitmap.fill(pixels)
                let transform = page.getDrawingTransform(.cropBox, rect: pixels, rotate: 0, preserveAspectRatio: true)
                bitmap.concatenate(transform)
                bitmap.drawPDFPage(page)
                guard let image = bitmap.makeImage() else { throw Failure.message("The OCR page could not be rendered.") }
                let lines = try recognize(image, language: language)
                drawText(lines, in: context, transform: CGAffineTransform(scaleX: pixels.width, y: pixels.height).concatenating(transform.inverted()))
                for (scalar, count) in characters(lines.map { $0.text.string }.joined(separator: "\n")) {
                    expected[scalar, default: 0] += count
                }
            }
            context.endPDFPage()
        }
    }
    context.closePDF()
    guard let layer = PDFDocument(url: output), layer.pageCount == document.numberOfPages else {
        throw Failure.message("The PDF text layer has an incorrect page count.")
    }
    var actual: [UInt32: Int] = [:]
    for index in 0..<layer.pageCount {
        autoreleasepool {
            for (scalar, count) in characters(layer.page(at: index)?.string ?? "") { actual[scalar, default: 0] += count }
        }
    }
    guard expected.allSatisfy({ actual[$0.key, default: 0] >= $0.value }) else {
        throw Failure.message("The PDF text layer did not preserve the recognized text.")
    }
}

func convertImage(_ input: URL, to output: URL, format: String, language: String) throws {
    let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 512 * 1024 * 1024,
          let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetType(source) as String? != "com.adobe.pdf", CGImageSourceGetCount(source) == 1,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, width <= 100_000, height <= 100_000, width <= 32_000_000 / height else {
        throw Failure.message("OCR needs a single image up to 32 million pixels and 512 MiB.")
    }
    let orientation = CGImagePropertyOrientation(rawValue: (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1) ?? .up
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw Failure.message("The OCR image could not be decoded.")
    }
    let recognized = try recognize(image, orientation: orientation, language: language)
    let text = recognized.map { $0.0.string }.joined(separator: "\n")
    if ["txt", "html"].contains(format), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw Failure.message("No readable text was found in the image.")
    }
    if format == "txt" {
        try (text + "\n").write(to: output, atomically: false, encoding: .utf8)
    } else if format == "html" {
        let paragraphs = recognized.map { "<p>" + escapeHTML($0.0.string) + "</p>" }.joined(separator: "\n")
        try ("<!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><meta charset=\"utf-8\"/></head><body>\n"
            + paragraphs + "\n</body></html>\n").write(to: output, atomically: false, encoding: .utf8)
    } else {
        func dpi(_ key: CFString) -> Double {
            let value = properties[key] as? Double ?? 72
            return value.isFinite && (1...12_000).contains(value) ? value : 72
        }
        var pageWidth = Double(width) * 72 / dpi(kCGImagePropertyDPIWidth)
        var pageHeight = Double(height) * 72 / dpi(kCGImagePropertyDPIHeight)
        if orientation.rawValue >= 5 { swap(&pageWidth, &pageHeight) }
        guard pageWidth <= 144_000, pageHeight <= 144_000 else {
            throw Failure.message("The image's physical page size is too large.")
        }
        var page = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let context = CGContext(output as CFURL, mediaBox: &page, nil) else {
            throw Failure.message("The searchable PDF could not be opened.")
        }
        context.beginPDFPage(nil)
        if format == "pdf" {
            context.saveGState()
            context.scaleBy(x: page.width, y: page.height)
            context.concatenate(imageTransform(orientation))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            context.restoreGState()
        }
        drawText(recognized, in: context, transform: CGAffineTransform(scaleX: page.width, y: page.height))
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(url: output), document.pageCount == 1,
              let checkedPage = document.page(at: 0) else {
            throw Failure.message("The searchable PDF could not be read back.")
        }
        let expected = characters(text), checked = characters(checkedPage.string ?? "")
        guard expected.allSatisfy({ checked[$0.key, default: 0] >= $0.value }) else {
            throw Failure.message("The searchable PDF did not preserve the recognized text.")
        }
    }
}

func convertDocument(_ input: URL, to output: URL, source: String, target: String) throws {
    guard (source == "txt" && ["rtf", "doc"].contains(target)) || (source == "rtf" && target == "doc")
            || (source == "doc" && ["html", "rtf", "txt"].contains(target)) else {
        throw Failure.message("This native document route is not supported.")
    }
    let file = try FileHandle(forReadingFrom: input)
    defer { try? file.close() }
    let data = try file.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data()
    guard !data.isEmpty, data.count <= 64 * 1024 * 1024 else {
        throw Failure.message("Native document input must be nonempty and up to 64 MiB.")
    }
    if source == "rtf" {
        let controls = try NSRegularExpression(pattern: #"(?:^|[^\\])(?:\\\\)*\\(?:pict|object|shp|shpinst|NeXTGraphic|bin|footnote|annotation|header[flr]?|footer[flr]?)(?![a-zA-Z])"#)
        let text = String(decoding: data, as: UTF8.self)
        guard controls.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil else {
            throw Failure.message("This Word writer cannot keep pictures, embedded data, notes, or page headers from RTF. The source was kept.")
        }
    }
    let sourceType: NSAttributedString.DocumentType = source == "txt" ? .plain : source == "doc" ? .docFormat : .rtf
    let targetType: NSAttributedString.DocumentType = switch target {
    case "doc": .docFormat
    case "html": .html
    case "txt": .plain
    default: .rtf
    }
    var attributes: NSDictionary?
    let document = try NSAttributedString(data: data, options: [.documentType: sourceType], documentAttributes: &attributes)
    guard document.length <= 8_000_000 else { throw Failure.message("The document exceeds eight million text characters.") }
    let range = NSRange(location: 0, length: document.length)
    var runs = 0, hasAttachment = false, hasLink = false
    document.enumerateAttributes(in: range) { values, _, stop in
        runs += 1
        hasAttachment = hasAttachment || values[.attachment] != nil
        hasLink = hasLink || values[.link] != nil
        if runs > 100_000 || hasAttachment || (target == "doc" && hasLink) { stop.pointee = true }
    }
    guard runs <= 100_000, !hasAttachment, target != "doc" || !hasLink else {
        throw Failure.message("This document route cannot keep attachments, DOC-output links, or more than 100,000 formatting runs. The source was kept.")
    }
    var properties = attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
    properties[.documentType] = targetType
    properties[.characterEncoding] = String.Encoding.utf8.rawValue
    var encoded = target == "txt" ? Data(document.string.utf8)
        : try document.data(from: range, documentAttributes: properties)
    if target == "doc" { encoded = try nativeWordContainer(encoded, text: document.string) }
    guard !encoded.isEmpty, encoded.count <= 512 * 1024 * 1024,
          target != "doc" || encoded.starts(with: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) else {
        throw Failure.message("The native document output is empty, too large, or has the wrong format.")
    }
    if ["html", "rtf"].contains(target) {
        let checked = try NSAttributedString(data: encoded, options: [.documentType: targetType], documentAttributes: nil)
        let before = normalizedDocumentText(document.string), after = normalizedDocumentText(checked.string)
        guard after == before || after == before + "\n" else {
            throw Failure.message("The native document output changed the text or paragraph order.")
        }
    }
    try encoded.write(to: output, options: .withoutOverwriting)
}

do {
    let args = CommandLine.arguments
    guard (5...6).contains(args.count), args[1] == "pdf-overlay"
            || (args[1] == "image" && ["txt", "html", "pdf", "pdf-layer"].contains(args[4]))
            || args[1] == "subtitle"
            || (args[1] == "document" && args.count == 6) else {
        throw Failure.message("Expected: image INPUT OUTPUT FORMAT [LANGUAGE], pdf-overlay INPUT OUTPUT PAGES [LANGUAGE], subtitle INPUT OUTPUT TRACK [LANGUAGE], or document INPUT OUTPUT FROM TO")
    }
    try autoreleasepool {
        let input = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
        let language = args.count == 6 ? args[5] : "auto"
        if args[1] == "document" { try convertDocument(input, to: output, source: args[4], target: args[5]) }
        else if args[1] == "subtitle" { try recognizeSubtitles(input, to: output, track: Int(args[4]) ?? 0, language: language) }
        else if args[1] == "pdf-overlay" { try pdfTextLayer(input, to: output, pages: args[4], language: language) }
        else { try convertImage(input, to: output, format: args[4], language: language) }
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
