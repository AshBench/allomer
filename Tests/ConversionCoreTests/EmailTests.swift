import Foundation
import XCTest

@testable import ConversionCore

final class EmailTests: XCTestCase {
    func testEmailRoutesHeadersAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("mailfile").path) else {
            throw XCTSkip("Build the email converter to check email conversion.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("email.eml")
        let original = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/email-values.eml"))
        try original.write(to: source)
        let wrapped = directory.appendingPathComponent("email.emlx")
        let restored = directory.appendingPathComponent("restored.eml")
        try engine.convert(source, to: wrapped)
        try engine.convert(wrapped, to: restored)
        XCTAssertEqual(try Data(contentsOf: restored), original)
        let message = directory.appendingPathComponent("email.msg")
        try engine.convert(source, to: message)
        XCTAssertEqual(Array(try Data(contentsOf: message).prefix(8)), [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
        let html = directory.appendingPathComponent("headers.html")
        try engine.convert(message, to: html)
        XCTAssertTrue(try String(contentsOf: html, encoding: .utf8).contains("X-Original-Field"))
        var emailOptions = EmailOptions()
        emailOptions.includeHeaders = false
        let plain = directory.appendingPathComponent("body.txt")
        try engine.convert(message, to: plain, settings: .init(emailOptions: emailOptions))
        let text = try String(contentsOf: plain, encoding: .utf8)
        XCTAssertTrue(text.contains("Second line."))
        XCTAssertFalse(text.contains("X-Original-Field"))
        for (input, format) in [(source, "msg"), (message, "txt"), (wrapped, "html")] {
            let old = directory.appendingPathComponent("automatic-\(format).\(input.pathExtension)")
            let renamed = old.deletingPathExtension().appendingPathExtension(format)
            let bytes = try Data(contentsOf: input)
            try bytes.write(to: renamed)
            let record = try engine.convertRenamedFile(from: old, to: renamed,
                historyDirectory: directory.appendingPathComponent("history"), settings: .init(emailOptions: emailOptions))
            if format != "msg" {
                XCTAssertFalse(try String(contentsOf: renamed, encoding: .utf8).contains("X-Original-Field"))
            }
            _ = try ConversionEngine.undo(record)
            XCTAssertEqual(try Data(contentsOf: old), bytes)
        }
        let failedInput = directory.appendingPathComponent("bad.emlx")
        let failedOutput = directory.appendingPathComponent("bad.docx")
        try Data("999999\nSubject: incomplete\n\nshort".utf8).write(to: failedInput)
        XCTAssertThrowsError(try engine.convert(failedInput, to: failedOutput))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedOutput.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
