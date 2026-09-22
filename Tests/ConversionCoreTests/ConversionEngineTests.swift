import AppKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import ConversionCore

final class ConversionEngineTests: XCTestCase {
    func testComposedRoutesKeepValuesAndCleanIntermediates() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["tabular", "carta"].allSatisfy({ FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the document and spreadsheet tools to check composed routes.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let docx = try XCTUnwrap(engine.catalog.format(forExtension: "docx"))
        let legacy = root.appendingPathComponent("Tests/Fixtures/sheet-values.xls")
        XCTAssertEqual(engine.conversionRoute(from: legacy, to: docx)?.map(\.id), ["tsv", "docx"])
        XCTAssertTrue(engine.availableOutputs(for: legacy).contains(docx))
        let document = directory.appendingPathComponent("from-xls.docx")
        try engine.convert(legacy, to: document)
        let text = try NSAttributedString(url: document,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
        for value in ["Name", "Code", "Café 東京", "00123", "12.5"] { XCTAssertTrue(text.contains(value), text) }
        let yaml = directory.appendingPathComponent("table.yaml")
        let yamlText = "- name: Café 東京\n  code: '00123'\n  amount: 12.5\n"
        try yamlText.write(to: yaml, atomically: false, encoding: .utf8)
        XCTAssertEqual(engine.conversionRoute(from: yaml, to: docx)?.map(\.id), ["json", "tsv", "docx"])
        let converted = directory.appendingPathComponent("from-yaml.docx")
        try engine.convert(yaml, to: converted)
        let yamlDocument = try NSAttributedString(url: converted,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
        for value in ["Café 東京", "00123", "12.5"] { XCTAssertTrue(yamlDocument.contains(value), yamlDocument) }
        let csv = directory.appendingPathComponent("custom.csv")
        try "name;code\nCafé 東京;00123\n".write(to: csv, atomically: false, encoding: .utf8)
        var spreadsheetOptions = SpreadsheetOptions()
        spreadsheetOptions.csvDelimiter = .semicolon
        let html = directory.appendingPathComponent("custom.html")
        try engine.convert(csv, to: html, settings: .init(spreadsheetOptions: spreadsheetOptions))
        let markup = try String(contentsOf: html, encoding: .utf8)
        XCTAssertTrue(markup.contains("<th>name</th>"), markup)
        XCTAssertTrue(markup.contains("<th>code</th>"), markup)
        let invalid = directory.appendingPathComponent("not-a-table.yaml")
        try "not a table\n".write(to: invalid, atomically: false, encoding: .utf8)
        let failed = directory.appendingPathComponent("failed.docx")
        XCTAssertThrowsError(try engine.convert(invalid, to: failed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".allomer-") })
        let renamed = directory.appendingPathComponent("table.docx")
        try FileManager.default.moveItem(at: yaml, to: renamed)
        let record = try engine.convertRenamedFile(from: yaml, to: renamed,
            historyDirectory: directory.appendingPathComponent("history"))
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try String(contentsOf: yaml, encoding: .utf8), yamlText)
    }
    func testRealConversionAndNoOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("misnamed.jpg")
        let output = directory.appendingPathComponent("result.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        let image = try XCTUnwrap(context.makeImage())
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let original = try Data(contentsOf: source)
        let engine = try ConversionEngine()
        XCTAssertEqual(engine.catalog.formats.count, 115)
        XCTAssertEqual(engine.catalog.format(forExtension: ".JPG")?.id, "jpeg")
        XCTAssertEqual(engine.catalog.format(for: directory.appendingPathComponent("archive.TAR.GZ"))?.id, "tgz")
        XCTAssertEqual(engine.catalog.format(for: directory.appendingPathComponent("data.gz"))?.id, "gzip")
        XCTAssertTrue(engine.availableOutputs(for: source).contains { $0.id == "jpeg" })
        XCTAssertFalse(engine.availableOutputs(for: source).contains { $0.id == "mp3" })
        try engine.convert(source, to: output)
        XCTAssertEqual(ImageConverter.detectedType(at: output), "public.jpeg")
        XCTAssertEqual(try Data(contentsOf: source), original)
        let converted = try Data(contentsOf: output)
        XCTAssertThrowsError(try engine.convert(source, to: output))
        XCTAssertEqual(try Data(contentsOf: output), converted)
        XCTAssertThrowsError(try engine.convert(source, to: source))
        XCTAssertEqual(try Data(contentsOf: source), original)
        var invalid = ImageOptions()
        invalid.quality = .nan
        XCTAssertThrowsError(try engine.convert(source, to: directory.appendingPathComponent("invalid.jpg"), settings: .init(imageOptions: invalid)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("invalid.jpg").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".allomer-") })
        let oldName = directory.appendingPathComponent("original.png")
        let newName = directory.appendingPathComponent("original.jpg")
        try original.write(to: oldName)
        let beforeMetadata = try FileVersion(oldName)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: oldName.path)
        XCTAssertNotEqual(try FileVersion(oldName), beforeMetadata)
        try FileManager.default.moveItem(at: oldName, to: newName)
        let record = try engine.convertRenamedFile(from: oldName, to: newName,
            historyDirectory: directory.appendingPathComponent("history"))
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(ImageConverter.detectedType(at: newName), "public.jpeg")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: newName.path)[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(try Data(contentsOf: record.backupURL), original)
        XCTAssertEqual(try Data(contentsOf: record.snapshotURL), original)
        var interrupted = record
        interrupted.state = .prepared
        try interrupted.save()
        XCTAssertEqual(try ConversionRecord.loadHistory(from: record.journalURL.deletingLastPathComponent()).first?.state, .completed)
        let changed = Data("edited after conversion".utf8)
        let convertedAgain = try Data(contentsOf: newName)
        try changed.write(to: newName)
        XCTAssertThrowsError(try ConversionEngine.undo(record))
        XCTAssertEqual(try Data(contentsOf: newName), changed)
        try convertedAgain.write(to: newName)
        try changed.write(to: oldName)
        XCTAssertThrowsError(try ConversionEngine.undo(record))
        XCTAssertEqual(try Data(contentsOf: oldName), changed)
        try FileManager.default.removeItem(at: oldName)
        let undone = try ConversionEngine.undo(record)
        XCTAssertEqual(undone.state, .undone)
        XCTAssertEqual(try Data(contentsOf: oldName), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newName.path))
        XCTAssertEqual(try JSONDecoder().decode(ConversionRecord.self, from: Data(contentsOf: record.journalURL)).state, .undone)
        interrupted.state = .undoPrepared
        try interrupted.save()
        XCTAssertEqual(try ConversionRecord.loadHistory(from: record.journalURL.deletingLastPathComponent()).first?.state, .undone)
        try changed.write(to: oldName)
        try interrupted.save()
        XCTAssertEqual(try ConversionRecord.loadHistory(from: record.journalURL.deletingLastPathComponent()).first?.state, .needsReview)
        XCTAssertEqual(try Data(contentsOf: oldName), changed)
        XCTAssertEqual(try Data(contentsOf: record.snapshotURL), original)
    }
    func testImageEncodersAreOfferedAndAnAbsentOneNamesTheReason() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let source = work.appendingPathComponent("original.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let engine = try ConversionEngine()

        let offered = Set(engine.availableOutputs(for: source).map(\.id))
        for id in ["heic", "icns", "ico"] {
            XCTAssertTrue(offered.contains(id), "\(id) is missing from the offered outputs.")
            XCTAssertTrue(ImageConverter.outputTypes.contains(
                try XCTUnwrap(engine.catalog.formats.first { $0.id == id }?.typeIdentifier)))
        }
        let avifType = try XCTUnwrap(engine.catalog.format(forExtension: "avif")?.typeIdentifier)
        XCTAssertEqual(offered.contains("avif"), ImageConverter.outputTypes.contains(avifType))

        // A type this Mac cannot encode is refused by name, not silently skipped.
        let absent = FileFormat(id: "absent", name: "Absent Format", category: "image", extensions: ["nosuchextension"])
        XCTAssertFalse(offered.contains(absent.id))
        XCTAssertThrowsError(try ImageConverter.convert(source, to: work.appendingPathComponent("out.bin"),
                                                        format: absent)) { error in
            XCTAssertEqual((error as? ConversionError)?.errorDescription,
                           "macOS cannot encode Absent Format with ImageIO.")
        }
    }
}
