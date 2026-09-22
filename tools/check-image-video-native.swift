import AVFoundation
import Foundation
import ImageIO

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: check-image-video-native INPUT_VIDEO OUTPUT_PNG")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard !FileManager.default.fileExists(atPath: output.path) else { fatalError("Output already exists") }
let generator = AVAssetImageGenerator(asset: AVURLAsset(url: input))
generator.appliesPreferredTrackTransform = true
let (image, _) = try await generator.image(at: .zero)
guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("The native frame output could not be created")
}
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
