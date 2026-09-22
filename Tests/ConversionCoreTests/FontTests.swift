import AppKit
import CoreGraphics
import CoreText
import Foundation
import XCTest

@testable import ConversionCore

final class FontTests: XCTestCase {
    /// Adds a table with `tag` to an sfnt so a refusal can be checked without a font that
    /// carries real colour or bitmap data.
    private func sfntAddingTable(_ data: Data, tag: String, contents: Data) -> Data {
        func read(_ offset: Int, _ count: Int) -> Int {
            Int(data[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) })
        }
        var records: [(tag: [UInt8], data: Data)] = []
        for index in 0..<read(4, 2) {
            let entry = 12 + index * 16
            let offset = read(entry + 8, 4), length = read(entry + 12, 4)
            records.append((Array(data[entry..<(entry + 4)]), data.subdata(in: offset..<(offset + length))))
        }
        records.append((Array(tag.utf8), contents))
        records.sort { $0.tag.lexicographicallyPrecedes($1.tag) }
        var directory = Data(), body = Data()
        var position = 12 + records.count * 16
        let entrySelector = records.count.bitWidth - 1 - records.count.leadingZeroBitCount
        directory.append(contentsOf: Array(data[0..<4]))
        for value in [records.count, 16 << entrySelector, entrySelector, records.count * 16 - (16 << entrySelector)] {
            directory.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
        for record in records {
            var padded = record.data
            while padded.count % 4 != 0 { padded.append(0) }
            var sum: UInt32 = 0
            for word in stride(from: 0, to: padded.count, by: 4) {
                sum &+= padded[word..<(word + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            }
            directory.append(contentsOf: record.tag)
            for value in [sum, UInt32(position), UInt32(record.data.count)] {
                directory.append(contentsOf: (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
            }
            body.append(padded)
            position += padded.count
        }
        return directory + body
    }

    private func tables(in font: URL) throws -> Set<String> {
        let data = try Data(contentsOf: font)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let graphics = try XCTUnwrap(CGFont(provider))
        var found = Set<String>()
        for name in ["fvar", "gvar", "avar", "cvar", "HVAR", "VVAR", "MVAR", "CFF2", "DSIG", "glyf", "CFF "] {
            let tag = name.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if graphics.table(for: tag) != nil { found.insert(name) }
        }
        return found
    }

    func testFontFormatsKeepCharactersSpacingAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["fontconvert", "fontguard"].allSatisfy({
            FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path)
        }) else {
            throw XCTSkip("Build the font converter to check font conversion.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var sources = [String: URL]()
        for format in ["ttf", "otf"] {
            let file = directory.appendingPathComponent("source." + format)
            try FileManager.default.copyItem(at: root.appendingPathComponent("Tests/Fixtures/font-values." + format), to: file)
            sources[format] = file
        }
        for format in ["woff", "woff2"] {
            let file = directory.appendingPathComponent("source." + format)
            try engine.convert(sources["ttf"]!, to: file)
            sources[format] = file
        }
        let signatures: [String: [UInt8]] = ["ttf": [0, 1, 0, 0], "otf": Array("OTTO".utf8),
            "woff": Array("wOFF".utf8), "woff2": Array("wOF2".utf8)]
        for (inputFormat, source) in sources {
            let original = try Data(contentsOf: source)
            for outputFormat in FontConverter.formats.sorted() {
                let output = directory.appendingPathComponent("\(inputFormat)-to-\(outputFormat).\(outputFormat)")
                try engine.convert(source, to: output)
                let data = try Data(contentsOf: output)
                XCTAssertEqual(Array(data.prefix(4)), signatures[outputFormat])
                let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
                let graphics = try XCTUnwrap(CGFont(provider))
                let font = CTFontCreateWithGraphicsFont(graphics, 1000, nil, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "ABé", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font]))
                XCTAssertEqual(CTLineGetTypographicBounds(line, nil, nil, nil), 3220, accuracy: 0.01)
                // Only OTF carries CFF outlines; the others carry TrueType outlines.
                let present = try tables(in: output)
                XCTAssertEqual(present.contains("CFF "), outputFormat == "otf", "\(inputFormat)->\(outputFormat)")
                XCTAssertEqual(present.contains("glyf"), outputFormat != "otf", "\(inputFormat)->\(outputFormat)")
                XCTAssertThrowsError(try engine.convert(source, to: output))
                XCTAssertEqual(try Data(contentsOf: output), data)
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
        let original = try Data(contentsOf: sources["otf"]!)
        let old = directory.appendingPathComponent("automatic.otf")
        let renamed = directory.appendingPathComponent("automatic.woff2")
        try original.write(to: renamed)
        let record = try engine.convertRenamedFile(from: old, to: renamed,
            historyDirectory: directory.appendingPathComponent("history"))
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: old), original)
        let invalid = directory.appendingPathComponent("invalid.ttf")
        try Data(repeating: 0, count: 100).write(to: invalid)
        let failed = directory.appendingPathComponent("invalid.otf")
        XCTAssertThrowsError(try engine.convert(invalid, to: failed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        // A bitmap-strike table is enough for the refusal; its contents are never read.
        let bitmap = directory.appendingPathComponent("bitmap.ttf")
        try sfntAddingTable(try Data(contentsOf: sources["ttf"]!), tag: "EBDT",
                            contents: Data([0, 2, 0, 0])).write(to: bitmap)
        XCTAssertThrowsError(try engine.convert(bitmap, to: failed)) { error in
            XCTAssertTrue(error.localizedDescription.contains("bitmap strikes"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
    }

    /// The upstream variable fixtures cover both variable outline flavours. They are fetched by
    /// tools/check-fonts.py, which records their addresses and checksums.
    func testVariableFontsConvertToStaticDefaultInstances() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        let fixtures = root.appendingPathComponent(".tools/fonts/fixtures")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("fontguard").path),
              ["otf", "ttf"].allSatisfy({
                  FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("AdobeVFPrototype." + $0).path)
              }) else {
            throw XCTSkip("Run tools/check-fonts.py to fetch the upstream variable fixtures.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let variation = Set(["fvar", "gvar", "avar", "cvar", "HVAR", "VVAR", "MVAR", "CFF2", "DSIG"])
        for flavour in ["otf", "ttf"] {
            let source = directory.appendingPathComponent("variable." + flavour)
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent("AdobeVFPrototype." + flavour), to: source)
            let original = try Data(contentsOf: source)
            // The fixture is a variable font of this flavour before conversion.
            XCTAssertTrue(try tables(in: source).contains("fvar"), flavour)
            XCTAssertEqual(try tables(in: source).contains("CFF2"), flavour == "otf")
            for outputFormat in FontConverter.formats.sorted() {
                let output = directory.appendingPathComponent("\(flavour)-to-\(outputFormat).\(outputFormat)")
                try engine.convert(source, to: output)
                let present = try tables(in: output)
                XCTAssertTrue(present.isDisjoint(with: variation),
                              "\(flavour)->\(outputFormat) kept \(present.intersection(variation).sorted())")
                XCTAssertEqual(present.contains("CFF "), outputFormat == "otf")
                XCTAssertEqual(present.contains("glyf"), outputFormat != "otf")
                let data = try Data(contentsOf: output)
                let graphics = try XCTUnwrap(CGFont(try XCTUnwrap(CGDataProvider(data: data as CFData))))
                let font = CTFontCreateWithGraphicsFont(graphics, CGFloat(graphics.unitsPerEm), nil, nil)
                XCTAssertEqual(CTFontCopyName(font, kCTFontPostScriptNameKey) as String?, "AdobeVFPrototype-Default")
                XCTAssertThrowsError(try engine.convert(source, to: output))
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    /// Roboto has 2048 units per em and composite glyphs whose components carry a scale. Placing
    /// such a component by the rounded offset a rasterizer may use moved whole glyphs sideways.
    func testCompositeGlyphsAndLargeEmsKeepTheirOutlines() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        let fixture = root.appendingPathComponent(".tools/fonts/fixtures/Roboto-Regular.ttf")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("fontguard").path),
              FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Run tools/check-fonts.py to fetch the upstream composite fixture.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("composite.ttf")
        try FileManager.default.copyItem(at: fixture, to: source)
        let original = try Data(contentsOf: source)
        let graphics = try XCTUnwrap(CGFont(try XCTUnwrap(CGDataProvider(data: original as CFData))))
        XCTAssertEqual(graphics.unitsPerEm, 2048)
        for outputFormat in FontConverter.formats.sorted() {
            // The engine's own outline check runs inside convert, so reaching here means every
            // character's advance and outline bounds survived.
            let output = directory.appendingPathComponent("converted." + outputFormat)
            try engine.convert(source, to: output)
            XCTAssertGreaterThan(try FileVersion(output).size, 0)
            XCTAssertEqual(try tables(in: output).contains("CFF "), outputFormat == "otf")
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
