import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import ConversionCore

final class AutomaticRenameTests: XCTestCase {
    @MainActor
    func testAutomaticConversionAfterExternalRename() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watched = directory.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = watched.appendingPathComponent("original.png")
        let renamed = watched.appendingPathComponent("original.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(original as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let originalBytes = try Data(contentsOf: original)
        let (results, continuation) = AsyncStream<Result<ConversionRecord, Error>>.makeStream()
        let service = AutomaticConverter(engine: try ConversionEngine(), historyDirectory: directory.appendingPathComponent("history")) {
            continuation.yield($0)
        }
        try service.start(folders: [watched])
        defer { service.stop(); continuation.finish() }
        let mover = Process()
        mover.executableURL = URL(fileURLWithPath: "/bin/mv")
        mover.arguments = [original.path, renamed.path]
        try mover.run()
        mover.waitUntilExit()
        XCTAssertEqual(mover.terminationStatus, 0)
        let timeout = Task {
            try await Task.sleep(for: .seconds(8))
            continuation.finish()
        }
        defer { timeout.cancel() }
        var iterator = results.makeAsyncIterator()
        let first = await iterator.next()
        let record = try XCTUnwrap(first, "The external rename did not trigger a conversion.").get()
        XCTAssertEqual(ImageConverter.detectedType(at: renamed), "public.jpeg")
        XCTAssertEqual(try Data(contentsOf: record.backupURL), originalBytes)
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("history").path).count, 1)
        await service.stopAndWait()
    }
    func testFileEventsReportBothNamesAndAnInode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.png")
        let renamed = directory.appendingPathComponent("original.jpg")
        try Data("fixture".utf8).write(to: original)
        let (events, continuation) = AsyncStream<[FileEvent]>.makeStream()
        let watcher = try FolderEvents(folders: [directory]) { continuation.yield($0) }
        defer { watcher.stop(); continuation.finish() }
        try FileManager.default.moveItem(at: original, to: renamed)
        let timeout = Task {
            try await Task.sleep(for: .seconds(5))
            continuation.finish()
        }
        defer { timeout.cancel() }
        var renames: [FileEvent] = []
        for await batch in events {
            renames += batch.filter(\.isFileRename)
            if Set(renames.map { $0.url.lastPathComponent }).isSuperset(of: ["original.png", "original.jpg"]) { break }
        }
        let before = try XCTUnwrap(renames.first { $0.url.lastPathComponent == "original.png" })
        let after = try XCTUnwrap(renames.first { $0.url.lastPathComponent == "original.jpg" })
        XCTAssertNotNil(before.inode)
        XCTAssertEqual(before.inode, after.inode)
    }
}
