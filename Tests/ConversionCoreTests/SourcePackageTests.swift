import Darwin
import Foundation
import ImageIO
import XCTest
@testable import ConversionCore

final class SourcePackageTests: XCTestCase {
    private func engineWithTools() throws -> ConversionEngine {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["webconvert", "webguard"].allSatisfy({ FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the native web helpers before checking Icon Composer projects.")
        }
        return try ConversionEngine(toolsDirectory: tools)
    }
    private func makeProject(at source: URL) throws {
        let assets = source.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("{\"groups\":[{\"layers\":[{\"image-name\":\"Shape.svg\"}]}]}".utf8)
            .write(to: source.appendingPathComponent("icon.json"))
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"128\" height=\"128\"><rect width=\"128\" height=\"128\" fill=\"#dc2814\"/></svg>".utf8)
            .write(to: assets.appendingPathComponent("Shape.svg"))
    }

    func testIconProjectArtworkFormatsAndUndo() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Icon artwork \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let source = work.appendingPathComponent("Artwork.icon")
        try makeProject(at: source)
        let hash = try sourceContentHash(source)
        let engine = try engineWithTools()
        let outputs = Set(engine.availableOutputs(for: source).map(\.id))
        XCTAssertTrue(Set(["avif", "bmp", "gif", "heic", "jpeg", "png", "tiff", "webp"]).isSubset(of: outputs))
        XCTAssertFalse(outputs.contains("zip"))
        for ext in ["avif", "bmp", "gif", "heic", "jpg", "png", "tiff", "webp"] {
            let target = work.appendingPathComponent("converted-artwork.\(ext)")
            try engine.convert(source, to: target)
            XCTAssertNotNil(ImageConverter.detectedType(at: target), ext)
            XCTAssertEqual(try engine.detectedFormat(at: target)?.id, engine.catalog.format(for: target)?.id, ext)
            XCTAssertEqual(try sourceContentHash(source), hash)
            XCTAssertThrowsError(try engine.convert(source, to: target))
        }
        let renamed = work.appendingPathComponent("Artwork.jpg")
        try manager.moveItem(at: source, to: renamed)
        let record = try engine.convertRenamedFile(from: source, to: renamed,
            historyDirectory: work.appendingPathComponent("history"))
        XCTAssertEqual(ImageConverter.detectedType(at: renamed), "public.jpeg")
        XCTAssertEqual(try sourceContentHash(record.backupURL), hash)
        XCTAssertTrue(try SourceVersion(record.snapshotURL).isPackage)
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try sourceContentHash(source), hash)
        XCTAssertFalse(manager.fileExists(atPath: renamed.path))
        try manager.moveItem(at: source, to: renamed)
        let kept = try engine.convertRenamedFile(from: source, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), keepOriginal: true)
        XCTAssertEqual(try sourceContentHash(source), hash)
        XCTAssertTrue(try SourceVersion(source).isPackage)
        let beforeUndo = try SourceVersion(source)
        _ = try ConversionEngine.undo(kept)
        XCTAssertEqual(try SourceVersion(source), beforeUndo)
        XCTAssertEqual(try sourceContentHash(source), hash)
        XCTAssertFalse(manager.fileExists(atPath: renamed.path))
        for keep in [false, true] {
            try manager.moveItem(at: source, to: renamed)
            XCTAssertEqual(try engine.detectedFormat(at: renamed)?.id, "icon_composer")
            let arrival = try engine.convertRenamedFile(from: renamed, to: renamed,
                historyDirectory: work.appendingPathComponent("history"), keepOriginal: keep,
                detectedSourceID: "icon_composer")
            XCTAssertEqual(ImageConverter.detectedType(at: renamed), "public.jpeg")
            _ = try ConversionEngine.undo(arrival)
            XCTAssertTrue(try SourceVersion(renamed).isPackage)
            XCTAssertEqual(try sourceContentHash(renamed), hash)
            XCTAssertFalse(manager.fileExists(atPath: source.path))
            try manager.moveItem(at: renamed, to: source)
        }
    }

    @MainActor
    func testAutomaticIconProjectRename() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Watched icon \(UUID().uuidString)")
        let watched = work.appendingPathComponent("watched")
        try manager.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let source = watched.appendingPathComponent("Artwork.icon")
        try makeProject(at: source)
        let hash = try sourceContentHash(source)
        let renamed = watched.appendingPathComponent("Artwork.png")
        let (results, continuation) = AsyncStream<Result<ConversionRecord, Error>>.makeStream()
        let service = AutomaticConverter(engine: try engineWithTools(), historyDirectory: work.appendingPathComponent("history")) {
            continuation.yield($0)
        }
        try service.start(folders: [watched])
        defer { service.stop(); continuation.finish() }
        let move = Process()
        move.executableURL = URL(fileURLWithPath: "/bin/mv")
        move.arguments = [source.path, renamed.path]
        try move.run()
        move.waitUntilExit()
        XCTAssertEqual(move.terminationStatus, 0)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            continuation.finish()
        }
        defer { timeout.cancel() }
        var iterator = results.makeAsyncIterator()
        let result = await iterator.next()
        let record = try XCTUnwrap(result, "The directory rename was not converted.").get()
        XCTAssertEqual(ImageConverter.detectedType(at: renamed), "public.png")
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try sourceContentHash(source), hash)
        XCTAssertFalse(manager.fileExists(atPath: renamed.path))
    }

    func testPackageSnapshotHashLimitsAndAtomicExchange() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("Icon package café \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let source = work.appendingPathComponent("Original.icon")
        let assets = source.appendingPathComponent("Assets")
        try manager.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("{\"groups\":[]}".utf8).write(to: source.appendingPathComponent("icon.json"))
        let asset = assets.appendingPathComponent("Café 東京.svg")
        try Data("first pixels".utf8).write(to: asset)
        let version = try SourceVersion(source)
        XCTAssertTrue(version.isPackage)
        XCTAssertEqual(version.members.count, 3)
        let hash = try sourceContentHash(source)
        XCTAssertEqual(try sourceContentHash(asset), try fileHash(asset))
        XCTAssertThrowsError(try FileVersion(source))

        let snapshot = work.appendingPathComponent("Snapshot.icon")
        XCTAssertEqual(clonefile(source.path, snapshot.path, UInt32(CLONE_NOFOLLOW)), 0)
        XCTAssertEqual(try sourceContentHash(snapshot), hash)
        XCTAssertNotEqual(try SourceVersion(snapshot).inode, version.inode)
        try Data("other pixels".utf8).write(to: asset)
        XCTAssertEqual(try SourceVersion(source).root, version.root)
        XCTAssertNotEqual(try SourceVersion(source), version)
        XCTAssertNotEqual(try sourceContentHash(source), hash)
        XCTAssertEqual(try sourceContentHash(snapshot), hash)
        try Data("first pixels".utf8).write(to: asset)
        XCTAssertEqual(try sourceContentHash(source), hash)

        let empty = assets.appendingPathComponent("Empty")
        try manager.createDirectory(at: empty, withIntermediateDirectories: false)
        XCTAssertNotEqual(try sourceContentHash(source), hash)
        try manager.removeItem(at: empty)
        let link = assets.appendingPathComponent("linked.svg")
        try manager.createSymbolicLink(at: link, withDestinationURL: asset)
        XCTAssertThrowsError(try SourceVersion(source))
        XCTAssertThrowsError(try sourceContentHash(source))
        try manager.removeItem(at: link)
        try manager.createSymbolicLink(at: link, withDestinationURL: work)
        XCTAssertThrowsError(try sourceContentHash(source))
        try manager.removeItem(at: link)
        let rootLink = work.appendingPathComponent("Link.icon")
        try manager.createSymbolicLink(at: rootLink, withDestinationURL: source)
        XCTAssertThrowsError(try SourceVersion(rootLink))
        XCTAssertThrowsError(try SourceVersion(work))

        let large = assets.appendingPathComponent("large.bin")
        XCTAssertTrue(manager.createFile(atPath: large.path, contents: nil))
        let file = try FileHandle(forWritingTo: large)
        try file.truncate(atOffset: 128 * 1024 * 1024 + 1)
        try file.close()
        XCTAssertThrowsError(try SourceVersion(source))
        try manager.removeItem(at: large)
        var deep = assets
        for _ in 0..<17 {
            deep.appendPathComponent("level")
            try manager.createDirectory(at: deep, withIntermediateDirectories: false)
        }
        XCTAssertThrowsError(try SourceVersion(source))
        try manager.removeItem(at: assets.appendingPathComponent("level"))

        let manifest = source.appendingPathComponent("icon.json")
        let originalManifest = try Data(contentsOf: manifest)
        try Data(repeating: 32, count: 1_048_577).write(to: manifest)
        XCTAssertThrowsError(try SourceVersion(source))
        try originalManifest.write(to: manifest)
        let fifo = assets.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try sourceContentHash(source))
        try manager.removeItem(at: fifo)
        let many = assets.appendingPathComponent("Many")
        try manager.createDirectory(at: many, withIntermediateDirectories: false)
        for index in 0..<4093 { try Data().write(to: many.appendingPathComponent("\(index)")) }
        XCTAssertThrowsError(try SourceVersion(source))
        try manager.removeItem(at: many)

        let output = work.appendingPathComponent("converted.png")
        try Data("output pixels".utf8).write(to: output)
        XCTAssertEqual(renameatx_np(AT_FDCWD, source.path, AT_FDCWD, output.path, UInt32(RENAME_SWAP)), 0)
        XCTAssertEqual(try sourceContentHash(output), hash)
        XCTAssertEqual(try SourceVersion(output).inode, version.inode)
        XCTAssertEqual(try Data(contentsOf: source), Data("output pixels".utf8))
        XCTAssertEqual(renameatx_np(AT_FDCWD, source.path, AT_FDCWD, output.path, UInt32(RENAME_SWAP)), 0)
        XCTAssertEqual(try sourceContentHash(source), hash)
        XCTAssertEqual(try SourceVersion(source).inode, version.inode)

        let renamed = work.appendingPathComponent("Original.png")
        try manager.moveItem(at: source, to: renamed)
        XCTAssertEqual(renameatx_np(AT_FDCWD, renamed.path, AT_FDCWD, output.path, UInt32(RENAME_SWAP)), 0)
        let record = ConversionRecord(id: UUID(), date: Date(), originalURL: source, convertedURL: renamed,
            backupURL: output, snapshotURL: snapshot, journalURL: work.appendingPathComponent("history.json"),
            sourceHash: hash, outputHash: try sourceContentHash(renamed), state: .prepared)
        try record.save()
        let recovered = try XCTUnwrap(ConversionRecord.loadHistory(from: work).first)
        XCTAssertEqual(recovered.state, .completed)
        let undone = try ConversionEngine.undo(recovered)
        XCTAssertEqual(undone.state, .undone)
        XCTAssertEqual(try sourceContentHash(source), hash)
        XCTAssertEqual(try SourceVersion(source).inode, version.inode)
        XCTAssertFalse(manager.fileExists(atPath: renamed.path))
        XCTAssertEqual(try Data(contentsOf: output), Data("output pixels".utf8))
    }
}
