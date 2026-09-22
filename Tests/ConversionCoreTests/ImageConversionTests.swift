import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import ConversionCore

final class ImageConversionTests: XCTestCase {
    func testImageBackgroundOptionsAndAutomaticUndo() throws {
        var options = try JSONDecoder().decode(ImageOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options.alphaHandling, .preserve)
        XCTAssertEqual(options.alphaCustomColor, "#FFFFFF")
        options.alphaHandling = .custom
        options.alphaCustomColor = "#336699"
        XCTAssertEqual(try JSONDecoder().decode(ImageOptions.self, from: JSONEncoder().encode(options)), options)
        for color in ["", "#fff", "##FFFFFF", "+12345", "12345g", "ffffff\n", "#FFFFFFFF", "１２３４５６"] {
            options.alphaCustomColor = color
            XCTAssertThrowsError(try options.backgroundColor(), color)
        }
        options.alphaCustomColor = "336699"
        let components = try XCTUnwrap(options.backgroundColor()?.components)
        XCTAssertEqual(components, [0.2, 0.4, 0.6, 1])

        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Image background café, \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let source = work.appendingPathComponent("transparent.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 0, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: source)
        let engine = try ConversionEngine()
        for quality in [-0.1, 1.1, .nan] {
            options.quality = quality
            let output = work.appendingPathComponent("invalid.jpg")
            XCTAssertThrowsError(try engine.convert(source, to: output, settings: .init(imageOptions: options)))
            XCTAssertFalse(manager.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
        options.quality = 1
        let renamed = source.deletingPathExtension().appendingPathExtension("jpg")
        try manager.moveItem(at: source, to: renamed)
        let record = try engine.convertRenamedFile(from: source, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), settings: .init(imageOptions: options))
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(renamed as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        let rendered = try ImageConverter.render(image, orientation: 1)
        let pixels = try XCTUnwrap(rendered.dataProvider?.data) as Data
        XCTAssertEqual(Double(pixels[0]) / 255, 0.2, accuracy: 0.02)
        XCTAssertEqual(Double(pixels[1]) / 255, 0.4, accuracy: 0.02)
        XCTAssertEqual(Double(pixels[2]) / 255, 0.6, accuracy: 0.02)
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testTIFFCompressionMetadataAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("tiffguard").path) else {
            throw XCTSkip("Build the TIFF tools to check JPEG compression.")
        }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("TIFF café, \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let source = work.appendingPathComponent("pages.tiff")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.tiff" as CFString, 2, nil))
        for index in 0..<2 {
            let context = try XCTUnwrap(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8,
                bytesPerRow: 0, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index), green: 0.5, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
            let properties: [CFString: Any] = [kCGImagePropertyOrientation: index == 0 ? 1 : 6,
                kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "Page \(index)"],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:03:0\(index + 1) 05:06:07"]]
            CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: source)
        let engine = try ConversionEngine(toolsDirectory: tools)
        var options = try JSONDecoder().decode(ImageOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options.tiffCompression, .automatic)
        XCTAssertEqual(options.tiffJPEGQuality, 0.85)
        options.tiffJPEGQuality = 0.4
        for (mode, code) in [(TIFFCompression.automatic, 1), (.none, 1), (.lzw, 5), (.deflate, 8), (.jpeg, 7)] {
            options.tiffCompression = mode
            let output = work.appendingPathComponent("\(mode.rawValue).tiff")
            try engine.convert(source, to: output, settings: .init(imageOptions: options))
            let reader = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(reader), 2)
            for index in 0..<2 {
                let properties = try ImageConverter.properties(reader, index)
                let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
                let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any], "\(mode.rawValue), page \(index): \(properties)")
                XCTAssertEqual(tiff[kCGImagePropertyTIFFCompression] as? Int, code)
                XCTAssertEqual(tiff[kCGImagePropertyTIFFImageDescription] as? String, "Page \(index)")
                XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2024:03:0\(index + 1) 05:06:07")
                XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, index == 0 ? 1 : 6)
                XCTAssertEqual(properties[kCGImagePropertyDPIWidth] as? Int, 144)
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
        XCTAssertEqual(try JSONDecoder().decode(ImageOptions.self, from: JSONEncoder().encode(options)), options)
        for quality in [-0.1, 1.1, .nan] {
            options.tiffJPEGQuality = quality
            XCTAssertThrowsError(try engine.convert(source, to: work.appendingPathComponent("invalid.tiff"), settings: .init(imageOptions: options)))
            XCTAssertFalse(manager.fileExists(atPath: work.appendingPathComponent("invalid.tiff").path))
        }
        options.tiffJPEGQuality = 0.4
        let png = work.appendingPathComponent("automatic.png")
        let pngWriter = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        CGImageDestinationAddImage(pngWriter, try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil)), nil)
        XCTAssertTrue(CGImageDestinationFinalize(pngWriter))
        let pngBytes = try Data(contentsOf: png)
        let renamed = png.deletingPathExtension().appendingPathExtension("tiff")
        try manager.moveItem(at: png, to: renamed)
        let record = try engine.convertRenamedFile(from: png, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), settings: .init(imageOptions: options))
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(ImageConverter.detectedType(at: renamed), "public.tiff")
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: png), pngBytes)
        let retained = record.backupURL.deletingLastPathComponent().lastPathComponent
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix(".allomer-") }, [retained])
    }
    func testDamagedJPEGIsRejectedBeforeImagePDFAndOCRConversion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("pdfguard").path) else {
            throw XCTSkip("Build the PDF tool to check JPEG validation.")
        }
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("JPEG check \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let good = work.appendingPathComponent("complete.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(good as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let engine = try ConversionEngine(toolsDirectory: tools)
        try engine.convert(good, to: work.appendingPathComponent("valid.png"))
        let bad = work.appendingPathComponent("incomplete.png")
        let damaged = try Data(contentsOf: good).dropLast(50)
        try damaged.write(to: bad)
        XCTAssertEqual(ImageConverter.detectedType(at: bad), "public.jpeg")
        for (index, target) in ["png", "pdf", "txt", "html", "docx", "pdf"].enumerated() {
            let output = work.appendingPathComponent("rejected-\(index).\(target)")
            var options = PDFOptions()
            options.imageOCR = index == 5
            XCTAssertThrowsError(try engine.convert(bad, to: output, settings: .init(pdfOptions: options))) { error in
                XCTAssertTrue(error.localizedDescription.contains("Premature end of JPEG file"), error.localizedDescription)
            }
            XCTAssertFalse(manager.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: bad), damaged)
        }
        let recordSource = work.appendingPathComponent("incomplete.jpg")
        XCTAssertThrowsError(try engine.convertRenamedFile(from: recordSource, to: bad,
            historyDirectory: work.appendingPathComponent("history")))
        XCTAssertEqual(try Data(contentsOf: bad), damaged)
        XCTAssertFalse(manager.fileExists(atPath: recordSource.path))
        // Archiving stores bytes and does not require a decodable image.
        try engine.convert(bad, to: work.appendingPathComponent("retained.zip"))
    }
    func testImagePDFAndMultipageTIFFWithAutomaticUndo() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Image pages \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let source = work.appendingPathComponent("original.tiff")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.tiff" as CFString, 2, nil))
        for (width, height, orientation) in [(48, 32, 1), (20, 50, 6)] {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation,
                kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "Private caption"]]
            CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: source)
        let engine = try ConversionEngine()
        XCTAssertTrue(engine.availableOutputs(for: source).contains { $0.id == "pdf" })
        XCTAssertFalse(engine.availableOutputs(for: source).contains { $0.id == "jpeg" })
        var options = ImageOptions()
        options.preserveMetadata = false
        options.convertToSRGB = true
        let output = work.appendingPathComponent("pages.pdf")
        try engine.convert(source, to: output, settings: .init(imageOptions: options))
        let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 2)
        XCTAssertEqual(pdf.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 24, height: 16))
        XCTAssertEqual(pdf.page(at: 2)?.getBoxRect(.mediaBox).size, CGSize(width: 25, height: 10))
        let copy = work.appendingPathComponent("clean.tiff")
        try engine.convert(source, to: copy, settings: .init(imageOptions: options))
        let read = try XCTUnwrap(CGImageSourceCreateWithURL(copy as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(read), 2)
        for index in 0..<2 {
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(read, index, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyDPIWidth] as? Double, 144)
            XCTAssertEqual(properties[kCGImagePropertyDPIHeight] as? Double, 144)
            XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, index == 0 ? 1 : 6)
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            XCTAssertNil(tiff?[kCGImagePropertyTIFFImageDescription])
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertThrowsError(try engine.convert(source, to: output))
        let renamed = work.appendingPathComponent("original.pdf")
        try manager.moveItem(at: source, to: renamed)
        let record = try engine.convertRenamedFile(from: source, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), settings: .init(imageOptions: options))
        XCTAssertEqual(CGPDFDocument(renamed as CFURL)?.numberOfPages, 2)
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let retained = record.backupURL.deletingLastPathComponent().lastPathComponent
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix(".allomer-") }, [retained])
    }
}
