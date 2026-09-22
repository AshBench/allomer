import Foundation
import XCTest
@testable import ConversionCore

final class PSDCompressionTests: XCTestCase {
    func testIndependentZIPFixturesAndFailures() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("PSD ZIP \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        // Original sample planes encoded with psd-tools 1.17.4.
        let cases: [(depth: Int, mode: Int, compressed: String, raw: String)] = [
            (8, 2, "eJxjUPXKn7LzHrOGb9H0PQ/ZtANKAUAfBx4=", "ACVKb5S53gMoTXKXvOEGK1B1"),
            (8, 3, "eJxjUFXNV1W9p6rqq6q6R1VVW1UVACg1BD4=", "ACVKb5S53gMoTXKXvOEGK1B1"),
            (16, 2, "eJxjYFAX9lMrtZzjczj+VZFgq8WM+NVt+9ZevPLk93dlLi/ZQoMZzgAEAA+v", "AAAnE04mdTmcTMNf6nIRhTiYX6uGvq3R1OT79yMKSh1xMJhD"),
            (16, 3, "eJxjYFAXVhcutQSRr4pAZPxqEHnlCYj0kgWRAIybB+w=", "AAAnE04mdTmcTMNf6nIRhTiYX6uGvq3R1OT79yMKSh1xMJhD"),
            (32, 2, "eJxjYGBgsC348NH2w4ePdiZbttoB2XbTpk232wJkX7p02Q4obs/e3mEvNm26verSZfZANfbOh4/YB126bJ/48JE9UL19AwMDADGTJHo=", "AAAAAD1w8PE98PDxPjS0tT5w8PE+lpaXPrS0tT7S0tM+8PDxPweHiD8Wlpc/JaWmPzS0tT9Dw8Q/UtLTP2Hh4j9w8PE/gAAA"),
            (32, 3, "eJxjsGU4XNAg8IFB4CODHQPDNxs1OZtl8jbLgOwyObkjcnJH5eTsGRhO8PMn8fM/5ucHsr8isZX4BRL5BR7x8wMAzwMR8w==", "AAAAAD1w8PE98PDxPjS0tT5w8PE+lpaXPrS0tT7S0tM+8PDxPweHiD8Wlpc/JaWmPzS0tT9Dw8Q/UtLTP2Hh4j9w8PE/gAAA"),
            (16, 1, "AAcABwAHAAcABwAH/wADJxNOJgV1OZxMw18F6nIRhTiYBV+rhr6t0QXU5Pv3IwoFSh1xMJhD", "AAAnE04mdTmcTMNf6nIRhTiYX6uGvq3R1OT79yMKSh1xMJhD"),
            (32, 1, "AAsADQANAA0ADQAN/QAHPXDw8T3w8PELPjS0tT5w8PE+lpaXCz60tLU+0tLTPvDw8Qs/B4eIPxaWlz8lpaYLPzS0tT9Dw8Q/UtLTCT9h4eI/cPDxP4D/AA==", "AAAAAD1w8PE98PDxPjS0tT5w8PE+lpaXPrS0tT7S0tM+8PDxPweHiD8Wlpc/JaWmPzS0tT9Dw8Q/UtLTP2Hh4j9w8PE/gAAA")
        ]
        func prefix(depth: Int) -> Data {
            var data = Data("8BPS".utf8)
            for value in [1, 0, 0, 0, 3, 0, 2, 0, 3, depth, 3] {
                var big = UInt16(value).bigEndian
                withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
            }
            data.append(Data(repeating: 0, count: 12))
            return data
        }
        let input = work.appendingPathComponent("input.psd")
        for item in cases {
            let compressed = try XCTUnwrap(Data(base64Encoded: item.compressed))
            let raw = try XCTUnwrap(Data(base64Encoded: item.raw))
            let bytes = prefix(depth: item.depth) + Data([0, UInt8(item.mode)]) + compressed
            try bytes.write(to: input)
            let normalized = try XCTUnwrap(PSDCompression.prepare(input, work: work))
            XCTAssertEqual(try Data(contentsOf: normalized), prefix(depth: item.depth) + Data([0, 0]) + raw)
            XCTAssertEqual(try Data(contentsOf: input), bytes)
            XCTAssertNil(try PSDCompression.prepare(normalized, work: work))
            try manager.removeItem(at: normalized)
            for damaged in [Data(bytes.dropLast()), bytes + Data([0]), bytes + compressed] {
                try damaged.write(to: input)
                XCTAssertThrowsError(try PSDCompression.prepare(input, work: work))
                XCTAssertFalse(try manager.contentsOfDirectory(atPath: work.path).contains { $0.hasPrefix("psd-") })
            }
        }
        var bitmap = prefix(depth: 1)
        bitmap.replaceSubrange(12..<14, with: [0,1])
        bitmap.replaceSubrange(18..<22, with: [0,0,0,9])
        bitmap.replaceSubrange(24..<26, with: [0,0])
        try (bitmap + Data([0,0,255,128,0,0])).write(to: input)
        let preparedBitmap = try XCTUnwrap(PSDCompression.prepare(input, work: work))
        XCTAssertEqual(try Data(contentsOf: preparedBitmap), bitmap + Data([0,1,0,3,0,3,1,255,128,1,0,0]))
        try manager.removeItem(at: preparedBitmap)
        func big(_ value: Int) -> Data {
            var value = UInt32(value).bigEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        let resource = Data("8BIM".utf8) + Data([15,160,0,0]) + big(1_048_577)
            + Data(repeating: 91, count: 1_048_577) + Data([0])
        let sections = Data(prefix(depth: 8).prefix(26)) + big(0) + big(resource.count) + resource + big(0)
        let compressed = try XCTUnwrap(Data(base64Encoded: cases[0].compressed))
        let raw = try XCTUnwrap(Data(base64Encoded: cases[0].raw))
        try (sections + Data([0,2]) + compressed).write(to: input)
        let prepared = try XCTUnwrap(PSDCompression.prepare(input, work: work))
        XCTAssertEqual(try Data(contentsOf: prepared), sections + Data([0,0]) + raw)
        try manager.removeItem(at: prepared)
        let original = prefix(depth: 8) + Data([0,3]) + (try XCTUnwrap(Data(base64Encoded: cases[1].compressed)))
        try original.write(to: input)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        let required = ["cwebp", "webpguard", "webpanim", "webpanimguard", "cjxl", "jxlguard"]
        guard required.allSatisfy({ manager.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Build the WebP and JPEG XL helpers before checking PSD output routes.")
        }
        let engine = try ConversionEngine(toolsDirectory: tools)
        for ext in ["png", "jpg", "tiff", "webp", "jxl", "pdf", "ico", "icns"] {
            let output = work.appendingPathComponent("converted.\(ext)")
            try engine.convert(input, to: output)
            XCTAssertGreaterThan(try Data(contentsOf: output).count, 0)
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
        let renamed = work.appendingPathComponent("input.png")
        try manager.moveItem(at: input, to: renamed)
        let record = try engine.convertRenamedFile(from: input, to: renamed, historyDirectory: work.appendingPathComponent("history"))
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: input), original)
        var oversized = prefix(depth: 32)
        oversized.replaceSubrange(12..<14, with: [0,56])
        oversized.replaceSubrange(14..<22, with: [0,0,15,160,0,0,23,112])
        try (oversized + Data([0,2,120,156])).write(to: input)
        XCTAssertThrowsError(try PSDCompression.prepare(input, work: work))
        let link = work.appendingPathComponent("link.psd")
        try manager.createSymbolicLink(at: link, withDestinationURL: input)
        XCTAssertThrowsError(try PSDCompression.prepare(link, work: work))
    }
}
