import Foundation

struct MonitoredPaths: Sendable {
    let folders: [URL]
    private let watched: [String]
    private let excluded: [String]

    init(folders: [URL], excluding: [URL] = [], ignoreSystemFiles: Bool = false,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.folders = folders.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        watched = self.folders.map(Self.path)
        let system = ignoreSystemFiles ? Self.systemFolders(home: home) : []
        excluded = excluding.map { Self.path($0.resolvingSymlinksInPath()) } + system.map(Self.path)
    }

    func contains(_ file: URL) -> Bool {
        guard file.isFileURL else { return false }
        let path = Self.path(file)
        return watched.contains { Self.isInside(path, folder: $0) }
            && !excluded.contains { Self.isInside(path, folder: $0) }
            && !path.split(separator: "/").contains { $0.hasPrefix(".allomer-") }
    }

    private static func isInside(_ path: String, folder: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    private static func path(_ url: URL) -> String {
        var path = url.standardized.path
        let dataVolume = "/System/Volumes/Data"
        // FSEvents can report the data-volume path for a startup-volume file.
        if path == dataVolume { return "/" }
        if path.hasPrefix(dataVolume + "/") { path = String(path.dropFirst(dataVolume.count)) }
        for alias in ["/private/var", "/private/tmp", "/private/etc"] {
            if path == alias || path.hasPrefix(alias + "/") { return String(path.dropFirst("/private".count)) }
        }
        return path
    }

    private static func systemFolders(home: URL) -> [URL] {
        let system = ["/System", "/bin", "/sbin", "/usr", "/cores", "/Library", "/private/var",
                      "/private/tmp", "/private/etc", "/var", "/tmp", "/etc", "/opt/homebrew", "/.Trashes"]
        let library = ["Accounts", "Application Support", "Autosave Information", "Caches", "Calendars",
                       "ColorSync", "Containers", "Cookies", "Developer", "Group Containers", "HTTPStorages",
                       "Input Methods", "Intents", "Internet Plug-Ins", "Keychains", "LaunchAgents", "Logs",
                       "Mail", "Messages", "Metadata", "Preferences", "Saved Application State", "Sounds",
                       "Spelling", "Suggestions", "WebKit", "Spotlight"]
        let hidden = [".Trash", ".npm", ".nvm", ".pnpm-store", ".yarn", ".bun", ".cargo", ".rustup",
                      ".gradle", ".m2", ".cocoapods", ".gem", ".rbenv", ".pyenv", ".conda", ".swiftpm",
                      ".local", ".cache", ".docker", ".orbstack", ".vscode", ".zsh_sessions",
                      ".bash_sessions"]
        return system.map { URL(fileURLWithPath: $0, isDirectory: true) }
            + library.map { home.appendingPathComponent("Library", isDirectory: true).appendingPathComponent($0, isDirectory: true) }
            + hidden.map { home.appendingPathComponent($0, isDirectory: true) }
    }
}
