import CryptoKit
import Darwin
import Foundation

/// A regular file or an Icon Composer package, including its member versions.
struct SourceVersion: Equatable, Sendable {
    let root: FileVersion
    let members: [String: FileVersion]
    let contentHash: String?
    var device: Int32 { root.device }
    var inode: UInt64 { root.inode }
    var isPackage: Bool { root.isDirectory }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.root == rhs.root && lhs.members == rhs.members
    }

    init(_ url: URL, hashing: Bool = false, checkCancellation: Bool = true) throws {
        root = try FileVersion(url, allowingDirectories: true)
        guard root.isDirectory else {
            members = [:]
            contentHash = hashing ? try fileHash(url, checkCancellation: checkCancellation) : nil
            if hashing {
                guard try FileVersion(url) == root else { throw Self.changed() }
            }
            return
        }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Self.posixError() }
        guard try FileVersion(status, allowingDirectories: true) == root else { throw Self.changed() }
        var manifest = stat()
        guard fstatat(descriptor, "icon.json", &manifest, AT_SYMLINK_NOFOLLOW) == 0,
              manifest.st_mode & S_IFMT == S_IFREG, manifest.st_size > 0, manifest.st_size <= 1_048_576 else {
            throw ConversionError.message("Only Icon Composer packages with an icon.json file up to 1 MiB are supported.")
        }
        var entries: [String: FileVersion] = [:]
        var hashes: [String: String] = [:]
        var totalBytes: Int64 = 0

        func visit(_ parent: Int32, prefix: String, depth: Int) throws {
            guard depth <= 16 else { throw ConversionError.message("The icon package has too many folder levels.") }
            let duplicate = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard duplicate >= 0 else { throw Self.posixError() }
            guard let directory = fdopendir(duplicate) else { close(duplicate); throw Self.posixError() }
            defer { closedir(directory) }
            while true {
                if checkCancellation { try Task.checkCancellation() }
                errno = 0
                guard let entry = readdir(directory) else {
                    guard errno == 0 else { throw Self.posixError() }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    String(validatingCString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                }
                guard let name else { throw ConversionError.message("An icon package filename is not valid UTF-8.") }
                if name == "." || name == ".." { continue }
                guard entries.count < 4096 else { throw ConversionError.message("Use an icon package with at most 4,096 entries.") }
                let relative = prefix + name
                var value = stat()
                guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.posixError() }
                let version = try FileVersion(value, allowingDirectories: true)
                guard entries.updateValue(version, forKey: relative) == nil else { throw Self.changed() }
                if version.isDirectory {
                    let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw Self.posixError() }
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0 else { throw Self.posixError() }
                    guard try FileVersion(opened, allowingDirectories: true) == version else { throw Self.changed() }
                    try visit(child, prefix: relative + "/", depth: depth + 1)
                    guard fstat(child, &opened) == 0 else { throw Self.posixError() }
                    guard try FileVersion(opened, allowingDirectories: true) == version else { throw Self.changed() }
                } else {
                    guard version.size >= 0, version.size <= 128 * 1024 * 1024 else {
                        throw ConversionError.message("An icon package file exceeds 128 MiB.")
                    }
                    totalBytes += version.size
                    guard totalBytes <= 512 * 1024 * 1024 else {
                        throw ConversionError.message("The icon package exceeds 512 MiB.")
                    }
                    if hashing {
                        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                        guard file >= 0 else { throw Self.posixError() }
                        defer { close(file) }
                        var opened = stat()
                        guard fstat(file, &opened) == 0 else { throw Self.posixError() }
                        guard try FileVersion(opened) == version else { throw Self.changed() }
                        hashes[relative] = try fileHash(descriptor: file, expectedBytes: version.size, checkCancellation: checkCancellation)
                        guard fstat(file, &opened) == 0 else { throw Self.posixError() }
                        guard try FileVersion(opened) == version else { throw Self.changed() }
                    }
                }
            }
        }
        try visit(descriptor, prefix: "", depth: 0)
        guard try FileVersion(url, allowingDirectories: true) == root else { throw Self.changed() }
        members = entries
        if hashing {
            var hash = SHA256()
            hash.update(data: Data("Icon Composer package contents v1\0".utf8))
            for name in entries.keys.sorted() {
                let value = entries[name]!.isDirectory ? "directory" : hashes[name]!
                hash.update(data: Data("\(name)\0\(value)\0".utf8))
            }
            contentHash = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard try Self(url, checkCancellation: checkCancellation) == self else { throw Self.changed() }
        } else { contentHash = nil }
    }

    private static func changed() -> ConversionError {
        .message("The source package changed while it was being read.")
    }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

func sourceContentHash(_ url: URL, checkCancellation: Bool = true) throws -> String {
    try SourceVersion(url, hashing: true, checkCancellation: checkCancellation).contentHash!
}
