import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import XCTest
@testable import ConversionCore

final class OCRImageOptionsTests: XCTestCase {
    func testSearchablePDFKeepsImageEncodingSettings() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["nativeguard", "pdfguard"].allSatisfy({ manager.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the native and PDF helpers before checking searchable images.")
        }
        let work = manager.temporaryDirectory.appendingPathComponent("OCR image settings \(UUID())")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
        for x in 0..<640 {
            bitmap.setFillColor(try XCTUnwrap(CGColor(colorSpace: space,
                components: [CGFloat(x) / 640, 0.15, 0.6, 1])))
            bitmap.fill(CGRect(x: x, y: 0, width: 1, height: 80))
        }
        bitmap.textPosition = CGPoint(x: 30, y: 200)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Invoice number 4827", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 40, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])), bitmap)
        let source = work.appendingPathComponent("original.png")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(bitmap.makeImage()), [
            kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: source)
        let engine = try ConversionEngine(toolsDirectory: tools)
        var pdfOptions = PDFOptions()
        pdfOptions.imageOCR = true
        pdfOptions.ocrLanguage = "en-US"
        var encodings: [[Data]] = []
        for (index, choices) in [(0.1, false), (1.0, false), (1.0, true)].enumerated() {
            var options = ImageOptions()
            options.quality = choices.0
            options.convertToSRGB = choices.1
            options.preserveMetadata = !choices.1
            let base = work.appendingPathComponent("base-\(index).pdf")
            let searchable = work.appendingPathComponent("searchable-\(index).pdf")
            try engine.convert(source, to: base, settings: .init(imageOptions: options))
            try engine.convert(source, to: searchable, settings: .init(imageOptions: options, pdfOptions: pdfOptions))
            let expected = try imageStreams(base)
            XCTAssertFalse(expected.isEmpty)
            XCTAssertEqual(try imageStreams(searchable), expected, "OCR changed the encoded image or color profile.")
            encodings.append(expected)
            let document = try XCTUnwrap(PDFDocument(url: searchable))
            XCTAssertEqual(document.pageCount, 1)
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertTrue((page.string ?? "").contains("Invoice number 4827"))
            XCTAssertEqual(page.bounds(for: .mediaBox).width, 320, accuracy: 0.02)
            XCTAssertEqual(page.bounds(for: .mediaBox).height, 160, accuracy: 0.02)
        }
        XCTAssertNotEqual(encodings[0], encodings[1], "Image quality must affect the encoded image.")
        XCTAssertNotEqual(encodings[1], encodings[2], "sRGB conversion must affect the image or its profile.")
        for orientation in 2...8 {
            let input = work.appendingPathComponent("orientation-\(orientation).png")
            let pixels = try ImageConverter.render(XCTUnwrap(bitmap.makeImage()),
                orientation: orientation == 6 ? 8 : (orientation == 8 ? 6 : orientation))
            let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(writer, pixels, [kCGImagePropertyOrientation: orientation,
                kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(writer))
            let bytes = try Data(contentsOf: input)
            let base = work.appendingPathComponent("rotated-base-\(orientation).pdf")
            let searchable = work.appendingPathComponent("rotated-searchable-\(orientation).pdf")
            try engine.convert(input, to: base)
            try engine.convert(input, to: searchable, settings: .init(pdfOptions: pdfOptions))
            XCTAssertEqual(try imageStreams(searchable), try imageStreams(base))
            let document = try XCTUnwrap(PDFDocument(url: searchable))
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertEqual(page.bounds(for: .mediaBox).width, 320, accuracy: 0.02)
            XCTAssertEqual(page.bounds(for: .mediaBox).height, 160, accuracy: 0.02)
            let text = try XCTUnwrap(document.findString("Invoice number 4827", withOptions: []).first)
            XCTAssertEqual(text.bounds(for: page).minX, 15, accuracy: 10)
            XCTAssertEqual(text.bounds(for: page).minY, 100, accuracy: 10)
            XCTAssertEqual(try Data(contentsOf: input), bytes)
        }
        var invalid = ImageOptions()
        invalid.quality = -1
        let rejected = work.appendingPathComponent("rejected.pdf")
        XCTAssertThrowsError(try engine.convert(source, to: rejected, settings: .init(imageOptions: invalid, pdfOptions: pdfOptions)))
        XCTAssertFalse(manager.fileExists(atPath: rejected.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: work.path).contains {
            $0.hasPrefix("ocr-") || $0.hasPrefix(".allomer-")
        })
    }

    private func imageStreams(_ file: URL) throws -> [Data] {
        let document = try XCTUnwrap(CGPDFDocument(file as CFURL))
        let page = try XCTUnwrap(document.page(at: 1))
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(page.dictionary), "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &objects))
        var result: [Data] = []
        try withUnsafeMutablePointer(to: &result) { resultPointer in
            CGPDFDictionaryApplyFunction(try XCTUnwrap(objects), { _, object, context in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<CChar>?
                var encoding = CGPDFDataFormat.raw
                guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                      String(cString: subtype) == "Image", let data = CGPDFStreamCopyData(stream, &encoding) else { return }
                let values = context!.assumingMemoryBound(to: [Data].self)
                values.pointee.append(data as Data)
                var color: CGPDFArrayRef?, profile: CGPDFStreamRef?
                if CGPDFDictionaryGetArray(dictionary, "ColorSpace", &color), let color,
                   CGPDFArrayGetStream(color, 1, &profile), let profile, let data = CGPDFStreamCopyData(profile, &encoding) {
                    values.pointee.append(data as Data)
                }
            }, resultPointer)
        }
        return result
    }
}
