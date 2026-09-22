import Foundation

public struct EmailOptions: Codable, Equatable, Sendable {
    public var includeHeaders = true
    public init() {}
}

enum EmailConverter {
    static let routes: [String: Set<String>] = [
        "eml": ["emlx", "msg", "html"], "emlx": ["eml"], "msg": ["eml"]
    ]

    static func convert(_ input: URL, to output: URL, from source: FileFormat, to target: FileFormat,
                        tool: URL, options: EmailOptions) throws {
        guard routes[source.id]?.contains(target.id) == true else {
            throw ConversionError.message("These email formats cannot be converted directly.")
        }
        try ExternalTool.run(tool, arguments: [input.path, output.path, source.id, target.id,
            options.includeHeaders ? "true" : "false"], workDirectory: output.deletingLastPathComponent())
        let values = try output.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 128 * 1024 * 1024 else {
            throw ConversionError.message("The email converter produced an invalid output file.")
        }
    }
}
