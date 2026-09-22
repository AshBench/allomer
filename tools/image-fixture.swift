import CoreGraphics
import Foundation
import ImageIO

// An original fixture for manual performance checks. It contains no external assets.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift tools/image-fixture.swift OUTPUT.png")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
guard !FileManager.default.fileExists(atPath: output.path) else {
    fatalError("Choose a new output path. The fixture generator does not overwrite files.")
}
let width = 6000, height = 4000
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
for index in 0..<40 {
    context.setFillColor(CGColor(red: CGFloat(index) / 40, green: 0.3, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: index * 150, y: index * 80, width: 120, height: 500))
}
let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
print(output.path)
