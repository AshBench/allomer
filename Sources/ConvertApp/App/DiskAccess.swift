import Darwin
import Foundation

enum DiskAccess: Equatable, Sendable {
    case notChecked, available, unavailable, unknown

    var description: String {
        switch self {
        case .notChecked: "Whole-system monitoring needs Full Disk Access."
        case .available: "Protected folders are accessible. macOS still enforces file permissions."
        case .unavailable: "Access is not available. Enable Full Disk Access in System Settings, then try again."
        case .unknown: "Access could not be checked. Review Full Disk Access in System Settings, then try again."
        }
    }

    static func check() -> Self {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return check(directories: ["Safari", "Mail", "Messages"].map { library.appendingPathComponent($0, isDirectory: true) })
    }

    /// Check directory access without opening user files or retaining entry names.
    static func check(directories: [URL]) -> Self {
        var accessible = false
        var unknown = false
        for url in directories {
            guard url.isFileURL else { return .unknown }
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 {
                if errno == EPERM || errno == EACCES { return .unavailable }
                if errno != ENOENT { unknown = true }
                continue
            }
            guard let directory = fdopendir(descriptor) else {
                close(descriptor)
                unknown = true
                continue
            }
            errno = 0
            _ = readdir(directory)
            let result = errno
            closedir(directory)
            if result == EPERM || result == EACCES { return .unavailable }
            if result == 0 { accessible = true } else { unknown = true }
        }
        return !unknown && accessible ? .available : .unknown
    }
}
