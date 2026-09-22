import CoreText
import Foundation

enum FontConverter {
    static let formats: Set<String> = ["ttf", "otf", "woff", "woff2"]

    /// Colour and bitmap-strike fonts have no faithful static form on this path.
    private static let unsupported: [UInt32] = [0x434f_4c52, 0x4342_4454, 0x7362_6978, 0x5356_4720,
                                                0x4542_4454, 0x4542_4c43, 0x6264_6174, 0x626c_6f63]
    /// A static font may carry none of these: the variation tables, and a signature that the
    /// rewrite below it has invalidated.
    private static let stale: [UInt32] = [0x6676_6172, 0x6776_6172, 0x6176_6172, 0x6376_6172,
                                          0x4856_4152, 0x5656_4152, 0x4d56_4152, 0x4346_4632, 0x4453_4947]
    /// Without these a font cannot be checked, so a file missing one is refused rather than
    /// handed to CoreText, whose derived values are not all safe to read from a damaged font.
    private static let required: [UInt32] = [0x636d_6170, 0x6e61_6d65, 0x68656164, 0x68686561, 0x686d_7478, 0x6d61_7870]

    private struct Font {
        let graphics: CGFont
        let text: CTFont
        let format: String
        let family: String
        let postScript: String
    }

    static func convert(_ input: URL, to output: URL, format: String, tool: URL) throws {
        guard formats.contains(format) else { throw ConversionError.message("The font output format is unknown.") }
        let source = try read(input)
        for tag in unsupported where source.graphics.table(for: tag) != nil {
            throw ConversionError.message("Fonts with colour data or bitmap strikes are not supported by this font conversion path yet.")
        }
        let work = output.deletingLastPathComponent()
        // File paths and the fixed format name are the only arguments.
        try ExternalTool.run(tool, arguments: [input.path, work.path, input.path, output.path, format],
                             workDirectory: work)
        let result = try read(output)
        guard result.format == format else { throw ConversionError.message("The font converter wrote the wrong file format.") }
        for tag in stale where result.graphics.table(for: tag) != nil {
            throw ConversionError.message("The converted font still carries variation or signature data. The output was not saved.")
        }
        try compare(source, result)
    }

    /// A name record read through the optional-returning CoreText call. The family and PostScript
    /// accessors are imported as non-optional and abort the process on a font that has no such
    /// record, so neither is used here and no name is compared as a CoreFoundation object.
    private static func name(_ font: CTFont, _ key: CFString) -> String? {
        guard let value = CTFontCopyName(font, key) else { return nil }
        let text = value as String
        return text.isEmpty ? nil : text
    }

    private static func read(_ url: URL) throws -> Font {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (12...64 * 1024 * 1024).contains(size) else {
            throw ConversionError.message("Font files must be between 12 bytes and 64 MiB.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func number(_ offset: Int, _ count: Int) -> UInt64 {
            data[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        let format: String
        let tables: UInt64
        switch number(0, 4) {
        case 0x00010000, 0x74727565: format = "ttf"; tables = number(4, 2)
        case 0x4f54544f: format = "otf"; tables = number(4, 2)
        case 0x774f4646, 0x774f4632:
            format = number(0, 4) == 0x774f4646 ? "woff" : "woff2"
            guard data.count >= (format == "woff" ? 44 : 48), number(8, 4) == UInt64(data.count),
                  (12...128 * 1024 * 1024).contains(number(16, 4)) else {
                throw ConversionError.message("The web font header is invalid or exceeds 128 MiB expanded.")
            }
            tables = number(12, 2)
        default: throw ConversionError.message("The file is not a supported font.")
        }
        guard (1...256).contains(tables),
              let provider = CGDataProvider(data: data as CFData), let graphics = CGFont(provider),
              graphics.unitsPerEm > 0, required.allSatisfy({ graphics.table(for: $0) != nil }) else {
            throw ConversionError.message("macOS could not read this font.")
        }
        let text = CTFontCreateWithGraphicsFont(graphics, CGFloat(graphics.unitsPerEm), nil, nil)
        guard let family = name(text, kCTFontFamilyNameKey), let postScript = name(text, kCTFontPostScriptNameKey) else {
            throw ConversionError.message("This font has no readable family or PostScript name.")
        }
        return Font(graphics: graphics, text: text, format: format, family: family, postScript: postScript)
    }

    private static func compare(_ source: Font, _ output: Font) throws {
        guard source.family == output.family, source.postScript == output.postScript,
              CTFontGetUnitsPerEm(source.text) == CTFontGetUnitsPerEm(output.text) else { throw mismatch() }
        let characters = CTFontCopyCharacterSet(source.text) as NSCharacterSet
        guard characters.isEqual(CTFontCopyCharacterSet(output.text)) else { throw mismatch() }
        for key in [kCTFontCopyrightNameKey, kCTFontTrademarkNameKey, kCTFontManufacturerNameKey,
                    kCTFontDesignerNameKey, kCTFontLicenseNameKey, kCTFontLicenseURLNameKey] {
            if let original = name(source.text, key), name(output.text, key) != original { throw mismatch() }
        }
        for plane: UInt8 in 0...16 where characters.hasMemberInPlane(plane) {
            for value in (UInt32(plane) << 16)...min((UInt32(plane) << 16) + 65535, 0x10ffff) {
                if value % 256 == 0 { try Task.checkCancellation() }
                guard characters.longCharacterIsMember(value), let scalar = UnicodeScalar(value) else { continue }
                try autoreleasepool {
                    let text = Array(String(scalar).utf16)
                    var before = [CGGlyph](repeating: 0, count: text.count)
                    var after = before
                    CTFontGetGlyphsForCharacters(source.text, text, &before, text.count)
                    CTFontGetGlyphsForCharacters(output.text, text, &after, text.count)
                    for (inputGlyph, outputGlyph) in zip(before, after) {
                        var inputGlyph = inputGlyph, outputGlyph = outputGlyph
                        var inputAdvance = CGSize.zero, outputAdvance = CGSize.zero
                        CTFontGetAdvancesForGlyphs(source.text, .horizontal, &inputGlyph, &inputAdvance, 1)
                        CTFontGetAdvancesForGlyphs(output.text, .horizontal, &outputGlyph, &outputAdvance, 1)
                        guard abs(inputAdvance.width - outputAdvance.width) <= 0.01 else { throw mismatch() }
                        let inputBounds = CTFontCreatePathForGlyph(source.text, inputGlyph, nil)?.boundingBoxOfPath
                        let outputBounds = CTFontCreatePathForGlyph(output.text, outputGlyph, nil)?.boundingBoxOfPath
                        if let inputBounds, let outputBounds {
                            let left = [inputBounds.minX, inputBounds.minY, inputBounds.maxX, inputBounds.maxY]
                            let right = [outputBounds.minX, outputBounds.minY, outputBounds.maxX, outputBounds.maxY]
                            guard zip(left, right).allSatisfy({ abs($0 - $1) <= 1 }) else { throw mismatch() }
                        } else if (inputBounds == nil) != (outputBounds == nil) { throw mismatch() }
                    }
                }
            }
        }
    }

    private static func mismatch() -> ConversionError {
        .message("The converted font changed character coverage, names, spacing, or outline bounds. The output was not saved.")
    }
}
