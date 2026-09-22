import CArchive
import CryptoKit
import Darwin
import Foundation

public struct ArchiveOptions: Codable, Equatable, Sendable {
    public enum Compression: String, Codable, CaseIterable, Sendable { case fast, balanced, small }
    public var compression = Compression.balanced
    public var includeTopLevelFolder = false
    public init() {}
}

public enum ArchiveConverter {
    public static let formats: Set<String> = ["zip", "tar", "tgz", "gzip", "7z"]
    private static let maximumBytes: Int64 = 16 * 1024 * 1024 * 1024

    struct Entry: Equatable {
        var path: String
        var directory: Bool
        var size: Int64
        var hash: Data
    }

    public static func convert(_ source: URL, to destination: URL, from input: FileFormat?,
                               to output: FileFormat, options: ArchiveOptions = ArchiveOptions()) throws {
        guard formats.contains(output.id) else { throw ConversionError.message("Unknown archive format.") }
        guard output.id != "gzip" || !options.includeTopLevelFolder else {
            throw ConversionError.message("GZIP stores one file. Use compressed TAR to include a folder.")
        }
        guard let writer = archive_write_new() else { throw failure(nil) }
        defer { archive_write_free(writer) }
        try configure(writer, format: output.id, compression: options.compression)
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        try check(archive_write_open_fd(writer, fd), writer)
        let suffix = input?.extensions.sorted { $0.count > $1.count }.first {
            source.lastPathComponent.lowercased().hasSuffix("." + $0)
        }
        let stem = suffix.map { String(source.lastPathComponent.dropLast($0.count + 1)) }
            ?? source.deletingPathExtension().lastPathComponent
        let folder = options.includeTopLevelFolder ? try safePath(stem) + "/" : ""
        var expected: [Entry] = []
        if !folder.isEmpty {
            guard let entry = archive_entry_new() else { throw failure(writer) }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname_utf8(entry, folder)
            archive_entry_set_filetype(entry, UInt32(S_IFDIR))
            archive_entry_set_perm(entry, 0o755)
            archive_entry_set_size(entry, 0)
            try check(archive_write_header(writer, entry), writer)
            try check(archive_write_finish_entry(writer), writer)
            expected.append(Entry(path: String(folder.dropLast()), directory: true, size: 0, hash: Data()))
        }
        if let input, formats.contains(input.id) {
            let rawSize = input.id == "gzip" ? try manifest(source, format: "gzip").first?.size : nil
            var memberCount = 0
            expected += try read(source, format: input.id) { entry, reader in
                if output.id == "gzip", memberCount != 0 || archive_entry_filetype(entry) != S_IFREG {
                    throw ConversionError.message("GZIP needs one regular file. Use compressed TAR for several files.")
                }
                memberCount += 1
                if let rawSize { archive_entry_set_size(entry, rawSize) }
                let path = folder + (try name(entry))
                archive_entry_set_pathname_utf8(entry, path)
                try check(archive_write_header(writer, entry), writer)
                let result = try transfer(reader, writer: writer, path: path,
                                          directory: archive_entry_filetype(entry) == S_IFDIR)
                try check(archive_write_finish_entry(writer), writer)
                return result
            }
        } else {
            guard let entry = archive_entry_new() else { throw failure(writer) }
            defer { archive_entry_free(entry) }
            var info = stat()
            guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw ConversionError.message("Choose a regular file to archive.")
            }
            guard info.st_size >= 0, info.st_size <= maximumBytes else { throw sizeError() }
            let path = folder + (try safePath(source.lastPathComponent))
            archive_entry_copy_stat(entry, &info)
            archive_entry_set_pathname_utf8(entry, path)
            try check(archive_write_header(writer, entry), writer)
            let archived = try transferFile(source, writer: writer, path: path, expectedSize: info.st_size)
            try check(archive_write_finish_entry(writer), writer)
            expected.append(archived)
        }
        guard !expected.isEmpty else { throw ConversionError.message("The archive is empty.") }
        try check(archive_write_close(writer), writer)
        let actual = try manifest(destination, format: output.id)
        if output.id == "gzip" {
            guard expected.count == 1, actual.count == 1, actual[0].size == expected[0].size,
                  actual[0].hash == expected[0].hash else { throw mismatch() }
        } else if actual.sorted(by: { $0.path < $1.path }) != expected.sorted(by: { $0.path < $1.path }) {
            throw mismatch()
        }
    }

    static func manifest(_ source: URL, format: String) throws -> [Entry] {
        try read(source, format: format) { entry, reader in
            try transfer(reader, writer: nil, path: name(entry), directory: archive_entry_filetype(entry) == S_IFDIR)
        }
    }

    // Inspect document parts without extracting paths supplied by the archive.
    static func inspectZIP(_ source: URL, visit: (String, Data) throws -> Void) throws {
        var remaining: Int64 = 256 * 1024 * 1024
        _ = try read(source, format: "zip") { entry, reader in
            try autoreleasepool {
                let path = try name(entry)
                let directory = archive_entry_filetype(entry) == S_IFDIR
                let limit = min(remaining, 32 * 1024 * 1024)
                guard archive_entry_size(entry) <= limit else {
                    throw ConversionError.message("A presentation part exceeds 32 MiB, or all parts exceed 256 MiB.")
                }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    try Task.checkCancellation()
                    let count = archive_read_data(reader, &buffer, buffer.count)
                    guard count >= 0 else { throw failure(reader) }
                    if count == 0 { break }
                    guard !directory, Int64(data.count + count) <= limit else {
                        throw ConversionError.message("The presentation exceeds its expanded-size limit.")
                    }
                    data.append(contentsOf: buffer.prefix(count))
                }
                remaining -= Int64(data.count)
                if !directory { try visit(path, data) }
                return Entry(path: path, directory: directory, size: Int64(data.count),
                    hash: directory ? Data() : Data(SHA256.hash(data: data)))
            }
        }
    }

    // Produce and archive one part at a time. Large images never accumulate in memory.
    static func makeZIP(to destination: URL, paths: [String], produce: (String, URL) throws -> Void) throws {
        guard !paths.isEmpty, paths.count <= 100_000, Set(paths).count == paths.count else { throw sizeError() }
        guard let writer = archive_write_new() else { throw failure(nil) }
        defer { archive_write_free(writer) }
        try configure(writer, format: "zip", compression: .balanced)
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var complete = false
        defer {
            close(fd)
            if !complete { try? FileManager.default.removeItem(at: destination) }
        }
        try check(archive_write_open_fd(writer, fd), writer)
        let part = destination.deletingLastPathComponent().appendingPathComponent("zip-part-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: part) }
        var expected: [Entry] = []
        var total: Int64 = 0
        for path in paths {
            // Drain Foundation and image-reader buffers before producing the next part.
            try autoreleasepool {
                try Task.checkCancellation()
                guard try safePath(path) == path else { throw mismatch() }
                try produce(path, part)
                let version = try FileVersion(part)
                total += version.size
                guard version.size >= 0, total <= 512 * 1024 * 1024 else {
                    throw ConversionError.message("The document parts exceed 512 MiB.")
                }
                // PNG already compresses its pixels. Store those bytes without recompressing.
                try check(path.hasSuffix(".png") ? archive_write_zip_set_compression_store(writer)
                    : archive_write_zip_set_compression_deflate(writer), writer)
                guard let entry = archive_entry_new() else { throw failure(writer) }
                defer { archive_entry_free(entry) }
                archive_entry_set_pathname_utf8(entry, path)
                archive_entry_set_filetype(entry, UInt32(S_IFREG))
                archive_entry_set_perm(entry, 0o644)
                archive_entry_set_size(entry, version.size)
                try check(archive_write_header(writer, entry), writer)
                let archived = try transferFile(part, writer: writer, path: path, expectedSize: version.size)
                guard try FileVersion(part) == version else { throw mismatch() }
                try check(archive_write_finish_entry(writer), writer)
                expected.append(archived)
                try FileManager.default.removeItem(at: part)
            }
        }
        try check(archive_write_close(writer), writer)
        guard try FileVersion(destination).size <= 512 * 1024 * 1024,
              try manifest(destination, format: "zip") == expected else { throw mismatch() }
        complete = true
    }

    // Rewrite selected small parts while streaming the other ZIP members unchanged.
    static func rewriteZIP(_ source: URL, to destination: URL, replacing paths: Set<String>,
                           transform: (String, Data) throws -> Data) throws {
        guard let writer = archive_write_new() else { throw failure(nil) }
        defer { archive_write_free(writer) }
        try configure(writer, format: "zip", compression: .balanced)
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        try check(archive_write_open_fd(writer, fd), writer)
        var found = Set<String>()
        var total: Int64 = 0
        let expected = try read(source, format: "zip") { entry, reader in
            let path = try name(entry)
            guard archive_entry_size(entry) <= 256 * 1024 * 1024 - total else {
                throw ConversionError.message("The EPUB expands beyond 256 MiB.")
            }
            try check(path == "mimetype" ? archive_write_zip_set_compression_store(writer)
                : archive_write_zip_set_compression_deflate(writer), writer)
            let result: Entry
            if paths.contains(path) {
                found.insert(path)
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    try Task.checkCancellation()
                    let count = archive_read_data(reader, &buffer, buffer.count)
                    guard count >= 0 else { throw failure(reader) }
                    if count == 0 { break }
                    guard data.count + count <= 16 * 1024 * 1024 else {
                        throw ConversionError.message("An EPUB text part exceeds 16 MiB.")
                    }
                    data.append(contentsOf: buffer.prefix(count))
                }
                let replacement = try transform(path, data)
                guard replacement.count <= 16 * 1024 * 1024 else {
                    throw ConversionError.message("A converted EPUB text part exceeds 16 MiB.")
                }
                if path == "mimetype" {
                    // EPUB forbids ZIP extra fields on this member.
                    archive_entry_clear(entry)
                    archive_entry_set_pathname_utf8(entry, "mimetype")
                    archive_entry_set_filetype(entry, UInt32(S_IFREG))
                    archive_entry_set_perm(entry, 0o644)
                }
                archive_entry_set_size(entry, Int64(replacement.count))
                try check(archive_write_header(writer, entry), writer)
                try replacement.withUnsafeBytes { try write($0, to: writer) }
                result = Entry(path: path, directory: false, size: Int64(replacement.count), hash: Data(SHA256.hash(data: replacement)))
            } else {
                try check(archive_write_header(writer, entry), writer)
                result = try transfer(reader, writer: writer, path: path, directory: archive_entry_filetype(entry) == S_IFDIR)
            }
            total += result.size
            guard total <= 256 * 1024 * 1024 else { throw ConversionError.message("The EPUB expands beyond 256 MiB.") }
            try check(archive_write_finish_entry(writer), writer)
            return result
        }
        guard found == paths else { throw ConversionError.message("An EPUB part is missing.") }
        try check(archive_write_close(writer), writer)
        guard try manifest(destination, format: "zip") == expected else { throw mismatch() }
    }

    private static func read(_ source: URL, format: String,
                             entryHandler: (OpaquePointer, OpaquePointer) throws -> Entry) throws -> [Entry] {
        guard let reader = archive_read_new() else { throw failure(nil) }
        defer { archive_read_free(reader) }
        try check(archive_read_support_filter_none(reader), reader)
        try check(archive_read_support_filter_gzip(reader), reader)
        switch format {
        case "zip": try check(archive_read_support_format_zip(reader), reader)
        case "7z": try check(archive_read_support_format_7zip(reader), reader)
        case "gzip":
            // Explicit selection also accepts a valid GZIP stream with an empty payload.
            try check(archive_read_set_format(reader, ARCHIVE_FORMAT_RAW), reader)
        default: try check(archive_read_support_format_tar(reader), reader)
        }
        try check(archive_read_open_filename(reader, source.path, 64 * 1024), reader)
        var entries: [Entry] = []
        var names: Set<String> = []
        var total: Int64 = 0
        var pathBytes = 0
        var headerCount = 0
        while true {
            try Task.checkCancellation()
            var pointer: OpaquePointer?
            let result = archive_read_next_header(reader, &pointer)
            if result == ARCHIVE_EOF { break }
            try check(result, reader)
            headerCount += 1
            guard headerCount <= 100_000 else { throw sizeError() }
            guard let entry = pointer, archive_entry_is_encrypted(entry) == 0 else {
                throw ConversionError.message("Encrypted archives are not supported on this path.")
            }
            if format == "gzip" {
                guard archive_filter_code(reader, 0) == ARCHIVE_FILTER_GZIP else {
                    throw ConversionError.message("The input is not a GZIP stream.")
                }
                archive_entry_set_pathname_utf8(entry, source.deletingPathExtension().lastPathComponent)
            }
            let type = archive_entry_filetype(entry)
            if type == S_IFDIR, let pointer = archive_entry_pathname_utf8(entry),
               [".", "./"].contains(String(cString: pointer)) {
                try check(archive_read_data_skip(reader), reader)
                continue
            }
            let path = try name(entry)
            guard [S_IFREG, S_IFDIR].contains(type), archive_entry_hardlink(entry) == nil,
                  archive_entry_symlink(entry) == nil else {
                throw ConversionError.message("This archive contains a link or special file that this path cannot preserve.")
            }
            guard names.insert(path).inserted else { throw ConversionError.message("The archive contains duplicate paths.") }
            pathBytes += path.utf8.count
            guard pathBytes <= 16 * 1024 * 1024,
                  archive_entry_size(entry) >= 0, archive_entry_size(entry) <= maximumBytes - total else { throw sizeError() }
            let converted = try entryHandler(entry, reader)
            total += converted.size
            guard total <= maximumBytes else { throw sizeError() }
            entries.append(converted)
        }
        let compressed = archive_filter_code(reader, 0) == ARCHIVE_FILTER_GZIP
        try check(archive_read_close(reader), reader)
        if compressed {
            // The platform archive reader does not check the GZIP trailer CRC.
            _ = try ExternalTool.run(URL(fileURLWithPath: "/usr/bin/gzip"),
                arguments: ["-t", "--", source.path], workDirectory: FileManager.default.temporaryDirectory)
        }
        return entries
    }

    private static func transferFile(_ source: URL, writer: OpaquePointer, path: String, expectedSize: Int64) throws -> Entry {
        let version = try FileVersion(source)
        guard version.size == expectedSize, (0...maximumBytes).contains(expectedSize) else { throw mismatch() }
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == version.device, info.st_ino == version.inode,
              info.st_mode & S_IFMT == S_IFREG else { throw mismatch() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var hash = SHA256()
        var size: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if count == 0 { break }
            size += Int64(count)
            guard size <= expectedSize else { throw mismatch() }
            try buffer.withUnsafeBytes { bytes in
                let block = UnsafeRawBufferPointer(rebasing: bytes.prefix(count))
                hash.update(bufferPointer: block)
                try write(block, to: writer)
            }
        }
        guard size == expectedSize, try FileVersion(source) == version else { throw mismatch() }
        return Entry(path: path, directory: false, size: size, hash: Data(hash.finalize()))
    }

    private static func transfer(_ reader: OpaquePointer, writer: OpaquePointer?, path: String, directory: Bool) throws -> Entry {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var hash = SHA256()
        var size: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = archive_read_data(reader, &buffer, buffer.count)
            guard count >= 0 else { throw failure(reader) }
            if count == 0 { break }
            size += Int64(count)
            guard size <= maximumBytes, !directory else { throw sizeError() }
            try buffer.withUnsafeBytes { bytes in
                let block = UnsafeRawBufferPointer(rebasing: bytes.prefix(count))
                hash.update(bufferPointer: block)
                if let writer { try write(block, to: writer) }
            }
        }
        return Entry(path: try safePath(path), directory: directory, size: size,
                     hash: directory ? Data() : Data(hash.finalize()))
    }

    private static func write(_ bytes: UnsafeRawBufferPointer, to writer: OpaquePointer) throws {
        var offset = 0
        while offset < bytes.count {
            let written = archive_write_data(writer, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            guard written > 0 else { throw failure(writer) }
            offset += written
        }
    }

    private static func configure(_ writer: OpaquePointer, format: String, compression: ArchiveOptions.Compression) throws {
        let level = compression == .fast ? "1" : (compression == .small ? "9" : "6")
        switch format {
        case "zip":
            try check(archive_write_set_format_zip(writer), writer)
            try check(archive_write_set_format_option(writer, "zip", "compression", "deflate"), writer)
            try check(archive_write_set_format_option(writer, "zip", "compression-level", level), writer)
        case "7z":
            try check(archive_write_set_format_7zip(writer), writer)
            try check(archive_write_set_format_option(writer, "7zip", "compression", "lzma2"), writer)
            try check(archive_write_set_format_option(writer, "7zip", "compression-level", level), writer)
        case "gzip": try check(archive_write_set_format_raw(writer), writer)
        default: try check(archive_write_set_format_pax_restricted(writer), writer)
        }
        if ["gzip", "tgz"].contains(format) {
            try check(archive_write_add_filter_gzip(writer), writer)
            try check(archive_write_set_filter_option(writer, "gzip", "compression-level", level), writer)
        }
    }

    private static func name(_ entry: OpaquePointer) throws -> String {
        guard let pointer = archive_entry_pathname_utf8(entry), let path = String(validatingCString: pointer) else {
            throw ConversionError.message("An archive path could not be read as UTF-8.")
        }
        return try safePath(path)
    }

    private static func safePath(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"), path.utf8.count <= 4096,
              !parts.contains(".."), !parts.isEmpty, !parts[0].contains(":") else {
            throw ConversionError.message("The archive contains an unsafe path.")
        }
        let normalized = parts.filter { $0 != "." }.joined(separator: "/")
        guard !normalized.isEmpty else { throw ConversionError.message("An archive entry has no filename.") }
        return normalized
    }

    private static func check(_ result: Int32, _ archive: OpaquePointer) throws {
        guard result == ARCHIVE_OK else { throw failure(archive) }
    }
    private static func failure(_ archive: OpaquePointer?) -> ConversionError {
        let reason = archive.flatMap { archive_error_string($0) }.map { String(cString: $0) } ?? "Archive conversion failed."
        return .message(reason)
    }
    private static func sizeError() -> ConversionError { .message("The archive exceeds the entry, path, or 16 GiB expanded-size limit.") }
    private static func mismatch() -> ConversionError { .message("Archive contents did not match after conversion. The original was kept.") }
}
