import Foundation

enum AVIFConverter {
    static func isAvailable(in media: MediaConverter) -> Bool {
        media.encoders.contains("libaom-av1") && media.muxers.contains("avif")
    }

    static func convert(_ input: URL, to output: URL, media: MediaConverter,
                        options: ImageOptions) throws {
        guard isAvailable(in: media) else {
            throw ConversionError.message("The bundled AVIF encoder is unavailable.")
        }
        guard options.quality.isFinite, (0...1).contains(options.quality) else {
            throw ConversionError.message("Image quality must be between 0 and 1.")
        }
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= 512 * 1024 * 1024,
              let image = ImageConverter.inspect(input), image.frames == 1,
              image.type != "com.adobe.pdf" else {
            throw ConversionError.message("AVIF input must be one readable image up to 512 MiB.")
        }
        let work = output.deletingLastPathComponent()
        let prepared = work.appendingPathComponent("avif-input-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: prepared) }
        let png = FileFormat(id: "png", name: "PNG", category: "image", extensions: ["png"])
        try ImageConverter.convert(input, to: prepared, format: png, options: options)

        let quality = String(Int(((1 - options.quality) * 63).rounded()))
        let color = "setparams=colorspace=bt709:color_primaries=bt709:color_trc=iec61966-2-1"
        let filter = "[0:v]format=rgba,split=2[color-source][alpha-source];"
            + "[color-source]format=yuv444p,\(color)[color];"
            + "[alpha-source]alphaextract,format=gray,\(color)[alpha]"
        try ExternalTool.run(media.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-xerror",
            "-max_alloc", "268435456", "-max_pixels", "32000000", "-threads", "4",
            "-i", prepared.path, "-filter_complex", filter,
            "-map", "[color]", "-map", "[alpha]", "-map_metadata", "0",
            "-frames:v:0", "1", "-frames:v:1", "1", "-c:v", "libaom-av1",
            "-pix_fmt:v:0", "yuv444p", "-pix_fmt:v:1", "gray",
            "-colorspace:v:0", "bt709", "-colorspace:v:1", "bt709",
            "-color_primaries:v:0", "bt709", "-color_primaries:v:1", "bt709",
            "-color_trc:v:0", "iec61966-2-1", "-color_trc:v:1", "iec61966-2-1",
            "-usage:v:0", "allintra", "-usage:v:1", "allintra",
            "-still-picture:v:0", "1", "-still-picture:v:1", "1",
            "-cpu-used:v:0", "6", "-cpu-used:v:1", "6",
            "-row-mt:v:0", "1", "-row-mt:v:1", "1",
            "-crf:v:0", quality, "-crf:v:1", "0", "-b:v:0", "0", "-b:v:1", "0",
            "-f", "avif", output.path
        ], workDirectory: work, timeout: 120)
        guard try FileVersion(input) == version,
              let encoded = ImageConverter.inspect(output),
              encoded.type == "public.avif", encoded.frames == 1,
              try FileVersion(output).size <= 512 * 1024 * 1024 else {
            throw ConversionError.message("The AVIF output failed validation.")
        }
    }
}
