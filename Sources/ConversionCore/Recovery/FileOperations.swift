import CryptoKit
import Darwin
import Foundation

struct FileVersion: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let isDirectory: Bool

    init(_ url: URL, allowingDirectories: Bool = false) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw posixError() }
        try self.init(value, allowingDirectories: allowingDirectories)
    }

    init(_ value: stat, allowingDirectories: Bool = false) throws {
        isDirectory = value.st_mode & S_IFMT == S_IFDIR
        guard value.st_mode & S_IFMT == S_IFREG || (allowingDirectories && isDirectory) else {
            throw ConversionError.message("The source must be a regular file.")
        }
        device = value.st_dev
        inode = value.st_ino
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

func fileHash(_ url: URL, checkCancellation: Bool = true) throws -> String {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw posixError() }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
        throw ConversionError.message("The recovery file is not a regular file.")
    }
    return try fileHash(descriptor: descriptor, expectedBytes: status.st_size, checkCancellation: checkCancellation)
}

func fileHash(descriptor: Int32, expectedBytes: Int64, checkCancellation: Bool) throws -> String {
    var hash = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    var total: Int64 = 0
    while true {
        if checkCancellation { try Task.checkCancellation() }
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw posixError() }
        if count == 0 { break }
        total += Int64(count)
        guard total <= expectedBytes else {
            throw ConversionError.message("The file grew while it was being read.")
        }
        buffer.withUnsafeBytes { bytes in
            hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes.prefix(count)))
        }
    }
    guard total == expectedBytes else { throw ConversionError.message("The file changed while it was being read.") }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func cloneSource(_ source: URL, to destination: URL) throws {
    if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) != 0 {
        guard [ENOTSUP, EXDEV, ENOSYS, EINVAL].contains(errno) else { throw posixError() }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

func coordinateReplacement(_ url: URL, operation: () throws -> Void) throws {
    var coordinationError: NSError?
    var operationError: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { _ in
        do { try operation() } catch { operationError = error }
    }
    if let operationError { throw operationError }
    if let coordinationError { throw coordinationError }
}

func exchange(_ first: URL, _ second: URL) throws {
    guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else {
        throw posixError()
    }
}

func moveExclusively(_ source: URL, _ target: URL) throws {
    guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else {
        throw posixError()
    }
}

func pathIsAbsent(_ url: URL) throws -> Bool {
    var status = stat()
    if lstat(url.path, &status) == 0 { return false }
    guard errno == ENOENT else { throw posixError() }
    return true
}

func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
