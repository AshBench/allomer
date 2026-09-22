import CoreGraphics
import ImageIO
import XCTest
@testable import ConversionCore

final class FormatDetectionTests: XCTestCase {
    func testContentDetectionAndArchiveContainers() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let engine = try ConversionEngine()
        for (id, text) in [
            ("json", #"{"name":"Café","count":3}"#),
            ("yaml", "name: Café\ncount: 3\n"), ("toml", "name = \"Café\"\ncount = 3\n"),
            ("svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"3\" height=\"4\"/></svg>"),
            ("opml", "<?xml version=\"1.0\"?><opml version=\"2.0\"><body/></opml>"),
            ("dae", "<COLLADA xmlns=\"http://www.collada.org/2005/11/COLLADASchema\" version=\"1.4.1\"/>"),
            ("plist", "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>name</key><string>Café</string></dict></plist>"),
            ("ipynb", #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#),
            ("gltf", #"{"asset":{"version":"2.0"},"scenes":[]}"#),
            ("usda", "#usda 1.0\ndef Xform \"Root\" {}\n"),
            ("vtt", "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello\n"),
            ("rtf", "{\\rtf1\\ansi Hello}"), ("html", "<!DOCTYPE html><html><body>Hello</body></html>")
        ] {
            let file = work.appendingPathComponent(UUID().uuidString + ".wrong")
            let bytes = Data(text.utf8)
            try bytes.write(to: file)
            XCTAssertEqual(try engine.detectedFormat(at: file)?.id, id, id)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
        let markdown = work.appendingPathComponent("notes.md")
        try Data("Title: A plain paragraph\n".utf8).write(to: markdown)
        XCTAssertEqual(try engine.detectedFormat(at: markdown)?.id, "markdown")
        for (id, object) in [
            ("ipynb", ["nbformat": 4, "nbformat_minor": 5, "metadata": [:],
                       "cells": [["cell_type": "markdown", "metadata": [:], "source": String(repeating: "x", count: 1_048_577)]]] as [String: Any]),
            ("gltf", ["asset": ["version": "2.0"], "extras": String(repeating: "x", count: 1_048_577)] as [String: Any])
        ] {
            let large = work.appendingPathComponent("large.\(id)")
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: large)
            XCTAssertEqual(try engine.detectedFormat(at: large)?.id, id)
        }
        let empty = work.appendingPathComponent("empty.png")
        try Data().write(to: empty)
        XCTAssertNil(try engine.detectedFormat(at: empty))
        let link = work.appendingPathComponent("link.png")
        try manager.createSymbolicLink(at: link, withDestinationURL: markdown)
        XCTAssertThrowsError(try engine.detectedFormat(at: link))

        let picture = work.appendingPathComponent("actually-a-picture.txt")
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(picture as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        XCTAssertEqual(try engine.detectedFormat(at: picture)?.id, "png")

        let zip = work.appendingPathComponent("document.zip")
        try ArchiveConverter.makeZIP(to: zip, paths: ["[Content_Types].xml", "word/document.xml"]) { name, url in
            let content = name == "word/document.xml"
                ? "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body/></w:document>"
                : "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>"
            try Data(content.utf8).write(to: url)
        }
        XCTAssertEqual(try engine.detectedFormat(at: zip)?.id, "docx")
        let svg = work.appendingPathComponent("drawing.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8).write(to: svg)
        for (source, output, expected) in [(svg, "drawing.gz", "svgz"), (markdown, "text.gz", "gzip"), (markdown, "text.tgz", "tgz")] {
            let target = work.appendingPathComponent(output)
            try ArchiveConverter.convert(source, to: target, from: engine.catalog.format(for: source),
                to: XCTUnwrap(engine.catalog.format(for: target)))
            XCTAssertEqual(try engine.detectedFormat(at: target)?.id, expected)
        }
    }

    func testInPlaceConversionUndoAndRecoveryKeepTheArrivalName() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let engine = try ConversionEngine()
        let bytes = Data(#"{"name":"Café","count":3}"#.utf8)
        let history = work.appendingPathComponent("history")
        for keep in [false, true] {
            let file = work.appendingPathComponent("arrived-\(keep).yaml")
            try bytes.write(to: file)
            let record = try engine.convertRenamedFile(from: file, to: file, historyDirectory: history,
                keepOriginal: keep, detectedSourceID: "json")
            let output = try Data(contentsOf: file)
            XCTAssertEqual(record.originalURL, record.convertedURL)
            XCTAssertEqual(record.detectedSourceExtension, "json")
            XCTAssertEqual(record.snapshotURL.pathExtension, "json")
            XCTAssertNotEqual(output, bytes)
            XCTAssertEqual(try Data(contentsOf: record.backupURL), bytes)
            if keep {
                XCTAssertEqual(try Data(contentsOf: record.visibleOriginalURL), bytes)
                try Data("Edited copy".utf8).write(to: record.visibleOriginalURL)
                XCTAssertThrowsError(try ConversionEngine.undo(record))
                try bytes.write(to: record.visibleOriginalURL)
                try manager.moveItem(at: record.visibleOriginalURL, to: record.undoneOriginalURL)
                var pending = record
                pending.state = .undoPrepared
                try pending.save()
                let recovered = try XCTUnwrap(ConversionRecord.loadHistory(from: history).first { $0.id == record.id })
                XCTAssertEqual(recovered.state, .completed)
                XCTAssertEqual(try Data(contentsOf: record.visibleOriginalURL), bytes)
            }
            var undone = try ConversionEngine.undo(record)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(try Data(contentsOf: undone.backupURL), output)
            XCTAssertFalse(manager.fileExists(atPath: record.visibleOriginalURL.path))
            undone.state = .undoPrepared
            try undone.save()
            let recovered = try XCTUnwrap(ConversionRecord.loadHistory(from: history).first { $0.id == record.id })
            XCTAssertEqual(recovered.state, .undone)
            let cleared = try BackupRetention.clean([recovered], options: BackupRetentionOptions(), removeAll: true)
            XCTAssertEqual(cleared.removedCount, 1)
            XCTAssertTrue(cleared.issues.isEmpty, cleared.issues.description)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
        let occupied = work.appendingPathComponent("collision.json")
        let arrival = work.appendingPathComponent("collision.yaml")
        try Data("An existing file".utf8).write(to: occupied)
        try bytes.write(to: arrival)
        XCTAssertThrowsError(try engine.convertRenamedFile(from: arrival, to: arrival,
            historyDirectory: history, keepOriginal: true, detectedSourceID: "json"))
        XCTAssertEqual(try Data(contentsOf: arrival), bytes)
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "An existing file")
    }
}
