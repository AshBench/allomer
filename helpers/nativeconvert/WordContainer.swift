import Foundation

func normalizedDocumentText(_ value: String) -> String {
    value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

// Rebuild only the container emitted by AppKit's DOC writer, never an input DOC.
// Some native outputs omit FAT entries for their own table and directory sectors.
// Stream bytes and the native directory tree stay intact. MS-CFB sections 2.2–2.6.
func nativeWordContainer(_ data: Data, text: String) throws -> Data {
    let invalid = Failure.message("The native Word writer produced an unsupported container layout.")
    guard data.count >= 512, data.count <= 512 * 1024 * 1024, data.count % 512 == 0,
          data.starts(with: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) else { throw invalid }
    func number(_ offset: Int, _ width: Int = 4) -> Int {
        (0..<width).reduce(0) { $0 | Int(data[offset + $1]) << (8 * $1) }
    }
    guard number(26, 2) == 3, number(28, 2) == 0xfffe, number(30, 2) == 9,
          number(32, 2) == 6, number(40) == 0, number(56) == 4096 else { throw invalid }
    let directory = (number(48) + 1) * 512
    guard directory >= 512, directory <= data.count - 1024 else { throw invalid }
    let names = ["Root Entry", "1Table", "WordDocument", "\u{5}SummaryInformation", "\u{5}DocumentSummaryInformation"]
    var streams: [Range<Int>] = []
    for index in 0..<8 {
        let entry = directory + index * 128
        if index >= names.count {
            guard data[entry + 66] == 0 else { throw invalid }
            continue
        }
        let nameSize = number(entry + 64, 2)
        guard (2...64).contains(nameSize), nameSize % 2 == 0,
              String(data: data[entry..<entry + nameSize - 2], encoding: .utf16LittleEndian) == names[index],
              number(entry + nameSize - 2, 2) == 0,
              data[entry + 66] == (index == 0 ? 5 : 2), number(entry + 124) == 0 else { throw invalid }
        let start = number(entry + 116), length = number(entry + 120)
        if index == 0 {
            let offset = (start + 1) * 512
            guard length == 128, offset <= data.count - length,
                  data[offset..<offset + length].allSatisfy({ $0 == 0 }) else { throw invalid }
        } else {
            guard length >= 4096, length <= data.count, start < data.count / 512 else { throw invalid }
            let end = start + (length + 511) / 512
            guard (end + 1) * 512 <= directory else { throw invalid }
            streams.append(start..<end)
        }
    }
    var streamEnd = 0
    for stream in streams.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        guard stream.lowerBound == streamEnd else { throw invalid }
        streamEnd = stream.upperBound
    }
    guard streamEnd == number(76) else { throw invalid }
    // AppKit emits one uncompressed text piece. Check its declared range and bytes
    // directly; the native reader cannot reopen the larger DIFAT containers.
    // MS-DOC: FibRgFcLcb97, PlcPcd, Pcd, and FcCompressed.
    let word = (streams[1].lowerBound + 1) * 512
    let table = (streams[0].lowerBound + 1) * 512
    let tableBytes = streams[0].count * 512, wordBytes = streams[1].count * 512
    guard number(word, 2) == 0xa5ec, number(word + 2, 2) == 0xc1,
          number(word + 10, 2) & 0x8300 == 0x0200,
          number(word + 32, 2) == 14, number(word + 62, 2) == 22,
          number(word + 152, 2) == 108,
          [80, 84, 92, 96, 100, 104].allSatisfy({ number(word + $0) == 0 }) else { throw invalid }
    let clx = number(word + 418), clxSize = number(word + 422), count = number(word + 76)
    guard clxSize == 21, clx <= tableBytes - clxSize, count <= 8_000_001 else { throw invalid }
    let piece = table + clx
    guard data[piece] == 2, number(piece + 1) == 16, number(piece + 5) == 0,
          number(piece + 9) == count, number(piece + 13, 2) == 0,
          number(piece + 19, 2) == 0 else { throw invalid }
    let textOffset = number(piece + 15)
    guard textOffset >= 1536, textOffset <= wordBytes, textOffset & 0xc0000000 == 0,
          count * 2 <= wordBytes - textOffset,
          let decoded = String(data: data[word + textOffset..<word + textOffset + count * 2],
                               encoding: .utf16LittleEndian) else { throw invalid }
    let before = normalizedDocumentText(text), after = normalizedDocumentText(decoded)
    guard after == before || after == before + "\n" else {
        throw Failure.message("The native document output changed the text or paragraph order.")
    }
    let tableStart = streamEnd + 2
    var fatCount = 0, difatCount = 0
    while true {
        let nextFAT = (tableStart + fatCount + difatCount + 127) / 128
        let nextDIFAT = (max(0, nextFAT - 109) + 126) / 127
        if nextFAT == fatCount, nextDIFAT == difatCount { break }
        fatCount = nextFAT; difatCount = nextDIFAT
    }
    let difatStart = tableStart + fatCount
    guard (difatStart + difatCount + 1) * 512 <= 512 * 1024 * 1024 else { throw invalid }
    let free = UInt32.max, end = UInt32.max - 1
    var fat = [UInt32](repeating: free, count: fatCount * 128)
    for range in streams + [streamEnd..<tableStart] {
        for sector in range { fat[sector] = sector == range.upperBound - 1 ? end : UInt32(sector + 1) }
    }
    for sector in tableStart..<difatStart { fat[sector] = UInt32.max - 2 }
    for sector in difatStart..<difatStart + difatCount { fat[sector] = UInt32.max - 3 }
    var output = Data(data.prefix((streamEnd + 1) * 512))
    output.append(data[directory..<directory + 1024])
    func put(_ value: UInt32, at offset: Int) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { output.replaceSubrange(offset..<offset + 4, with: $0) }
    }
    put(UInt32(fatCount), at: 44); put(UInt32(streamEnd), at: 48)
    put(end, at: 60); put(0, at: 64)
    put(difatCount == 0 ? end : UInt32(difatStart), at: 68); put(UInt32(difatCount), at: 72)
    for index in 0..<109 { put(index < fatCount ? UInt32(tableStart + index) : free, at: 76 + index * 4) }
    let root = (streamEnd + 1) * 512
    put(end, at: root + 116); put(0, at: root + 120)
    // This helper is built only for little-endian Apple Silicon.
    fat.withUnsafeBytes { output.append(contentsOf: $0) }
    for index in 0..<difatCount {
        var sector = [UInt32](repeating: free, count: 128)
        for item in 0..<127 {
            let table = 109 + index * 127 + item
            if table < fatCount { sector[item] = UInt32(tableStart + table).littleEndian }
        }
        sector[127] = (index == difatCount - 1 ? end : UInt32(difatStart + index + 1)).littleEndian
        sector.withUnsafeBytes { output.append(contentsOf: $0) }
    }
    return output
}
