import CoreGraphics
import Foundation
import ImageIO
import XCTest
import zlib

@testable import ConversionCore

final class PNGCompressionTests: XCTestCase {
    @MainActor
    func testPNGCompressionPreservesStreamAndRejectsDamage() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("PNG compression \(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let file = work.appendingPathComponent("generated.png")
        func integer(_ value: UInt32) -> Data {
            var big = value.bigEndian
            return Data(bytes: &big, count: 4)
        }
        func chunk(_ type: String, _ payload: Data) -> Data {
            let content = Data(type.utf8) + payload
            let crc = content.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            return integer(UInt32(payload.count)) + content + integer(UInt32(crc))
        }
        var raw = Data(), state: UInt32 = 719
        for _ in 0..<512 {
            raw.append(0)
            for _ in 0..<(128 * 4) {
                state = state &* 1_664_525 &+ 1_013_904_223
                raw.append(UInt8(state >> 24))
            }
        }
        var compressedSize = compressBound(uLong(raw.count))
        var compressed = Data(count: Int(compressedSize))
        let status = compressed.withUnsafeMutableBytes { output in
            raw.withUnsafeBytes { input in
                compress2(output.bindMemory(to: Bytef.self).baseAddress, &compressedSize,
                    input.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), 6)
            }
        }
        XCTAssertEqual(status, Z_OK)
        compressed.count = Int(compressedSize)
        let header = Data([137, 80, 78, 71, 13, 10, 26, 10])
            + chunk("IHDR", integer(128) + integer(512) + Data([8, 6, 0, 0, 0]))
            + chunk("tEXt", Data("Title\0Original caption".utf8))
        let ending = chunk("tEXt", Data("Comment\0After image data".utf8)) + chunk("IEND", Data())
        var original = header + chunk("IDAT", Data())
        for start in stride(from: 0, to: compressed.count, by: 8191) {
            original += chunk("IDAT", compressed.subdata(in: start..<min(start + 8191, compressed.count)))
        }
        original += chunk("IDAT", Data()) + ending
        for level in 0...9 {
            try original.write(to: file)
            try PNGCompression.recompress(file, level: level)
            let result = try Data(contentsOf: file)
            XCTAssertTrue(result.starts(with: header))
            XCTAssertEqual(result.suffix(ending.count), ending)
            var offset = header.count, stream = Data()
            while offset < result.count - ending.count {
                let length = result[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
                XCTAssertEqual(result[(offset + 4)..<(offset + 8)], Data("IDAT".utf8))
                stream += result[(offset + 8)..<(offset + 8 + length)]
                offset += length + 12
            }
            var actual = Data(count: raw.count), count = uLong(raw.count)
            let decoded = actual.withUnsafeMutableBytes { output in
                stream.withUnsafeBytes { input in
                    uncompress(output.bindMemory(to: Bytef.self).baseAddress, &count,
                        input.bindMemory(to: Bytef.self).baseAddress, uLong(input.count))
                }
            }
            XCTAssertEqual(decoded, Z_OK)
            XCTAssertEqual(actual, raw)
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        }
        var badCRC = original
        badCRC[header.count - 1] ^= 1
        var damaged: [Data] = [badCRC, Data(original.dropLast()), original + Data([0])]
        damaged.append(header + chunk("IDAT", Data(compressed.dropLast(3))) + ending)
        damaged.append(header + chunk("IDAT", compressed + Data([0])) + ending)
        let interrupted = header + chunk("IDAT", compressed) + chunk("tEXt", Data())
        damaged.append(interrupted + chunk("IDAT", Data()) + ending)
        damaged.append(header + chunk("IEND", Data()))
        damaged.append(header + integer(UInt32.max) + Data("IDAT".utf8))
        for bytes in damaged {
            try bytes.write(to: file)
            XCTAssertThrowsError(try PNGCompression.recompress(file, level: 6))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(try manager.contentsOfDirectory(atPath: work.path), [file.lastPathComponent])
        }
        try original.write(to: file)
        for level in [-1, 10] { XCTAssertThrowsError(try PNGCompression.recompress(file, level: level)) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try PNGCompression.recompress(file, level: 6)
        }
        do { try await cancelled.value; XCTFail("Cancelled PNG compression succeeded") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: work.path), [file.lastPathComponent])
        var options = try JSONDecoder().decode(ImageOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options.pngCompressionLevel, 6)
        options.pngCompressionLevel = 9
        XCTAssertEqual(try JSONDecoder().decode(ImageOptions.self, from: JSONEncoder().encode(options)), options)
        let engine = try ConversionEngine()
        let bitmap = work.appendingPathComponent("automatic.bmp")
        try engine.convert(file, to: bitmap)
        let before = try Data(contentsOf: bitmap)
        let renamed = bitmap.deletingPathExtension().appendingPathExtension("png")
        try manager.moveItem(at: bitmap, to: renamed)
        let record = try engine.convertRenamedFile(from: bitmap, to: renamed,
            historyDirectory: work.appendingPathComponent("history"), settings: .init(imageOptions: options))
        XCTAssertEqual(record.state, .completed)
        XCTAssertEqual(ImageConverter.detectedType(at: renamed), "public.png")
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: bitmap), before)
    }
}
