import CoreGraphics
import Darwin
import Foundation

private final class BitmapSubtitleWriter {
    let output: FileHandle
    let language: String
    var failure: Error?
    private var pending: (start: Int64, end: Int64, text: String)?
    private var lastStart: Int64 = -1
    private var count = 0
    private var bytes = 0

    init(output: FileHandle, language: String) {
        self.output = output
        self.language = language
    }

    private func writePending(until next: Int64? = nil) throws {
        guard let cue = pending else { return }
        let end = next.map { cue.end < 0 ? $0 : min(cue.end, $0) } ?? cue.end
        guard end >= cue.start else {
            throw Failure.message("The final subtitle picture has no known end time.")
        }
        pending = nil
        // A replacement at the same time means the previous picture was never displayed.
        if end == cue.start { return }
        count += 1
        func timestamp(_ value: Int64) -> String {
            String(format: "%02lld:%02lld:%02lld,%03lld", value / 3_600_000,
                   value / 60_000 % 60, value / 1000 % 60, value % 1000)
        }
        let data = Data("\(count)\n\(timestamp(cue.start)) --> \(timestamp(end))\n\(cue.text)\n\n".utf8)
        bytes += data.count
        guard count <= 100_000, bytes <= 16 * 1024 * 1024 else {
            throw Failure.message("Recognized subtitles exceed 100,000 cues or 16 MiB of text.")
        }
        try output.write(contentsOf: data)
    }

    func accept(start: Int64, end: Int64, pixels: UnsafePointer<UInt8>?, width: Int32, height: Int32) throws {
        guard start >= 0, start >= lastStart, end == -1 || end >= start,
              pixels == nil || end == -1 || end > start else {
            throw Failure.message("The subtitle pictures have invalid or unordered times.")
        }
        lastStart = start
        try writePending(until: start)
        guard let pixels else {
            guard width == 0, height == 0 else { throw Failure.message("The subtitle clear event is invalid.") }
            return
        }
        let width = Int(width), height = Int(height)
        guard width > 0, height > 0, width <= 32_000, height <= 32_000, width * height <= 32_000_000,
              let provider = CGDataProvider(dataInfo: nil, data: pixels, size: width * height * 4,
                    releaseData: { _, _, _ in }),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure.message("The subtitle picture exceeds its image bounds.")
        }
        // The decoder owns the pixels until this synchronous recognition call returns.
        let text = try recognize(image, language: language).map { $0.text.string }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.message("A subtitle picture has no readable text. The source was kept.")
        }
        pending = (start, end, text)
    }

    func finish() throws {
        try writePending()
        guard count > 0 else { throw Failure.message("The subtitle track contains no readable picture cues.") }
    }
}

func recognizeSubtitles(_ input: URL, to output: URL, track: Int, language: String) throws {
    guard (1...256).contains(track), language.utf8.count <= 64 else {
        throw Failure.message("The subtitle track or text language is invalid.")
    }
    let descriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw Failure.message("The subtitle output could not be created safely.") }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    let writer = BitmapSubtitleWriter(output: file, language: language)
    var error = [CChar](repeating: 0, count: 1024)
    let status = input.path.withCString { path in
        decode_bitmap_subtitles(path, Int32(track), { context, start, end, pixels, width, height in
            guard let context else { return 1 }
            let writer = Unmanaged<BitmapSubtitleWriter>.fromOpaque(context).takeUnretainedValue()
            do {
                try autoreleasepool { try writer.accept(start: start, end: end, pixels: pixels, width: width, height: height) }
                return 0
            } catch {
                writer.failure = error
                return 1
            }
        }, Unmanaged.passUnretained(writer).toOpaque(), &error, 1024)
    }
    if let failure = writer.failure { throw failure }
    guard status == 0 else { throw Failure.message(String(cString: error)) }
    try writer.finish()
}
