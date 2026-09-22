import Foundation

enum MediaTiming {
    static let byteLimit = 64 * 1024 * 1024

    static func mxfBounds(input: URL, ffmpeg: URL, work: URL, video: String, audio: String,
                          inputOptions: [String], threads: String, timeout: TimeInterval) throws -> (videoStart: Double, videoEnd: Double, end: Double) {
        let timeline = work.appendingPathComponent("media-bounds-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: timeline) }
        try ExternalTool.run(ffmpeg, arguments: ["-hide_banner", "-v", "error", "-nostdin", "-xerror",
            "-max_alloc", "268435456", "-threads", threads, "-filter_threads", "1", "-err_detect", "explode",
            "-max_pixels", "32200000", "-protocol_whitelist", "file,pipe"] + inputOptions
            + ["-i", input.path] + arguments(stream: video, audioStream: audio),
            workDirectory: work, timeout: timeout, outputFile: timeline, outputLimit: byteLimit)
        let picture = try streamBounds(Reader(timeline)), sound = try streamBounds(Reader(timeline, stream: 1))
        return (max(0, picture.start), picture.end, max(picture.end, sound.end))
    }

    // Each decoded video frame's own duration in seconds, for writers that store per-frame delays.
    static func frameDurations(input: URL, ffmpeg: URL, work: URL, inputOptions: [String],
                               limit: Int, timeout: TimeInterval = 120) throws -> [Double] {
        let timeline = work.appendingPathComponent("media-frames-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: timeline) }
        try ExternalTool.run(ffmpeg, arguments: ["-hide_banner", "-v", "error", "-nostdin", "-xerror",
            "-max_alloc", "268435456", "-threads", "1", "-filter_threads", "1", "-err_detect", "explode",
            "-max_pixels", "32200000", "-protocol_whitelist", "file,pipe"] + inputOptions
            + ["-i", input.path] + arguments(stream: "0:V:0"),
            workDirectory: work, timeout: timeout, outputFile: timeline, outputLimit: byteLimit)
        let reader = try Reader(timeline)
        guard let first = try reader.next(), let scale = reader.scale else {
            throw ConversionError.message("The video has no decoded frames.")
        }
        var durations = [Double(first.duration) * scale]
        while let frame = try reader.next() {
            guard durations.count < limit else {
                throw ConversionError.message("The video exceeds the animation frame limit.")
            }
            durations.append(Double(frame.duration) * scale)
        }
        guard durations.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw ConversionError.message("The video has invalid frame timing.")
        }
        return durations
    }

    static func arguments(stream: String?, audioStream: String? = nil) -> [String] {
        // The wrapper carries frame metadata and references. It does not encode or hash pixels.
        var result: [String] = []
        if let stream {
            result += ["-map", stream, "-c:v", "wrapped_avframe", "-threads:v", "1", "-fps_mode:v", "passthrough",
                       "-enc_time_base:v", "filter"]
        }
        if let audioStream {
            result += ["-map", audioStream, "-c:a", "pcm_s16le", "-threads:a", "1"]
        }
        // Tracks are read separately. Do not retain picture references for cross-track sorting.
        return result + ["-max_interleave_delta", "1", "-f", "framecrc", "pipe:1"]
    }

    private struct Frame {
        let pts: Int64
        let duration: Int64

        func time(from origin: Int64, scale: Double) throws -> Double {
            let (ticks, overflow) = pts.subtractingReportingOverflow(origin)
            let seconds = Double(ticks) * scale
            guard !overflow, seconds.isFinite, seconds >= 0 else {
                throw ConversionError.message("The media timestamps are invalid.")
            }
            return seconds
        }
    }

    private final class Reader {
        let file: FileHandle
        let stream: Int
        var scale: Double?
        private var buffer = Data()
        private var cursor = 0
        private var previous: Int64?

        init(_ url: URL, stream: Int = 0) throws {
            guard try FileVersion(url).size <= byteLimit else {
                throw ConversionError.message("The media timeline exceeds 64 MiB.")
            }
            file = try FileHandle(forReadingFrom: url)
            self.stream = stream
        }

        deinit { try? file.close() }

        private func line() throws -> String? {
            while true {
                try Task.checkCancellation()
                if let end = buffer[cursor...].firstIndex(of: 10) {
                    let bytes = buffer[cursor..<end]
                    guard bytes.count <= 4096, let text = String(data: bytes, encoding: .utf8) else {
                        throw ConversionError.message("The media timeline contains an invalid record.")
                    }
                    cursor = end + 1
                    return text
                }
                buffer.removeSubrange(..<cursor)
                cursor = 0
                guard buffer.count <= 4096 else {
                    throw ConversionError.message("The media timeline record is too large.")
                }
                let more = try file.read(upToCount: 65_536) ?? Data()
                if more.isEmpty {
                    guard buffer.isEmpty else { throw ConversionError.message("The media timeline is incomplete.") }
                    return nil
                }
                buffer.append(more)
            }
        }

        func next() throws -> Frame? {
            while let text = try line() {
                if text.hasPrefix("#tb \(stream):") {
                    let parts = text.dropFirst(6).trimmingCharacters(in: .whitespaces).split(separator: "/")
                    guard scale == nil, parts.count == 2, let numerator = Int32(parts[0]),
                          let denominator = Int32(parts[1]), numerator > 0, denominator > 0 else {
                        throw ConversionError.message("The media clock could not be read.")
                    }
                    scale = Double(numerator) / Double(denominator)
                } else if !text.hasPrefix("#") {
                    let fields = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard fields.count >= 6, let index = Int(fields[0]), (0...1).contains(index) else {
                        throw ConversionError.message("The media timeline contains an invalid stream.")
                    }
                    if index != stream { continue }
                    guard scale != nil,
                          let pts = Int64(fields[2]), pts != Int64.min,
                          let duration = Int64(fields[3]), duration > 0,
                          let size = Int(fields[4]), size > 0,
                          previous.map({ pts > $0 }) ?? true else {
                        throw ConversionError.message("The media has missing or unordered frame timing.")
                    }
                    previous = pts
                    return Frame(pts: pts, duration: duration)
                }
            }
            return nil
        }
    }

    static func validate(source: URL, output: URL, ffmpeg: URL, work: URL,
                         inputOptions: [String], rate: VideoFrameRate, timeout: TimeInterval,
                         estimatesFinalDuration: Bool, usesFrameClock: Bool, audioPadding: Double? = nil,
                         includeVideo: Bool = true, sourceDuration: Double? = nil) throws {
        let decoded = work.appendingPathComponent("media-result-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: decoded) }
        try ExternalTool.run(ffmpeg, arguments: ["-hide_banner", "-v", "error", "-nostdin", "-xerror",
            "-max_alloc", "268435456", "-threads", "1", "-filter_threads", "1", "-err_detect", "explode",
            "-max_pixels", "32200000", "-protocol_whitelist", "file,pipe"] + inputOptions
            + ["-i", output.path] + arguments(stream: includeVideo ? "0:V:0" : nil,
                audioStream: audioPadding == nil ? nil : "0:a:0"), workDirectory: work, timeout: timeout,
            outputFile: decoded, outputLimit: byteLimit)
        try compare(source: source, result: decoded, rate: rate,
                    estimatesFinalDuration: estimatesFinalDuration, usesFrameClock: usesFrameClock,
                    audioPadding: audioPadding, includeVideo: includeVideo, sourceDuration: sourceDuration)
    }

    static func compare(source: URL, result: URL, rate: VideoFrameRate,
                        estimatesFinalDuration: Bool, usesFrameClock: Bool, audioPadding: Double? = nil,
                        includeVideo: Bool = true, sourceDuration: Double? = nil) throws {
        if let audioPadding, !audioPadding.isFinite || audioPadding < 0 {
            throw ConversionError.message("The audio timing allowance is invalid.")
        }
        if !includeVideo {
            guard let audioPadding else { throw ConversionError.message("The audio timing allowance is missing.") }
            let before = try streamBounds(Reader(source)), after = try streamBounds(Reader(result))
            if let sourceDuration {
                guard sourceDuration.isFinite, sourceDuration > 0,
                      abs(before.samplesDuration - sourceDuration) <= before.tick + 0.000_001 else {
                    throw ConversionError.message("The decoded source audio does not match its declared length.")
                }
            }
            let tolerance = 2 * audioPadding + max(before.tick, after.tick) + 0.000_001
            // Standalone audio starts at its first sample. Containers can add codec padding.
            guard abs(before.samplesDuration - after.samplesDuration) <= tolerance,
                  abs((before.end - before.start) - (after.end - after.start)) <= tolerance else {
                throw ConversionError.message("The output changed the decoded audio duration.")
            }
            return
        }
        let before = try Reader(source), after = try Reader(result)
        guard let firstSource = try before.next(), let firstResult = try after.next(),
              let sourceScale = before.scale, let resultScale = after.scale else {
            throw ConversionError.message("The video has no decoded frames.")
        }
        let interval = rate.value.map { 1 / $0 }
        let frameClock = usesFrameClock ? Double(firstResult.duration) * resultScale : 0
        let precision = max(sourceScale, resultScale, frameClock) + 0.000_001
        // Containers can shift the timestamp origin. Compare time from the first frame.
        var lastSource = firstSource, lastResult = firstResult
        if let interval {
            var count = 1
            while let frame = try after.next() {
                let time = try frame.time(from: firstResult.pts, scale: resultScale)
                guard abs(time - Double(count) * interval) <= precision else {
                    throw ConversionError.message("The encoded frame rate differs from the selected rate.")
                }
                lastResult = frame
                count += 1
            }
            while let frame = try before.next() { lastSource = frame }
        } else {
            while let frame = try before.next() {
                guard let converted = try after.next() else {
                    throw ConversionError.message("The encoded video lost frames.")
                }
                let sourceTime = try frame.time(from: firstSource.pts, scale: sourceScale)
                let resultTime = try converted.time(from: firstResult.pts, scale: resultScale)
                guard abs(sourceTime - resultTime) <= precision else {
                    throw ConversionError.message("The output cannot preserve this frame timing. Select a fixed frame rate.")
                }
                lastSource = frame
                lastResult = converted
            }
            guard try after.next() == nil else {
                throw ConversionError.message("The encoded video added frames.")
            }
        }
        let sourceEnd = try lastSource.time(from: firstSource.pts, scale: sourceScale)
            + Double(lastSource.duration) * sourceScale
        let resultEnd = try lastResult.time(from: firstResult.pts, scale: resultScale)
            + Double(lastResult.duration) * resultScale
        // ASF does not store each frame's duration. Its decoder supplies an estimate.
        let endPrecision = estimatesFinalDuration
            ? min(Double(lastSource.duration) * sourceScale, Double(lastResult.duration) * resultScale) : 0
        guard sourceEnd.isFinite, resultEnd.isFinite,
              abs(sourceEnd - resultEnd) <= max(precision, interval ?? 0, endPrecision) else {
            throw ConversionError.message("The output changed the final frame duration. Select another frame rate or container.")
        }
        if let audioPadding {
            let sourceAudio = try streamBounds(Reader(source, stream: 1))
            let resultAudio = try streamBounds(Reader(result, stream: 1))
            let tolerance = precision + audioPadding + max(sourceAudio.tick, resultAudio.tick)
            let sourceOrigin = Double(firstSource.pts) * sourceScale
            let resultOrigin = Double(firstResult.pts) * resultScale
            guard abs((sourceAudio.start - sourceOrigin) - (resultAudio.start - resultOrigin)) <= tolerance,
                  abs((sourceAudio.end - sourceOrigin) - (resultAudio.end - resultOrigin)) <= tolerance,
                  abs(sourceAudio.samplesDuration - resultAudio.samplesDuration) <= tolerance + audioPadding else {
                throw ConversionError.message("The output changed audio/video synchronization or audio duration.")
            }
        }
    }

    private static func streamBounds(_ reader: Reader) throws -> (start: Double, end: Double, samplesDuration: Double, tick: Double) {
        guard let first = try reader.next(), let scale = reader.scale else {
            throw ConversionError.message("The media stream has no decoded frames.")
        }
        var last = first, ticks = first.duration
        while let frame = try reader.next() {
            let (sum, overflow) = ticks.addingReportingOverflow(frame.duration)
            guard !overflow else { throw ConversionError.message("The media duration is too large.") }
            ticks = sum
            last = frame
        }
        let start = Double(first.pts) * scale
        let duration = Double(ticks) * scale
        let end = start + (try last.time(from: first.pts, scale: scale)) + Double(last.duration) * scale
        guard start.isFinite, end.isFinite, duration.isFinite else {
            throw ConversionError.message("The media timestamps are invalid.")
        }
        return (start, end, duration, scale)
    }
}
