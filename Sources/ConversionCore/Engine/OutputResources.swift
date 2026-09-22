import Darwin
import Foundation

/// Companion files that must stay beside a converted file.
public struct OutputResources: Codable, Equatable, Sendable {
    public let directoryName: String
    public let fileHashes: [String: String]

    init(directory: URL) throws {
        directoryName = directory.lastPathComponent
        fileHashes = try Self.hashes(in: directory)
        try validateName()
    }

    func validateName() throws {
        let prefix = "conversion-assets-"
        guard directoryName.hasPrefix(prefix), UUID(uuidString: String(directoryName.dropFirst(prefix.count))) != nil,
              !fileHashes.isEmpty, fileHashes.count <= 2048,
              fileHashes.keys.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") && !$0.contains("\\") }) else {
            throw ConversionError.message("The converted resource folder has an invalid name or file list.")
        }
    }

    func verify(in parent: URL, checkCancellation: Bool = true) throws {
        try validateName()
        guard try Self.hashes(in: parent.appendingPathComponent(directoryName), checkCancellation: checkCancellation) == fileHashes else {
            throw ConversionError.message("The converted resource files have changed or are missing.")
        }
    }

    func move(from source: URL, to destination: URL, checkCancellation: Bool = true) throws {
        try verify(in: source, checkCancellation: checkCancellation)
        let before = source.appendingPathComponent(directoryName)
        let after = destination.appendingPathComponent(directoryName)
        guard renameatx_np(AT_FDCWD, before.path, AT_FDCWD, after.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "The converted resource folder could not be moved. Its destination may already exist."
            ])
        }
    }

    private static func hashes(in directory: URL, checkCancellation: Bool = true) throws -> [String: String] {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ConversionError.message("The converted resources must be in a regular folder.")
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        guard !files.isEmpty, files.count <= 2048 else {
            throw ConversionError.message("The converted resource folder has an invalid file count.")
        }
        var total = 0
        var hashes: [String: String] = [:]
        for file in files {
            let version = try FileVersion(file)
            guard version.size >= 0, version.size <= 128 * 1024 * 1024 else {
                throw ConversionError.message("A converted resource exceeds 128 MiB.")
            }
            total += Int(version.size)
            guard total <= 512 * 1024 * 1024 else {
                throw ConversionError.message("Converted resources exceed 512 MiB.")
            }
            hashes[file.lastPathComponent] = try fileHash(file, checkCancellation: checkCancellation)
            guard try FileVersion(file) == version else {
                throw ConversionError.message("A converted resource changed during validation.")
            }
        }
        return hashes
    }
}
