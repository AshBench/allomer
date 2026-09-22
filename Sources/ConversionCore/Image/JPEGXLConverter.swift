import Foundation
import ImageIO

enum JPEGXLConverter {
    static func convert(_ input: URL, to output: URL, tool: URL, options: ImageOptions) throws {
        guard options.quality.isFinite, (0...1).contains(options.quality) else {
            throw ConversionError.message("Image quality must be between 0 and 1.")
        }
        guard (1...10).contains(options.jpegXLEffort) else {
            throw ConversionError.message("JPEG XL effort must be between 1 and 10.")
        }
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= 512 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, type != "com.adobe.pdf" else {
            throw ConversionError.message("JPEG XL output currently needs one readable image up to 512 MiB.")
        }
        let properties = try ImageConverter.properties(source, 0)
        let size = try ImageConverter.dimensions(properties)
        try ImageConverter.requireStillImage(source, type: type, properties: properties)
        let work = output.deletingLastPathComponent()
        let prepared = work.appendingPathComponent("jpegxl-input-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: prepared) }
        var png = input
        if type != "public.png" || !options.preserveMetadata || options.convertToSRGB {
            let format = FileFormat(id: "png", name: "PNG", category: "image", extensions: ["png"])
            try ImageConverter.convert(input, to: prepared, format: format, options: options, omitPNGGamma: true)
            png = prepared
        }
        // The encoder parses quality as Float and treats 100 as lossless.
        let quality = options.jpegXLMode == .lossless ? 100 : min(options.quality * 100, Double(Float(100).nextDown))
        try ExternalTool.run(tool, arguments: [png.path, work.path, png.path, output.path,
            "--quiet", "--quality=\(quality)", "--effort=\(options.jpegXLEffort)", "--num_threads=0",
            "--keep_invisible=1", "--alpha_distance=0", "--resampling=1", "--ec_resampling=1",
            "--buffering=2", "--streaming_output", "--output_mode=1"],
            workDirectory: work)
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard try FileVersion(output).size <= 512 * 1024 * 1024,
              let check = CGImageSourceCreateWithURL(output as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(check) as String? == "public.jpeg-xl", CGImageSourceGetCount(check) == 1,
              let image = CGImageSourceCreateImageAtIndex(check, 0, nil),
              CGImageSourceGetStatusAtIndex(check, 0) == .statusComplete else {
            throw ConversionError.message("The encoded JPEG XL failed validation.")
        }
        let result = try ImageConverter.properties(check, 0)
        let resultOrientation = result[kCGImagePropertyOrientation] as? Int ?? 1
        let width = orientation >= 5 ? size.height : size.width
        let height = orientation >= 5 ? size.width : size.height
        guard (1...8).contains(orientation), (1...8).contains(resultOrientation),
              (resultOrientation >= 5 ? image.height : image.width) == width,
              (resultOrientation >= 5 ? image.width : image.height) == height else {
            throw ConversionError.message("The encoded JPEG XL changed the displayed dimensions.")
        }
        guard try FileVersion(input) == version else {
            throw ConversionError.message("The source changed during JPEG XL conversion.")
        }
    }
}
