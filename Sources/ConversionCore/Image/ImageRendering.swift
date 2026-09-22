import Accelerate
import CoreGraphics
import Foundation
import ImageIO

extension ImageConverter {
    static func properties(_ source: CGImageSource, _ index: Int) throws -> [CFString: Any] {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            throw ConversionError.message("An image page has unreadable properties.")
        }
        return properties
    }

    static func dimensions(_ properties: [CFString: Any]) throws -> (width: Int, height: Int) {
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000, width <= 32_000_000 / height else {
            throw ConversionError.message("An image page exceeds 32 million pixels or has invalid dimensions.")
        }
        return (width, height)
    }

    // Fit a canvas inside a maximum width without enlarging it.
    static func scaledCanvas(width: Int, height: Int, maxWidth: Int) -> (width: Int, height: Int) {
        guard maxWidth > 0, width > 0, height > 0, maxWidth < width else { return (width, height) }
        return (maxWidth, max(1, Int((Double(height) * Double(maxWidth) / Double(width)).rounded())))
    }

    static func render(_ image: CGImage, orientation: Int, colorSpace: CGColorSpace? = nil,
                       alphaInfo: CGImageAlphaInfo = .premultipliedLast, maxWidth: Int = 0) throws -> CGImage {
        let context = try renderContext(image, orientation: orientation, colorSpace: colorSpace,
                                        alphaInfo: alphaInfo, maxWidth: maxWidth)
        guard let converted = context.makeImage() else { throw ConversionError.message("The color conversion failed.") }
        return converted
    }

    static func renderContext(_ image: CGImage, orientation: Int, colorSpace: CGColorSpace? = nil,
                              alphaInfo: CGImageAlphaInfo = .premultipliedLast, maxWidth: Int = 0) throws -> CGContext {
        let oriented = (width: orientation >= 5 ? image.height : image.width,
                        height: orientation >= 5 ? image.width : image.height)
        let canvas = scaledCanvas(width: oriented.width, height: oriented.height, maxWidth: maxWidth)
        let width = canvas.width, height = canvas.height
        guard (1...8).contains(orientation), let colorSpace = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: alphaInfo.rawValue) else {
            throw ConversionError.message("The color conversion buffer could not be created.")
        }
        // Scale first so the orientation transform still maps the source at its own size.
        if canvas.width != oriented.width || canvas.height != oriented.height {
            context.interpolationQuality = .high
            context.concatenate(CGAffineTransform(scaleX: Double(canvas.width) / Double(oriented.width),
                                                  y: Double(canvas.height) / Double(oriented.height)))
        }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: transform = .identity
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }

    static func requireStillImage(_ source: CGImageSource, type: String, properties: [CFString: Any]) throws {
        guard CGImageSourceGetCount(source) == 1, type != "com.adobe.pdf" else {
            throw ConversionError.message("This output requires one still image.")
        }
        if let keys = AnimationFrames.keys(type) {
            let global = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
            let animation = global[keys.dictionary] as? [CFString: Any] ?? [:]
            let frame = properties[keys.dictionary] as? [CFString: Any] ?? [:]
            guard (animation[keys.loop] as? Int ?? 1) == 1,
                  !(type == "public.png" && animation[keys.loop] != nil),
                  !(type == "org.webmproject.webp" && properties[keys.dictionary] != nil),
                  (frame[keys.unclamped] as? Double ?? frame[keys.delay] as? Double ?? 0) == 0 else {
                throw ConversionError.message("This output does not support animation timing. The source was kept.")
            }
        }
    }

    // Consume the rendered RGBA buffer once, removing premultiplication and row padding.
    static func writeRGBA(_ rendered: CGContext, to file: FileHandle) throws {
        try withExtendedLifetime(rendered) {
            guard rendered.bitsPerComponent == 8, rendered.bitsPerPixel == 32, let pixels = rendered.data else {
                throw ConversionError.message("The RGBA color buffer is missing or invalid.")
            }
            let width = rendered.width, height = rendered.height
            var buffer = vImage_Buffer(data: pixels, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                       rowBytes: rendered.bytesPerRow)
            guard vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageDoNotTile)) == kvImageNoError else {
                throw ConversionError.message("Image transparency could not be prepared.")
            }
            if rendered.bytesPerRow == width * 4 {
                try file.write(contentsOf: Data(bytesNoCopy: pixels, count: width * height * 4, deallocator: .none))
            } else {
                for row in 0..<height {
                    try Task.checkCancellation()
                    try file.write(contentsOf: Data(bytesNoCopy: pixels.advanced(by: row * rendered.bytesPerRow),
                                                   count: width * 4, deallocator: .none))
                }
            }
        }
    }
}
