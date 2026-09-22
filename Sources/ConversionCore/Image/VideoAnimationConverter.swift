import Foundation
import ImageIO

extension MediaConverter {
    func supportsAnimation(_ format: String) -> Bool {
        encoders.contains("png") && muxers.contains("image2")
            && (format == "webp" || (format == "gif" && encoders.contains("gif") && muxers.contains("gif")))
    }

    func convertAnimation(_ input: URL, to output: URL, format: String, tools: URL, options: ImageOptions) throws {
        guard supportsAnimation(format) else { throw ConversionError.message("The installed decoder cannot prepare this animation format.") }
        guard options.videoFrameRate.isFinite,
              (1...100).contains(options.videoFrameRate), (0...65_535).contains(options.videoMaxWidth),
              (0...65_535).contains(options.videoLoopCount), (2...256).contains(options.videoGIFColors) else {
            throw ConversionError.message("Video animation needs 1–100 frames per second, width and plays from 0–65,535, and 2–256 GIF colors, including transparency.")
        }
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= 512 * 1024 * 1024 else {
            throw ConversionError.message("Video animation input is limited to 512 MiB.")
        }
        let manager = FileManager.default
        let work = output.deletingLastPathComponent().appendingPathComponent("video-animation-\(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: work) }
        let info = try inspect(input, work: work)
        let videos = info.video.filter { $0.disposition?["attached_pic"] != 1 }
        guard videos.count == 1, let video = videos.first,
              let width = video.width, let height = video.height,
              width > 0, height > 0, width <= 32_000_000 / height else {
            throw ConversionError.message("Animation needs one video track with at most 32 million pixels per frame.")
        }
        guard !["smpte2084", "arib-std-b67"].contains(video.color_transfer ?? "") else {
            throw ConversionError.message("HDR video needs tone-mapping controls before animation conversion.")
        }
        let base = ["-hide_banner", "-v", "error", "-nostdin", "-n", "-xerror", "-max_alloc", "268435456",
                    "-cpucount", "1", "-threads", "1", "-filter_threads", "1", "-filter_complex_threads", "1",
                    "-err_detect", "explode", "-max_pixels", "32000000", "-protocol_whitelist", "file,pipe"]
                    + (info.format.format_name == "mpegts" ? ["-f", "mpegts"] : [])
                    + ["-i", input.path, "-map", "0:V:0", "-an", "-sn", "-dn", "-map_metadata", "-1"]
        let maxWidth = options.videoMaxWidth == 0 ? "iw*sar" : "min(iw*sar,\(options.videoMaxWidth))"
        let scale = "scale=w='max(1,\(maxWidth))':h=-1:flags=lanczos:reset_sar=1:out_primaries=bt709:out_transfer=srgb"
        let rate = options.videoFrameRate
        // Preserve source keeps every decoded frame and its own duration instead of resampling.
        let preserve = options.videoPreserveFrameRate
        let resample = preserve ? "" : "fps=\(rate):round=near:eof_action=pass,"
        let filter = "setpts=PTS-STARTPTS,\(resample)\(scale),format=rgba"
        // Probe the displayed canvas after rotation and pixel-aspect correction, before processing the full clip.
        let preview = work.appendingPathComponent("preview.png")
        try ExternalTool.run(ffmpeg, arguments: base + ["-vf", scale, "-frames:v", "1", "-c:v", "png",
            "-threads", "1", "-compression_level", "1", "-f", "image2", preview.path],
            workDirectory: work, workDirectoryByteLimit: 512 * 1024 * 1024)
        guard let probe = ImageConverter.inspect(preview), probe.frames == 1,
              let source = CGImageSourceCreateWithURL(preview as CFURL, nil) else {
            throw ConversionError.message("The video has no readable frame.")
        }
        let size = try ImageConverter.dimensions(ImageConverter.properties(source, 0))
        let edgeLimit = format == "webp" ? 16_383 : 65_535
        guard size.width <= edgeLimit, size.height <= edgeLimit else {
            throw ConversionError.message("The animation canvas exceeds this format's dimensions. Set a smaller maximum width.")
        }
        try manager.removeItem(at: preview)
        let frameLimit = min(10_000, 256_000_000 / (size.width * size.height))
        let sourceDurations = preserve ? try MediaTiming.frameDurations(input: input, ffmpeg: ffmpeg, work: work,
            inputOptions: info.format.format_name == "mpegts" ? ["-f", "mpegts"] : [], limit: frameLimit) : []
        let encoded = work.appendingPathComponent("encoded.\(format)")
        let count: Int
        if format == "gif" {
            let palette = ",split[pixels][colors];[colors]palettegen=max_colors=\(options.videoGIFColors):alpha_threshold=128:bounded_histogram=1:stats_mode=single[palette];"
                + "[pixels][palette]paletteuse=new=1:cache_limit=32:dither=\(options.videoGIFDither ? "bayer" : "none")"
            let repeats = options.videoLoopCount == 1 ? -1 : max(0, options.videoLoopCount - 1)
            try ExternalTool.run(ffmpeg, arguments: base + ["-vf", filter + palette,
                "-frames:v", String(frameLimit + 1), "-fps_mode", "passthrough", "-c:v", "gif", "-threads", "1",
                "-loop", String(repeats), "-final_delay", String(preserve
                    ? max(1, Int(((sourceDurations.last ?? 0.01) * 100).rounded())) : Int((100 / rate).rounded())),
                "-f", "gif", encoded.path],
                workDirectory: work, workDirectoryByteLimit: 512 * 1024 * 1024)
            if preserve {
                let written = try GIFMetadata(encoded).frames.count
                guard written <= sourceDurations.count else {
                    throw ConversionError.message("The encoded GIF has more frames than the video.")
                }
                try GIFEncoder.setDelays(encoded, delays: sourceDurations.prefix(written).map {
                    max(0.01, ($0 * 100).rounded() / 100)
                })
            }
            count = try validateVideoGIF(encoded, size: size, frameLimit: frameLimit, options: options,
                                         preserveDurations: sourceDurations)
        } else {
            try ExternalTool.run(ffmpeg, arguments: base + ["-vf", filter, "-frames:v", String(frameLimit + 1),
                "-fps_mode", "passthrough", "-c:v", "png", "-threads", "1", "-compression_level", "1", "-f", "image2",
                "frame-%06d.png"], workDirectory: work, workDirectoryByteLimit: 1_073_741_824)
            count = try manager.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).count
            guard (1...frameLimit).contains(count) else {
                throw ConversionError.message("The animation exceeds 10,000 frames or 256 million total pixels, or has no frames.")
            }
            let durations: [Int]
            if preserve {
                guard count <= sourceDurations.count else {
                    throw ConversionError.message("The animation has more frames than the video.")
                }
                durations = sourceDurations.prefix(count).map { max(1, Int(($0 * 1000).rounded())) }
            } else {
                durations = (0..<count).map { index -> Int in
                    let start = Int((Double(index) * 1000.0 / rate).rounded())
                    let end = Int((Double(index + 1) * 1000.0 / rate).rounded())
                    return end - start
                }
            }
            try WebPConverter.writeAnimation(frames: work, to: output, width: size.width, height: size.height,
                durations: durations, plays: options.videoLoopCount, tools: tools, options: options)
        }
        if let duration = video.duration.flatMap(Double.init) ?? (info.audio.isEmpty ? info.format.duration.flatMap(Double.init) : nil) {
            let produced = preserve ? sourceDurations.prefix(count).reduce(0, +) : Double(count) / rate
            let allowance = preserve ? (sourceDurations.last ?? 0) + 0.02 : 1 / rate + 0.02
            guard duration.isFinite, duration > 0, abs(produced - duration) <= allowance else {
                throw ConversionError.message("The animation duration differs from the video track.")
            }
        }
        guard try FileVersion(input) == version else {
            throw ConversionError.message("The video changed during animation conversion.")
        }
        if format == "gif" { try manager.moveItem(at: encoded, to: output) }
    }

    private func validateVideoGIF(_ output: URL, size: (width: Int, height: Int), frameLimit: Int,
                                  options: ImageOptions, preserveDurations: [Double] = []) throws -> Int {
        let metadata = try ImageConverter.validateGIF(output, tools: ffmpeg.deletingLastPathComponent(), work: output.deletingLastPathComponent())
        let count = metadata.frames.count
        guard (1...frameLimit).contains(count), metadata.width == size.width, metadata.height == size.height,
              metadata.plays == options.videoLoopCount, metadata.frames.allSatisfy({ $0.delay > 0 }) else {
            throw ConversionError.message("The encoded GIF changed its size, frame count, repeats, or delay.")
        }
        let duration = metadata.frames.reduce(0) { $0 + $1.delay }
        let expected = options.videoPreserveFrameRate
            ? preserveDurations.prefix(count).map { max(0.01, ($0 * 100).rounded() / 100) }.reduce(0, +)
            : Double(count) / options.videoFrameRate
        guard abs(duration - expected) <= 0.021 else {
            throw ConversionError.message("The encoded GIF changed the frame timing.")
        }
        return count
    }
}
