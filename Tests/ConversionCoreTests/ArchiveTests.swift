import CArchive
import Foundation
import XCTest

@testable import ConversionCore

final class ArchiveTests: XCTestCase {
    func testArchiveFormatsKeepEveryFileByte() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try FormatCatalog()
        let formats = catalog.formats.filter { ArchiveConverter.formats.contains($0.id) }
        XCTAssertEqual(formats.count, 5)
        let original = directory.appendingPathComponent("payload.bin")
        let bytes = Data((0..<1_048_577).map { UInt8($0 % 251) })
        try bytes.write(to: original)
        XCTAssertEqual(try fileHash(original), "5769f52bc3eef28afa39c6fc68cadb7d0bd69812ae3a3d71452f519ec3c7aa56")
        for sourceFormat in formats {
            let folder = directory.appendingPathComponent(sourceFormat.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let source = folder.appendingPathComponent("payload.bin.\(sourceFormat.extensions[0])")
            do { try ArchiveConverter.convert(original, to: source, from: nil, to: sourceFormat) }
            catch { return XCTFail("File to \(sourceFormat.id): \(error)") }
            for target in formats {
                let targetFolder = folder.appendingPathComponent(target.id)
                try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: false)
                let output = targetFolder.appendingPathComponent("payload.bin.\(target.extensions[0])")
                do { try ArchiveConverter.convert(source, to: output, from: sourceFormat, to: target) }
                catch { return XCTFail("\(sourceFormat.id) to \(target.id): \(error)") }
                let contents = try ArchiveConverter.manifest(output, format: target.id)
                XCTAssertEqual(contents.count, 1)
                XCTAssertEqual(contents.first?.path, "payload.bin")
                XCTAssertEqual(contents.first?.size, Int64(bytes.count))
            }
        }
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let zip = try XCTUnwrap(formats.first { $0.id == "zip" })
        for preset in ArchiveOptions.Compression.allCases {
            var options = ArchiveOptions()
            options.compression = preset
            options.includeTopLevelFolder = true
            let output = directory.appendingPathComponent("\(preset).zip")
            try ArchiveConverter.convert(original, to: output, from: nil, to: zip, options: options)
            XCTAssertEqual(Set(try ArchiveConverter.manifest(output, format: "zip").map(\.path)), ["payload", "payload/payload.bin"])
        }
        let bad = directory.appendingPathComponent("broken.zip")
        try Data("not an archive".utf8).write(to: bad)
        XCTAssertThrowsError(try ArchiveConverter.manifest(bad, format: "zip"))
        let empty = directory.appendingPathComponent("empty")
        try Data().write(to: empty)
        for target in formats {
            let output = directory.appendingPathComponent("empty.\(target.extensions[0])")
            do { try ArchiveConverter.convert(empty, to: output, from: nil, to: target) }
            catch { return XCTFail("Empty file to \(target.id): \(error)") }
            XCTAssertEqual(try ArchiveConverter.manifest(output, format: target.id).first?.size, 0)
        }
        func fixture(_ url: URL, paths: [String]) throws {
            let writer = try XCTUnwrap(archive_write_new())
            defer { archive_write_free(writer) }
            XCTAssertEqual(archive_write_set_format_pax_restricted(writer), ARCHIVE_OK)
            XCTAssertEqual(archive_write_open_filename(writer, url.path), ARCHIVE_OK)
            for path in paths {
                let entry = try XCTUnwrap(archive_entry_new())
                defer { archive_entry_free(entry) }
                archive_entry_set_pathname_utf8(entry, path)
                let folder = path.hasSuffix("/")
                archive_entry_set_filetype(entry, UInt32(folder ? S_IFDIR : S_IFREG))
                archive_entry_set_perm(entry, 0o755)
                archive_entry_set_size(entry, folder ? 0 : Int64(bytes.count))
                XCTAssertEqual(archive_write_header(writer, entry), ARCHIVE_OK)
                if !folder { XCTAssertEqual(bytes.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }, bytes.count) }
                XCTAssertEqual(archive_write_finish_entry(writer), ARCHIVE_OK)
            }
            XCTAssertEqual(archive_write_close(writer), ARCHIVE_OK)
        }
        let engine = try ConversionEngine()
        let multiple = directory.appendingPathComponent("multiple.tar")
        try fixture(multiple, paths: ["./", "folder/", "folder/Café 東京.bin", "another.bin"])
        let expected = try ArchiveConverter.manifest(multiple, format: "tar").sorted { $0.path < $1.path }
        for target in formats where target.id != "gzip" {
            let output = directory.appendingPathComponent("multiple.\(target.extensions[0])")
            if output == multiple { continue }
            try engine.convert(multiple, to: output)
            XCTAssertEqual(try ArchiveConverter.manifest(output, format: target.id).sorted { $0.path < $1.path }, expected)
        }
        let failed = directory.appendingPathComponent("multiple.gz")
        XCTAssertThrowsError(try engine.convert(multiple, to: failed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        let corruptGzip = directory.appendingPathComponent("bad-checksum.gz")
        var damaged = try Data(contentsOf: directory.appendingPathComponent("gzip/payload.bin.gz"))
        damaged[damaged.count - 8] ^= 1
        try damaged.write(to: corruptGzip)
        XCTAssertThrowsError(try ArchiveConverter.manifest(corruptGzip, format: "gzip"))
        for (index, paths) in [["../outside"], ["/absolute"], ["repeat", "repeat"]].enumerated() {
            let unsafe = directory.appendingPathComponent("unsafe-\(index).tar")
            try fixture(unsafe, paths: paths)
            let output = directory.appendingPathComponent("unsafe-\(index).zip")
            XCTAssertThrowsError(try engine.convert(unsafe, to: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        let priorName = directory.appendingPathComponent("renamed.tar")
        let changedName = directory.appendingPathComponent("renamed.zip")
        let originalArchive = try Data(contentsOf: multiple)
        try originalArchive.write(to: changedName)
        let record = try engine.convertRenamedFile(from: priorName, to: changedName,
            historyDirectory: directory.appendingPathComponent("history"))
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: priorName), originalArchive)
    }
}
