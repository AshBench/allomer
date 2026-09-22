import Foundation
import XCTest

@testable import ConversionCore

final class EbookTests: XCTestCase {
    func testEbookReconstructionKeepsMediaAndCreatesXHTML() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tool = root.appendingPathComponent(".tools/ebook/bin/mobitool")
        let fixtures = root.appendingPathComponent(".tools/ebook-build/libmobi-0.12/tests/samples")
        guard FileManager.default.isExecutableFile(atPath: tool.path), FileManager.default.fileExists(atPath: fixtures.path) else {
            throw XCTSkip("Build the ebook reader to check its upstream fixtures.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ConversionEngine(toolsDirectory: root.appendingPathComponent(".tools/bin"))
        for name in ["sample-unicode-uncompressed", "sample-unicode-huffdic", "sample-cp1252", "sample-multimedia",
                     "sample-ncx", "sample-dict-infl2", "sample-obfuscated-fonts", "sample-textread"] {
            let source = fixtures.appendingPathComponent(name + ".mobi")
            let output = directory.appendingPathComponent(name + ".epub")
            try engine.convert(source, to: output)
            let entries = try ArchiveConverter.manifest(output, format: "zip")
            XCTAssertEqual(entries.first?.path, "mimetype")
            let raw = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: false)
            try ExternalTool.run(tool, arguments: ["-e", "-o", raw.path, "--", source.path], workDirectory: raw)
            let originalEntries = try ArchiveConverter.manifest(raw.appendingPathComponent(name + ".epub"), format: "zip")
            XCTAssertEqual(entries.filter { !$0.path.hasSuffix(".html") }, originalEntries.filter { !$0.path.hasSuffix(".html") })
            let header = try Data(contentsOf: output).prefix(30)
            XCTAssertEqual(Array(header[8..<10]), [0, 0], "The EPUB mimetype must be stored without compression.")
            XCTAssertEqual(Array(header[28..<30]), [0, 0], "The EPUB mimetype must not have ZIP extra fields.")
            try DocumentConverter.validate(output, format: "epub")
        }
        let original = try Data(contentsOf: fixtures.appendingPathComponent("sample-unicode-uncompressed.mobi"))
        var recoveryFolders = Set<String>()
        for extensionName in ["mobi", "azw", "azw3"] {
            let source = directory.appendingPathComponent("book.\(extensionName)")
            let renamed = directory.appendingPathComponent("automatic-\(extensionName).epub")
            try original.write(to: renamed)
            let record = try engine.convertRenamedFile(from: source, to: renamed,
                historyDirectory: directory.appendingPathComponent("history"))
            recoveryFolders.insert(record.backupURL.deletingLastPathComponent().lastPathComponent)
            try DocumentConverter.validate(renamed, format: "epub")
            _ = try ConversionEngine.undo(record)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
        let source = directory.appendingPathComponent("book.mobi")
        let text = directory.appendingPathComponent("book.txt")
        XCTAssertEqual(engine.conversionRoute(from: source, to: engine.catalog.format(forExtension: "txt")!)?.map(\.id), ["epub", "txt"])
        try engine.convert(source, to: text)
        XCTAssertTrue(try String(contentsOf: text, encoding: .utf8).contains("sample for testing libmobi"))
        let recordOffset = original[78..<82].reduce(0) { ($0 << 8) | Int($1) }
        for (name, offset, bytes) in [("encrypted", recordOffset + 12, [UInt8(0), 1]),
                                       ("too-large", recordOffset + 4, [0xff, 0xff, 0xff, 0xff]),
                                       ("bad-offset", 78, [0, 0, 0, 0])] {
            var invalid = original
            invalid.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            let input = directory.appendingPathComponent(name + ".mobi")
            let output = directory.appendingPathComponent(name + ".epub")
            try invalid.write(to: input)
            XCTAssertThrowsError(try engine.convert(input, to: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: input), invalid)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".allomer-") }), recoveryFolders)
    }
}
