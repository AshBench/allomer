import AppKit
import Foundation
import XCTest
@testable import ConversionCore

final class NativeDocumentTests: XCTestCase {
    func testNativeWordTextFormattingEncodingsAndAutomaticUndo() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Native Word \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        let required = ["carta", "nativeconvert", "nativeguard", "webconvert", "webguard", "ffmpeg", "ffprobe"]
        guard required.allSatisfy({ manager.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the document, native, and media helpers before checking native documents.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let literal = "Literal <b>markup</b>, café 世界 😀.\nA backslash: \\pict.\n"
        var recoveryDirectories: Set<String> = []
        for (index, encoding) in [String.Encoding.utf8, .utf16, .utf32].enumerated() {
            let source = work.appendingPathComponent("text-\(index).txt")
            let original = try XCTUnwrap(literal.data(using: encoding))
            try original.write(to: source)
            let outputs = Set(engine.availableOutputs(for: source).map(\.id))
            XCTAssertTrue(Set(["doc", "rtf", "html", "docx", "pdf"]).isSubset(of: outputs))
            let renamed = work.appendingPathComponent("text-\(index).doc")
            try manager.moveItem(at: source, to: renamed)
            let record = try engine.convertRenamedFile(from: source, to: renamed,
                historyDirectory: work.appendingPathComponent("history"))
            recoveryDirectories.insert(record.backupURL.deletingLastPathComponent().lastPathComponent)
            let data = try Data(contentsOf: renamed)
            XCTAssertTrue(data.starts(with: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]))
            let text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.docFormat], documentAttributes: nil)
            XCTAssertEqual(text.string, literal)
            _ = try ConversionEngine.undo(record)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertFalse(manager.fileExists(atPath: renamed.path))
            XCTAssertEqual(try Data(contentsOf: record.backupURL), data)
        }
        let source = work.appendingPathComponent("formatting.rtf")
        let rtf = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}{\colortbl;\red0\green0\blue200;}\fs24 Normal \b Bold\b0  \i Italic\i0  \ul Underline\ulnone  \cf1 Blue\cf0\par Literal \\pict.\par}"#
        try Data(rtf.utf8).write(to: source)
        let output = work.appendingPathComponent("formatting.doc")
        try engine.convert(source, to: output)
        let data = try Data(contentsOf: output)
        let text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.docFormat], documentAttributes: nil)
        XCTAssertEqual(text.string, "Normal Bold Italic Underline Blue\nLiteral \\pict.\n")
        func attributes(_ word: String) throws -> [NSAttributedString.Key: Any] {
            let range = (text.string as NSString).range(of: word)
            guard range.location != NSNotFound else { throw ConversionError.message("The checked word is missing.") }
            return text.attributes(at: range.location, effectiveRange: nil)
        }
        XCTAssertTrue(try XCTUnwrap(attributes("Bold")[.font] as? NSFont).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(try XCTUnwrap(attributes("Italic")[.font] as? NSFont).fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertEqual(try attributes("Underline")[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        let color = try XCTUnwrap((attributes("Blue")[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        let originalText = try NSAttributedString(data: Data(rtf.utf8), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let blueRange = (originalText.string as NSString).range(of: "Blue")
        let originalColor = try XCTUnwrap((originalText.attribute(.foregroundColor, at: blueRange.location, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.blueComponent, originalColor.blueComponent, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: source), Data(rtf.utf8))
        let docFormat = try XCTUnwrap(engine.catalog.format(forExtension: "doc"))
        for targetID in ["html", "rtf", "txt", "docx", "pdf", "png", "mp4"] {
            let target = try XCTUnwrap(engine.catalog.format(forExtension: targetID))
            XCTAssertNotNil(engine.conversionRoute(from: docFormat, to: target), targetID)
        }
        for targetID in ["html", "rtf", "txt"] {
            let imported = work.appendingPathComponent("imported.\(targetID)")
            try engine.convert(output, to: imported)
            let importedData = try Data(contentsOf: imported)
            let importedText: String
            if targetID == "txt" {
                importedText = try XCTUnwrap(String(data: importedData, encoding: .utf8))
            } else {
                let type: NSAttributedString.DocumentType = targetID == "html" ? .html : .rtf
                let attributed = try NSAttributedString(data: importedData, options: [.documentType: type], documentAttributes: nil)
                importedText = attributed.string
                let word = (attributed.string as NSString).range(of: "Bold")
                XCTAssertNotEqual(word.location, NSNotFound)
                XCTAssertTrue(try XCTUnwrap(attributed.attribute(.font, at: word.location, effectiveRange: nil) as? NSFont)
                    .fontDescriptor.symbolicTraits.contains(.bold), targetID)
            }
            XCTAssertTrue(importedText == text.string || importedText == text.string + "\n", targetID)
            XCTAssertEqual(try Data(contentsOf: output), data)
        }
        let docx = work.appendingPathComponent("imported.docx")
        try engine.convert(output, to: docx)
        let docxText = try NSAttributedString(url: docx,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
        XCTAssertEqual(docxText.trimmingCharacters(in: .newlines), text.string.trimmingCharacters(in: .newlines),
            String(reflecting: docxText))
        XCTAssertEqual(try Data(contentsOf: output), data)
        let automaticSource = work.appendingPathComponent("automatic.doc")
        try data.write(to: automaticSource)
        let automaticOutput = work.appendingPathComponent("automatic.html")
        try manager.moveItem(at: automaticSource, to: automaticOutput)
        let record = try engine.convertRenamedFile(from: automaticSource, to: automaticOutput,
            historyDirectory: work.appendingPathComponent("history"))
        recoveryDirectories.insert(record.backupURL.deletingLastPathComponent().lastPathComponent)
        let automaticText = try NSAttributedString(url: automaticOutput,
            options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil).string
        XCTAssertTrue(automaticText == text.string || automaticText == text.string + "\n")
        XCTAssertEqual(try Data(contentsOf: record.backupURL), data)
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: automaticSource), data)
        XCTAssertFalse(manager.fileExists(atPath: automaticOutput.path))
        let malformed = work.appendingPathComponent("malformed.doc")
        try Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]).write(to: malformed)
        let refused = work.appendingPathComponent("malformed.txt")
        XCTAssertThrowsError(try engine.convert(malformed, to: refused))
        XCTAssertFalse(manager.fileExists(atPath: refused.path))
        let large = work.appendingPathComponent("large.txt")
        let largeText = (0..<25_000).map { "Paragraph \($0): Original text with café and a final period.\n" }.joined()
        try Data(largeText.utf8).write(to: large)
        let largeOutput = work.appendingPathComponent("large.doc")
        try engine.convert(large, to: largeOutput)
        let largeRead = try NSAttributedString(data: Data(contentsOf: largeOutput),
            options: [.documentType: NSAttributedString.DocumentType.docFormat], documentAttributes: nil)
        XCTAssertEqual(largeRead.string, largeText)
        XCTAssertEqual(try Data(contentsOf: large), Data(largeText.utf8))
        for (index, invalid) in [#"{\rtf1 Body"#, #"{\rtf1 Body{\footnote Note}}"#,
                                 #"{\rtf1{\header Header}Body}"#, #"{\rtf1{\pict\pngblip 0000}}"#,
                                 #"{\rtf1{\field{\*\fldinst HYPERLINK "https://example.invalid"}{\fldrslt Link}}}"#].enumerated() {
            let input = work.appendingPathComponent("invalid-\(index).rtf")
            let refused = work.appendingPathComponent("invalid-\(index).doc")
            try Data(invalid.utf8).write(to: input)
            XCTAssertThrowsError(try engine.convert(input, to: refused))
            XCTAssertFalse(manager.fileExists(atPath: refused.path))
            XCTAssertEqual(try Data(contentsOf: input), Data(invalid.utf8))
        }
        XCTAssertThrowsError(try engine.convert(source, to: output))
        XCTAssertEqual(try Data(contentsOf: output), data)
        let leftovers = try manager.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix(".allomer-") }
        XCTAssertEqual(Set(leftovers), recoveryDirectories, "Only the recorded Undo recovery folders should remain")
    }
}
