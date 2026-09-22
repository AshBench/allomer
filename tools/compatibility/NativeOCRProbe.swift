import CoreGraphics
import CoreText
import Foundation
import Vision

enum ProbeFailure: Error {
    case failed(String)
}

func runProbe() throws {
    guard CommandLine.arguments.count == 3 else {
        throw ProbeFailure.failed("Expected an allowed file and a blocked file.")
    }
    let visionOnly = CommandLine.arguments[1] == "--vision-only"
    let allowed = URL(fileURLWithPath: CommandLine.arguments[visionOnly ? 2 : 1])
    guard try String(contentsOf: allowed, encoding: .utf8) == "allowed\n" else {
        throw ProbeFailure.failed("The sandbox blocked the declared input.")
    }
    if !visionOnly {
        let blocked = URL(fileURLWithPath: CommandLine.arguments[2])
        guard (try? Data(contentsOf: blocked)) == nil else {
            throw ProbeFailure.failed("The sandbox exposed an unrelated file.")
        }
    }

    guard let context = CGContext(
        data: nil,
        width: 1_200,
        height: 320,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw ProbeFailure.failed("The OCR test image could not be created.")
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 320))
    context.textPosition = CGPoint(x: 60, y: 120)
    let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: "Allomer runtime 4827",
        attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String):
                CTFontCreateWithName("Helvetica" as CFString, 72, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 0, alpha: 1),
        ]
    ))
    CTLineDraw(line, context)
    guard let image = context.makeImage() else {
        throw ProbeFailure.failed("The OCR test image could not be read.")
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.automaticallyDetectsLanguage = false
    request.usesLanguageCorrection = true
    request.preferBackgroundProcessing = true
    try VNImageRequestHandler(cgImage: image).perform([request])
    let text = (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ")
    guard text.contains("4827") else {
        throw ProbeFailure.failed("Vision did not recognize the test number: \(text)")
    }
    print("Vision OCR and its restricted cache passed: \(text)")
}

do {
    try runProbe()
} catch {
    let failure = error as NSError
    let message = "\(failure.domain) \(failure.code): \(failure.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
