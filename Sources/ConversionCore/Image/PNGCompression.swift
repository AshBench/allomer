import Darwin
import Foundation
import zlib

enum PNGCompression {
    // Recompress the native writer's filtered bytes. Keep pixel data, filters, and metadata intact.
    static func recompress(_ file: URL, level: Int) throws {
        let limit = 512 * 1024 * 1024
        // PDF rendering allows 256 megapixels. This covers 16-bit RGBA rows without buffering them.
        let expandedLimit = 2 * 1024 * 1024 * 1024
        let version = try FileVersion(file)
        guard (0...9).contains(level), version.size > 0, version.size <= limit else {
            throw ConversionError.message("PNG compression needs a level from 0 to 9 and a file up to 512 MiB.")
        }
        let temporary = file.deletingLastPathComponent().appendingPathComponent("png-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw ConversionError.message("The compressed PNG could not be opened.")
        }
        let input = try FileHandle(forReadingFrom: file), output = try FileHandle(forWritingTo: temporary)
        defer { try? input.close(); try? output.close() }
        var decoder = z_stream(), encoder = z_stream()
        guard inflateInit_(&decoder, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ConversionError.message("The PNG decoder could not start.")
        }
        defer { inflateEnd(&decoder) }
        guard deflateInit_(&encoder, Int32(level), zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ConversionError.message("The PNG compressor could not start.")
        }
        defer { deflateEnd(&encoder) }
        var decoded = [UInt8](repeating: 0, count: 65_536)
        var encoded = [UInt8](repeating: 0, count: 65_536)
        var written = 0, expanded = 0
        let idat = Data("IDAT".utf8)
        func number(_ bytes: Data) -> UInt32 { bytes.reduce(0) { ($0 << 8) | UInt32($1) } }
        func bytes(_ number: UInt32) -> Data {
            var value = number.bigEndian
            return Data(bytes: &value, count: 4)
        }
        func read(_ count: Int) throws -> Data {
            let data = try input.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ConversionError.message("The generated PNG is incomplete.") }
            return data
        }
        func write(_ data: Data) throws {
            written += data.count
            guard written <= limit else { throw ConversionError.message("The compressed PNG exceeds 512 MiB.") }
            try output.write(contentsOf: data)
        }
        func crc(_ data: Data, starting: uLong = 0) -> uLong {
            data.withUnsafeBytes { crc32(starting, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        }
        func compress(_ data: UnsafeRawBufferPointer, finish: Bool = false) throws {
            encoder.next_in = UnsafeMutablePointer(mutating: data.bindMemory(to: Bytef.self).baseAddress)
            encoder.avail_in = uInt(data.count)
            var status: Int32
            repeat {
                try Task.checkCancellation()
                status = encoded.withUnsafeMutableBytes { buffer in
                    encoder.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    encoder.avail_out = uInt(buffer.count)
                    return deflate(&encoder, finish ? Z_FINISH : Z_NO_FLUSH)
                }
                if status == Z_BUF_ERROR, !finish, encoder.avail_in == 0 { break }
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw ConversionError.message("PNG compression failed.")
                }
                let count = encoded.count - Int(encoder.avail_out)
                if count > 0 {
                    let chunk = Data(encoded.prefix(count))
                    try write(bytes(UInt32(count)))
                    try write(idat)
                    try write(chunk)
                    try write(bytes(UInt32(crc(chunk, starting: crc(idat)))))
                }
            } while finish ? status != Z_STREAM_END : encoder.avail_in > 0 || encoder.avail_out == 0
        }
        let signature = try read(8)
        guard signature == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw ConversionError.message("The generated file is not PNG.")
        }
        try write(signature)
        var sawData = false, endedStream = false, finishedData = false
        while true {
            try Task.checkCancellation()
            let header = try read(8), length = Int(number(Data(header.prefix(4)))), type = Data(header.suffix(4))
            guard length <= limit, try input.offset() + UInt64(length) + 4 <= version.size else {
                throw ConversionError.message("A generated PNG chunk has an invalid length.")
            }
            let imageData = type == idat
            if imageData {
                guard !finishedData else { throw ConversionError.message("PNG image chunks are out of order.") }
                sawData = true
            } else {
                if sawData, !finishedData {
                    guard endedStream else { throw ConversionError.message("The PNG image stream is incomplete.") }
                    try compress(UnsafeRawBufferPointer(start: nil, count: 0), finish: true)
                    finishedData = true
                }
                try write(header)
            }
            var remaining = length, checksum = crc(type)
            while remaining > 0 {
                try Task.checkCancellation()
                let data = try read(min(remaining, 65_536))
                remaining -= data.count
                checksum = crc(data, starting: checksum)
                if imageData {
                    guard !endedStream else { throw ConversionError.message("The PNG image stream has trailing bytes.") }
                    try data.withUnsafeBytes { buffer in
                        decoder.next_in = UnsafeMutablePointer(mutating: buffer.bindMemory(to: Bytef.self).baseAddress)
                        decoder.avail_in = uInt(buffer.count)
                        repeat {
                            var count = 0
                            let status = try decoded.withUnsafeMutableBytes { raster in
                                decoder.next_out = raster.bindMemory(to: Bytef.self).baseAddress
                                decoder.avail_out = uInt(raster.count)
                                let status = inflate(&decoder, Z_NO_FLUSH)
                                count = raster.count - Int(decoder.avail_out)
                                expanded += count
                                guard expanded <= expandedLimit else { throw ConversionError.message("The PNG image stream exceeds 2 GiB.") }
                                if count > 0 { try compress(UnsafeRawBufferPointer(rebasing: raster[..<count])) }
                                return status
                            }
                            if status == Z_STREAM_END {
                                guard decoder.avail_in == 0 else { throw ConversionError.message("The PNG image stream has trailing bytes.") }
                                endedStream = true
                                break
                            }
                            if status == Z_BUF_ERROR, decoder.avail_in == 0, count == 0 { break }
                            guard status == Z_OK else { throw ConversionError.message("The PNG image stream is corrupt.") }
                        } while decoder.avail_in > 0 || decoder.avail_out == 0
                    }
                } else {
                    try write(data)
                }
            }
            let storedCRC = try read(4)
            guard UInt32(checksum) == number(storedCRC) else { throw ConversionError.message("A PNG chunk checksum is invalid.") }
            if !imageData { try write(storedCRC) }
            if type == Data("IEND".utf8) {
                guard length == 0, finishedData, try input.offset() == version.size else {
                    throw ConversionError.message("The generated PNG has an invalid ending.")
                }
                break
            }
        }
        try output.close()
        try Task.checkCancellation()
        guard try FileVersion(file) == version else { throw ConversionError.message("The PNG changed during compression.") }
        guard rename(temporary.path, file.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
