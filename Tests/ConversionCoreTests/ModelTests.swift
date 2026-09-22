import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import ConversionCore

final class ModelTests: XCTestCase {
    func testModelTexturesSettingsPublicationAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("modeltool").path) else {
            throw XCTSkip("Build the model helper to check model conversion.")
        }
        let manager = FileManager.default
        let engine = try ConversionEngine(toolsDirectory: tools)
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let manual = directory.appendingPathComponent("manual")
        try manager.createDirectory(at: manual, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("shape.obj")
        let original = Data("mtllib colors.mtl\nv 0 0 0\nv 2 0 0\nv 0 3 0\nvt 0 0\nvt 1 0\nvt 0 1\nusemtl colors\nf 1/1 2/2 3/3\n".utf8)
        try original.write(to: source)
        try Data("newmtl colors\nKd 1 1 1\nmap_Kd colors.png\n".utf8).write(to: directory.appendingPathComponent("colors.mtl"))
        let texture = directory.appendingPathComponent("colors.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(texture as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let textureBytes = try Data(contentsOf: texture)
        var options = ModelOptions()
        options.embedTextures = false
        options.binaryPLY = false
        let output = manual.appendingPathComponent("manual.glb")
        let resources = try engine.convert(source, to: output, settings: .init(modelOptions: options))
        XCTAssertEqual(resources.count, 1)
        try resources[0].verify(in: manual)
        let glb = try Data(contentsOf: output)
        let jsonLength = Int(glb.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }.littleEndian)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: glb.subdata(in: 20..<(20 + jsonLength))) as? [String: Any])
        let images = try XCTUnwrap(document["images"] as? [[String: Any]])
        let relative = try XCTUnwrap(images.first?["uri"] as? String)
        XCTAssertEqual(try Data(contentsOf: manual.appendingPathComponent(relative)), textureBytes)
        XCTAssertThrowsError(try engine.convert(source, to: output, settings: .init(modelOptions: options)))
        XCTAssertEqual(try Data(contentsOf: output), glb)
        XCTAssertEqual(try Data(contentsOf: source), original)
        for format in ["glb", "ply", "usdz"] {
            let old = directory.appendingPathComponent("automatic-\(format).obj")
            let renamed = old.deletingPathExtension().appendingPathExtension(format)
            try original.write(to: renamed)
            let record = try engine.convertRenamedFile(from: old, to: renamed,
                historyDirectory: directory.appendingPathComponent("history-\(format)"), settings: .init(modelOptions: options),
                keepOriginal: format == "glb")
            if record.keepOriginal == true { XCTAssertEqual(try Data(contentsOf: old), original) }
            let produced = record.resources ?? []
            if format == "usdz" { XCTAssertTrue(produced.isEmpty) }
            else {
                let resource = try XCTUnwrap(produced.first)
                try resource.verify(in: directory)
                if format == "ply" {
                    XCTAssertTrue(try String(contentsOf: renamed, encoding: .utf8).contains("format ascii 1.0"))
                }
                let companion = directory.appendingPathComponent(resource.directoryName)
                    .appendingPathComponent(try XCTUnwrap(resource.fileHashes.keys.first))
                let saved = try Data(contentsOf: companion)
                try Data("edited texture".utf8).write(to: companion)
                XCTAssertThrowsError(try ConversionEngine.undo(record))
                XCTAssertEqual(try Data(contentsOf: companion), Data("edited texture".utf8))
                try saved.write(to: companion)
                // Recover an Undo interrupted after moving its textures, before swapping the model.
                try resource.move(from: directory, to: record.backupURL.deletingLastPathComponent())
                var interrupted = record
                interrupted.state = .undoPrepared
                try interrupted.save()
                let recovered = try XCTUnwrap(ConversionRecord.loadHistory(from: record.journalURL.deletingLastPathComponent()).first)
                XCTAssertEqual(recovered.state, .completed)
                try resource.verify(in: directory)
            }
            let undone = try ConversionEngine.undo(record)
            XCTAssertEqual(undone.state, .undone)
            XCTAssertEqual(try Data(contentsOf: old), original)
            XCTAssertFalse(manager.fileExists(atPath: renamed.path))
            for resource in produced {
                try resource.verify(in: record.backupURL.deletingLastPathComponent())
                XCTAssertFalse(manager.fileExists(atPath: directory.appendingPathComponent(resource.directoryName).path))
            }
        }
        XCTAssertEqual(try Data(contentsOf: texture), textureBytes)
        let nonexistent = manual.appendingPathComponent("missing.obj")
        try original.write(to: nonexistent)
        XCTAssertThrowsError(try engine.convert(nonexistent, to: manual.appendingPathComponent("missing.glb")))
        XCTAssertFalse(manager.fileExists(atPath: manual.appendingPathComponent("missing.glb").path))
        let target = try XCTUnwrap(engine.catalog.format(forExtension: "usdz"))
        XCTAssertEqual(engine.conversionRoute(from: directory.appendingPathComponent("source.dae"), to: target)?.map(\.id), ["ply", "usdz"])
    }
}
