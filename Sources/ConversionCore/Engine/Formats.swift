import Foundation
import UniformTypeIdentifiers

public struct FileFormat: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let extensions: [String]

    public var typeIdentifier: String? {
        extensions.lazy.compactMap { UTType(filenameExtension: $0)?.identifier }.first
    }
}

public struct FormatCatalog: Sendable {
    public let formats: [FileFormat]

    public init() throws {
        let appResources = Bundle.main.resourceURL?
            .appendingPathComponent("Allomer_ConversionCore.bundle")
        let resources = appResources.flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = resources.url(forResource: "formats", withExtension: "json") else {
            throw ConversionError.message("The format catalog is missing.")
        }
        formats = try JSONDecoder().decode([FileFormat].self, from: Data(contentsOf: url))
    }

    public func format(forExtension value: String) -> FileFormat? {
        let value = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return formats.first { $0.id == value || $0.extensions.contains(value) }
    }

    public func format(for file: URL) -> FileFormat? {
        let name = file.lastPathComponent.lowercased()
        var result: FileFormat?
        var matchedLength = 0
        for format in formats {
            for suffix in format.extensions where suffix.count > matchedLength && name.hasSuffix("." + suffix) {
                result = format
                matchedLength = suffix.count
            }
        }
        return result
    }
}

public enum ConversionError: Error, LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
