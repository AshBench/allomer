import Darwin
import Foundation
import zlib

enum PSDCompression {
    /// Keeps the PSD sections while preparing merged pixels for the native reader.
    static func prepare(_ input: URL, work: URL) throws -> URL? {
        let version = try FileVersion(input)
        guard version.size >= 26, version.size <= 512 * 1024 * 1024 else {
            throw ConversionError.message("PSD input must be between 26 bytes and 512 MiB.")
        }
        let sourceBytes = Int(version.size)
        let descriptor = open(input.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let source = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? source.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, try FileVersion(status) == version else {
            throw ConversionError.message("The PSD source changed before preparation.")
        }
        func read(_ count: Int) throws -> Data {
            let data = try source.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ConversionError.message("The PSD data is incomplete.") }
            return data
        }
        func number(_ bytes: Data) -> Int { bytes.reduce(0) { ($0 << 8) | Int($1) } }
        let header = try read(26)
        guard header.prefix(4) == Data("8BPS".utf8), number(header.subdata(in: 4..<6)) == 1 else { return nil }
        var offset = 26
        for _ in 0..<3 {
            guard offset <= sourceBytes - 4 else { throw ConversionError.message("A PSD section length is missing.") }
            try source.seek(toOffset: UInt64(offset))
            let length = number(try read(4))
            guard length <= sourceBytes - offset - 4 else { throw ConversionError.message("A PSD section exceeds the source file.") }
            offset += 4 + length
        }
        guard offset <= sourceBytes - 2 else { throw ConversionError.message("The PSD pixel data is missing.") }
        try source.seek(toOffset: UInt64(offset))
        let compression = number(try read(2))
        let channels = number(header.subdata(in: 12..<14))
        let height = number(header.subdata(in: 14..<18)), width = number(header.subdata(in: 18..<22))
        let depth = number(header.subdata(in: 22..<24))
        if (compression == 1 && depth <= 8) || (compression == 0 && depth != 1) { return nil }
        guard header.subdata(in: 6..<12).allSatisfy({ $0 == 0 }), [0, 1, 2, 3].contains(compression),
              (1...56).contains(channels), (1...30_000).contains(width), (1...30_000).contains(height),
              width <= 32_000_000 / height, [1, 8, 16, 32].contains(depth), compression != 3 || depth != 1,
              depth != 1 || (channels == 1 && number(header.subdata(in: 24..<26)) == 0) else {
            throw ConversionError.message("The PSD compression, dimensions, channels, or bit depth is unsupported.")
        }
        let rowBytes = (width * depth + 7) / 8
        let expectedBytes = rowBytes * height * channels
        let literalRowBytes = rowBytes + (rowBytes + 127) / 128
        let preparedBytes = depth == 1 ? (literalRowBytes + 2) * height : expectedBytes
        guard preparedBytes <= 536_870_912 - offset - 2 else {
            throw ConversionError.message("The prepared PSD exceeds the image reader's 512 MiB limit.")
        }
        if compression == 0, sourceBytes != offset + 2 + expectedBytes {
            throw ConversionError.message("The PSD bitmap data does not match its declared size.")
        }
        let output = work.appendingPathComponent("psd-\(UUID().uuidString).psd")
        let outputDescriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputDescriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let destination = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        var complete = false
        defer {
            try? destination.close()
            if !complete { try? FileManager.default.removeItem(at: output) }
        }
        try source.seek(toOffset: 0)
        var remaining = offset
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try read(min(remaining, 1_048_576))
            try destination.write(contentsOf: data)
            remaining -= data.count
        }
        try destination.write(contentsOf: Data([0, depth == 1 ? 1 : 0]))
        if depth == 1 {
            var lengths = Data()
            for _ in 0..<height { lengths.append(contentsOf: [UInt8(literalRowBytes >> 8), UInt8(truncatingIfNeeded: literalRowBytes)]) }
            try destination.write(contentsOf: lengths)
        }
        try source.seek(toOffset: UInt64(offset + 2))
        var decoder = z_stream()
        guard inflateInit_(&decoder, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ConversionError.message("The PSD decompressor could not start.")
        }
        defer { inflateEnd(&decoder) }
        var row = [UInt8](repeating: 0, count: rowBytes)
        var shuffled = depth == 32 ? row : []
        var buffered = Data()
        buffered.reserveCapacity(65_536 + rowBytes)
        var filled = 0, decoded = 0, consumed = offset + 2
        var ended = false
        func writeRow() throws {
            if compression == 3 {
                if depth == 16 {
                    var previous: UInt16 = 0
                    for index in stride(from: 0, to: rowBytes, by: 2) {
                        previous &+= (UInt16(row[index]) << 8) | UInt16(row[index + 1])
                        row[index] = UInt8(previous >> 8)
                        row[index + 1] = UInt8(truncatingIfNeeded: previous)
                    }
                } else {
                    for index in 1..<rowBytes { row[index] &+= row[index - 1] }
                    if depth == 32 {
                        for lane in 0..<4 {
                            for pixel in 0..<width { shuffled[pixel * 4 + lane] = row[lane * width + pixel] }
                        }
                    }
                }
            }
            if depth == 1 {
                for index in stride(from: 0, to: rowBytes, by: 128) {
                    let count = min(128, rowBytes - index)
                    buffered.append(UInt8(count - 1))
                    buffered.append(contentsOf: row[index..<(index + count)])
                }
            } else { buffered.append(contentsOf: compression == 3 && depth == 32 ? shuffled : row) }
            if buffered.count >= 65_536 {
                try destination.write(contentsOf: buffered)
                buffered.removeAll(keepingCapacity: true)
            }
            filled = 0
        }
        if compression == 0 {
            while consumed < sourceBytes {
                try Task.checkCancellation()
                row = Array(try read(rowBytes))
                consumed += rowBytes; decoded += rowBytes
                try writeRow()
            }
            ended = true
        }
        if compression == 1 {
            let rows = height * channels
            guard rows * 2 <= sourceBytes - consumed else { throw ConversionError.message("The PSD row length table is incomplete.") }
            let lengths = try read(rows * 2)
            consumed += lengths.count
            for index in 0..<rows {
                try Task.checkCancellation()
                let length = Int(lengths[index * 2]) * 256 + Int(lengths[index * 2 + 1])
                guard length <= sourceBytes - consumed else { throw ConversionError.message("A PSD packed row exceeds the source file.") }
                let packed = try read(length)
                consumed += length
                var cursor = 0, position = 0
                while cursor < packed.count {
                    let control = Int(packed[cursor]); cursor += 1
                    if control == 128 { continue }
                    let count = control < 128 ? control + 1 : 257 - control
                    guard count <= rowBytes - position else { throw ConversionError.message("A PSD packed row expands beyond its width.") }
                    if control < 128 {
                        guard count <= packed.count - cursor else { throw ConversionError.message("A PSD literal run is incomplete.") }
                        row.replaceSubrange(position..<(position + count), with: packed[cursor..<(cursor + count)])
                        cursor += count
                    } else {
                        guard cursor < packed.count else { throw ConversionError.message("A PSD repeated run is incomplete.") }
                        for byte in position..<(position + count) { row[byte] = packed[cursor] }
                        cursor += 1
                    }
                    position += count
                }
                guard position == rowBytes else { throw ConversionError.message("A PSD packed row does not fill its declared width.") }
                decoded += rowBytes
                try writeRow()
            }
            guard consumed == sourceBytes else { throw ConversionError.message("The PSD packed pixels have trailing bytes.") }
            ended = true
        }
        while !ended && consumed < sourceBytes {
            try Task.checkCancellation()
            guard !ended else { throw ConversionError.message("The PSD ZIP stream has trailing bytes.") }
            let data = try read(min(65_536, sourceBytes - consumed))
            consumed += data.count
            try data.withUnsafeBytes { bytes in
                decoder.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
                decoder.avail_in = uInt(bytes.count)
                repeat {
                    try Task.checkCancellation()
                    let available = rowBytes - filled
                    let result = row.withUnsafeMutableBytes { bytes in
                        decoder.next_out = bytes.bindMemory(to: Bytef.self).baseAddress!.advanced(by: filled)
                        decoder.avail_out = uInt(available)
                        return inflate(&decoder, Z_NO_FLUSH)
                    }
                    let count = available - Int(decoder.avail_out)
                    filled += count
                    decoded += count
                    guard decoded <= expectedBytes else { throw ConversionError.message("The PSD ZIP stream expands beyond its declared pixels.") }
                    if filled == rowBytes { try writeRow() }
                    if result == Z_STREAM_END {
                        guard decoder.avail_in == 0, consumed == sourceBytes else {
                            throw ConversionError.message("The PSD ZIP stream has trailing bytes.")
                        }
                        ended = true
                        break
                    }
                    if result == Z_BUF_ERROR, decoder.avail_in == 0, count == 0 { break }
                    guard result == Z_OK else { throw ConversionError.message("The PSD ZIP stream is corrupt.") }
                } while decoder.avail_in > 0 || decoder.avail_out == 0
            }
        }
        guard ended, filled == 0, decoded == expectedBytes else {
            throw ConversionError.message("The PSD ZIP stream does not contain all declared pixels.")
        }
        try destination.write(contentsOf: buffered)
        try destination.close()
        guard try FileVersion(output).size == offset + 2 + preparedBytes,
              fstat(descriptor, &status) == 0, try FileVersion(status) == version,
              try FileVersion(input) == version else {
            throw ConversionError.message("The PSD source or prepared data changed during decompression.")
        }
        complete = true
        return output
    }
}
