import Foundation
import ImageIO

enum IconImageConverter {
    static let inputTypes: Set<String> = ["com.microsoft.ico", "com.apple.icns"]
    static let outputTypes = inputTypes

    static func convert(_ input: URL, to output: URL, format: FileFormat, options: ImageOptions) throws {
        let version = try FileVersion(input)
        guard version.size > 0, version.size <= 512 * 1024 * 1024,
              options.quality.isFinite, (0...1).contains(options.quality),
              let type = format.typeIdentifier,
              let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let sourceType = CGImageSourceGetType(source) as String? else {
            throw ConversionError.message("Icon conversion needs a readable image up to 512 MiB and quality between 0 and 1.")
        }
        let isIcon = inputTypes.contains(sourceType)
        guard outputTypes.contains(type) || (isIcon && type == "public.png") else {
            throw ConversionError.message("This icon conversion is not supported.")
        }
        let count = CGImageSourceGetCount(source)
        guard (1...256).contains(count) else { throw ConversionError.message("An icon may contain at most 256 images.") }
        var selected = 0, bestArea = 0, bestDepth = 0, totalPixels = 0
        for index in 0..<count {
            try Task.checkCancellation()
            let properties = try ImageConverter.properties(source, index)
            let size = try ImageConverter.dimensions(properties)
            let area = size.width * size.height
            let depth = properties[kCGImagePropertyDepth] as? Int ?? 0
            totalPixels += area
            guard totalPixels <= 256_000_000 else { throw ConversionError.message("The icon images exceed 256 million pixels in total.") }
            if area > bestArea || (area == bestArea && depth > bestDepth) {
                selected = index; bestArea = area; bestDepth = depth
            }
        }
        let original = try ImageConverter.properties(source, selected)
        if !isIcon { try ImageConverter.requireStillImage(source, type: sourceType, properties: original) }
        defer { CGImageSourceRemoveCacheAtIndex(source, selected) }
        let expected: [Int]
        if type == "public.png" {
            let size = try ImageConverter.dimensions(original)
            guard let image = CGImageSourceCreateImageAtIndex(source, selected, nil),
                  CGImageSourceGetStatusAtIndex(source, selected) == .statusComplete,
                  image.width == size.width, image.height == size.height,
                  let destination = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else {
                throw ConversionError.message("The selected icon image could not be decoded.")
            }
            let pixels = options.convertToSRGB ? try ImageConverter.render(image, orientation: 1) : image
            var properties = options.preserveMetadata ? original : [:]
            for key in [kCGImagePropertyOrientation, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
                properties[key] = original[key]
            }
            CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ConversionError.message("The icon PNG could not be encoded.") }
            expected = [size.width * size.height]
        } else {
            let maximum = type == "com.apple.icns" ? 1024 : 256
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, selected, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary), image.width > 0, image.height > 0,
                  image.width <= maximum, image.height <= maximum,
                  CGImageSourceGetStatusAtIndex(source, selected) == .statusComplete else {
                throw ConversionError.message("The icon artwork could not be decoded at a bounded size.")
            }
            CGImageSourceRemoveCacheAtIndex(source, selected)
            let sizes = type == "com.apple.icns"
                ? [(16, 72), (32, 144), (32, 72), (64, 144), (128, 72), (256, 144), (256, 72), (512, 144), (512, 72), (1024, 144)]
                : [16, 24, 32, 48, 64, 128, 256].map { ($0, 72) }
            let destination = type == "com.apple.icns"
                ? CGImageDestinationCreateWithURL(output as CFURL, type as CFString, sizes.count, nil) : nil
            guard type != "com.apple.icns" || destination != nil else {
                throw ConversionError.message("The ICNS output could not be opened.")
            }
            var payloads: [Data] = []
            for (size, dpi) in sizes {
                try autoreleasepool {
                    try Task.checkCancellation()
                    let space = !options.convertToSRGB && image.colorSpace?.model == .rgb
                        ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
                    guard let space, let context = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                        throw ConversionError.message("The icon image buffer could not be created.")
                    }
                    let scale = Double(size) / Double(max(image.width, image.height))
                    let width = Double(image.width) * scale, height = Double(image.height) * scale
                    context.interpolationQuality = .high
                    context.draw(image, in: CGRect(x: (Double(size) - width) / 2, y: (Double(size) - height) / 2, width: width, height: height))
                    guard let rendered = context.makeImage() else { throw ConversionError.message("The icon image could not be rendered.") }
                    var properties = options.preserveMetadata ? original : [:]
                    properties[kCGImagePropertyOrientation] = 1
                    properties[kCGImagePropertyPixelWidth] = size
                    properties[kCGImagePropertyPixelHeight] = size
                    properties[kCGImagePropertyDPIWidth] = dpi
                    properties[kCGImagePropertyDPIHeight] = dpi
                    var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                    tiff[kCGImagePropertyTIFFOrientation] = 1
                    properties[kCGImagePropertyTIFFDictionary] = tiff
                    if let destination {
                        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
                    } else {
                        let data = NSMutableData()
                        guard let png = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                            throw ConversionError.message("An ICO image could not be opened.")
                        }
                        CGImageDestinationAddImage(png, rendered, properties as CFDictionary)
                        guard CGImageDestinationFinalize(png), data.length <= 4 * 1024 * 1024 else {
                            throw ConversionError.message("An ICO image could not be encoded within 4 MiB.")
                        }
                        payloads.append(data as Data)
                    }
                }
            }
            if let destination {
                guard CGImageDestinationFinalize(destination) else { throw ConversionError.message("The ICNS output could not be encoded.") }
            } else {
                var container = Data()
                func append<T: FixedWidthInteger>(_ number: T) {
                    var little = number.littleEndian
                    withUnsafeBytes(of: &little) { container.append(contentsOf: $0) }
                }
                append(UInt16(0)); append(UInt16(1)); append(UInt16(sizes.count))
                var offset = 6 + 16 * sizes.count
                for (index, pair) in sizes.enumerated() {
                    let dimension = UInt8(pair.0 == 256 ? 0 : pair.0)
                    container.append(contentsOf: [dimension, dimension, 0, 0])
                    append(UInt16(1)); append(UInt16(32))
                    append(UInt32(payloads[index].count)); append(UInt32(offset))
                    offset += payloads[index].count
                }
                for payload in payloads { container.append(payload) }
                try container.write(to: output)
            }
            expected = sizes.map { $0.0 * $0.0 }.sorted()
        }
        guard try FileVersion(output).size <= 512 * 1024 * 1024,
              let check = CGImageSourceCreateWithURL(output as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(check) as String? == type, CGImageSourceGetCount(check) == expected.count else {
            throw ConversionError.message("The encoded icon has an incorrect type or image count.")
        }
        var actual: [Int] = []
        for index in 0..<expected.count {
            try autoreleasepool {
                try Task.checkCancellation()
                defer { CGImageSourceRemoveCacheAtIndex(check, index) }
                let size = try ImageConverter.dimensions(ImageConverter.properties(check, index))
                let dimensionsMatch = type == "public.png"
                    ? size.width == original[kCGImagePropertyPixelWidth] as? Int && size.height == original[kCGImagePropertyPixelHeight] as? Int
                    : size.width == size.height
                guard let image = CGImageSourceCreateImageAtIndex(check, index, nil),
                      dimensionsMatch,
                      image.width == size.width, image.height == size.height,
                      CGImageSourceGetStatusAtIndex(check, index) == .statusComplete else {
                    throw ConversionError.message("An encoded icon image could not be decoded.")
                }
                actual.append(size.width * size.height)
            }
        }
        guard actual.sorted() == expected, try FileVersion(input) == version else {
            throw ConversionError.message("The icon dimensions or source changed during conversion.")
        }
    }
}
