import Foundation

struct GIFMetadata {
    struct Frame {
        let delay: Double
        let controlOffset: UInt64?
    }
    let width: Int
    let height: Int
    let frames: [Frame]
    let plays: Int
    let profile: Data?
    let paletteRanges: [Range<UInt64>]
    let profileRange: Range<UInt64>?
    let version: FileVersion
    let is89a: Bool

    init(_ url: URL) throws {
        let version = try FileVersion(url)
        self.version = version
        guard (13...536_870_912).contains(version.size) else {
            throw ConversionError.message("GIF input must be up to 512 MiB.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = UInt64(version.size)
        var offset: UInt64 = 0
        var window = Data(), windowStart: UInt64 = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        func read(_ count: Int) throws -> Data {
            guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
                throw ConversionError.message("The GIF has an incomplete block.")
            }
            if offset < windowStart || offset + UInt64(count) > windowStart + UInt64(window.count) {
                try file.seek(toOffset: offset)
                window = try file.read(upToCount: max(65_536, count)) ?? Data()
                windowStart = offset
            }
            let start = Int(offset - windowStart)
            guard start + count <= window.count else { throw ConversionError.message("The GIF could not be read.") }
            let data = window.subdata(in: start..<start + count)
            offset += UInt64(count)
            return data
        }
        func skip(_ count: Int) throws {
            guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
                throw ConversionError.message("The GIF has an invalid block length.")
            }
            offset += UInt64(count)
        }
        func blocks(collect: Bool = false) throws -> Data {
            var data = Data()
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ConversionError.message("GIF metadata reading exceeded 120 seconds.") }
                let count = Int(try read(1)[0])
                if count == 0 { return data }
                if collect {
                    guard data.count + count <= 16 * 1024 * 1024 else {
                        throw ConversionError.message("GIF application metadata exceeds 16 MiB.")
                    }
                    data.append(try read(count))
                } else { try skip(count) }
            }
        }
        func word(_ data: Data, _ index: Int) -> Int { Int(data[index]) | Int(data[index + 1]) << 8 }
        let header = try read(13)
        is89a = header.prefix(6) == Data("GIF89a".utf8)
        guard is89a || header.prefix(6) == Data("GIF87a".utf8) else {
            throw ConversionError.message("The file has no GIF header.")
        }
        width = word(header, 6); height = word(header, 8)
        guard width > 0, height > 0, width <= 32_000_000 / height else {
            throw ConversionError.message("A GIF canvas exceeds 32 million pixels or has invalid dimensions.")
        }
        let globalPalette = header[10] & 0x80 != 0
        var palettes: [Range<UInt64>] = []
        func palette(_ flags: UInt8) throws {
            let start = offset
            try skip(3 << (Int(flags & 7) + 1))
            palettes.append(start..<offset)
        }
        if globalPalette { try palette(header[10]) }
        var decodedFrames: [Frame] = []
        var control: UInt64?, delay = 0.1, repeats: Int?, icc: Data?
        var iccRange: Range<UInt64>?
        while true {
            try Task.checkCancellation()
            switch try read(1)[0] {
            case 0x21:
                switch try read(1)[0] {
                case 0xf9:
                    let start = offset
                    let block = try read(6)
                    guard block[0] == 4, block[5] == 0, control == nil else {
                        throw ConversionError.message("The GIF has an invalid frame control block.")
                    }
                    control = start + 2
                    delay = Double(word(block, 2)) / 100
                case 0xff:
                    let start = offset - 2
                    guard try read(1)[0] == 11 else { throw ConversionError.message("The GIF application block is invalid.") }
                    let identifier = try read(11)
                    let isLoop = identifier == Data("NETSCAPE2.0".utf8) || identifier == Data("ANIMEXTS1.0".utf8)
                    let isICC = identifier == Data("ICCRGBG1012".utf8)
                    let data = try blocks(collect: isLoop || isICC)
                    if isLoop {
                        guard data.count == 3, data[0] == 1, repeats == nil else {
                            throw ConversionError.message("The GIF has an invalid repeat count.")
                        }
                        let stored = word(data, 1)
                        repeats = stored == 0 ? 0 : stored + 1
                    } else if isICC {
                        guard !data.isEmpty, icc == nil else { throw ConversionError.message("The GIF color profile is invalid.") }
                        icc = data
                        iccRange = start..<offset
                    }
                case 0x01:
                    throw ConversionError.message("GIF plain-text rendering is not supported. The source was kept.")
                default: _ = try blocks()
                }
            case 0x2c:
                let descriptor = try read(9)
                let left = word(descriptor, 0), top = word(descriptor, 2)
                let frameWidth = word(descriptor, 4), frameHeight = word(descriptor, 6)
                guard frameWidth > 0, frameHeight > 0, left + frameWidth <= width, top + frameHeight <= height,
                      decodedFrames.count < 10_000 else {
                    throw ConversionError.message("A GIF frame exceeds its canvas or the animation limits.")
                }
                let localPalette = descriptor[8] & 0x80 != 0
                guard localPalette || globalPalette else { throw ConversionError.message("A GIF frame has no color palette.") }
                if localPalette { try palette(descriptor[8]) }
                guard (2...8).contains(try read(1)[0]) else {
                    throw ConversionError.message("The GIF has an invalid color code size.")
                }
                _ = try blocks()
                decodedFrames.append(Frame(delay: delay, controlOffset: control))
                control = nil; delay = 0.1
            case 0x3b:
                guard !decodedFrames.isEmpty, control == nil, offset == size, try FileVersion(url) == version else {
                    throw ConversionError.message("The GIF ended with missing frames, trailing data, or a changed source.")
                }
                frames = decodedFrames; plays = repeats ?? 1; profile = icc
                paletteRanges = palettes; profileRange = iccRange
                return
            default:
                throw ConversionError.message("The GIF contains an unknown block.")
            }
        }
    }
}
