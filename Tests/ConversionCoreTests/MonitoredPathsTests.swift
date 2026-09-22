import XCTest
@testable import ConversionCore

final class MonitoredPathsTests: XCTestCase {
    func testRootFiltersAliasesAndDirectoryBoundaries() {
        let home = URL(fileURLWithPath: "/Users/MonitoringFixture")
        let root = URL(fileURLWithPath: "/")
        let filtered = MonitoredPaths(folders: [root], ignoreSystemFiles: true, home: home)
        for path in ["/System/Library/font.ttf", "/Library/Caches/file.json", "/usr/local/file.txt",
                     "/private/var/folders/file.json", "/tmp/file.json", "/opt/homebrew/file.txt",
                     home.path + "/Library/Caches/file.json", home.path + "/.cargo/file.json",
                     home.path + "/.Trash/file.json", home.path + "/Library/../Library/Preferences/file.json"] {
            XCTAssertFalse(filtered.contains(URL(fileURLWithPath: path)), path)
        }
        for path in [home.path + "/Documents/file.json", home.path + "/Library/Fonts/file.ttf",
                     home.path + "/Library/Caches-other/file.json", "/Library-other/file.json",
                     "/System/Volumes/Data" + home.path + "/Documents/file.json",
                     "/Volumes/External/file.json"] {
            XCTAssertTrue(filtered.contains(URL(fileURLWithPath: path)), path)
        }
        XCTAssertFalse(filtered.contains(URL(fileURLWithPath: "/System/Volumes/Data/Library/Caches/file.json")))
        let unfiltered = MonitoredPaths(folders: [root])
        XCTAssertTrue(unfiltered.contains(URL(fileURLWithPath: "/Library/Caches/file.json")))
        XCTAssertFalse(unfiltered.contains(URL(fileURLWithPath: home.path + "/.allomer-123/input.json")))
        XCTAssertFalse(unfiltered.contains(URL(string: "https://example.com/file.json")!))
        let scoped = MonitoredPaths(folders: [home], excluding: [home.appendingPathComponent("excluded")])
        XCTAssertTrue(scoped.contains(home.appendingPathComponent("excluded-other/file.json")))
        XCTAssertFalse(scoped.contains(home.appendingPathComponent("excluded/file.json")))
        XCTAssertFalse(scoped.contains(URL(fileURLWithPath: home.path + "-other/file.json")))
        XCTAssertTrue(scoped.contains(URL(fileURLWithPath: "/System/Volumes/Data" + home.path + "/file.json")))
        let alias = MonitoredPaths(folders: [root], excluding: [URL(fileURLWithPath: "/System/Volumes/Data" + home.path)])
        XCTAssertFalse(alias.contains(home.appendingPathComponent("file.json")))
        XCTAssertFalse(MonitoredPaths(folders: [root], excluding: [root]).contains(home))
        let temporary = MonitoredPaths(folders: [URL(fileURLWithPath: "/private/var/folders")])
        XCTAssertTrue(temporary.contains(URL(fileURLWithPath: "/var/folders/missing-old-name.json")))
        XCTAssertTrue(temporary.contains(URL(fileURLWithPath: "/private/var/folders/missing-old-name.json")))
        XCTAssertTrue(temporary.contains(URL(fileURLWithPath: "/System/Volumes/Data/private/var/folders/missing-old-name.json")))
    }

    @MainActor
    func testMonitoringRefusesFoldersItWouldSkipEntirely() throws {
        let manager = FileManager.default
        // The system filter skips the temporary directory, so watching it there would convert nothing.
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watched = work.appendingPathComponent("watched")
        try manager.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let service = AutomaticConverter(engine: try ConversionEngine(),
                                         historyDirectory: work.appendingPathComponent("history")) { _ in }
        defer { service.stop() }
        XCTAssertThrowsError(try service.start(folders: [watched], ignoreSystemFiles: true)) { error in
            XCTAssertTrue("\(error)".contains("skips"), "\(error)")
        }
        // Excluding the watched folder itself is the same dead configuration without the system list.
        XCTAssertThrowsError(try service.start(folders: [watched], excluding: [watched]))
        XCTAssertNoThrow(try service.start(folders: [watched]))
    }

    @MainActor
    func testExternalRenamesRespectExclusionsAndSymlinks() async throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watched = work.appendingPathComponent("watched")
        let ignored = watched.appendingPathComponent("ignored")
        let allowed = watched.appendingPathComponent("ignored-other")
        for folder in [ignored, allowed] { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? manager.removeItem(at: work) }
        let link = watched.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: ignored)
        let paths = MonitoredPaths(folders: [watched], excluding: [link])
        XCTAssertFalse(paths.contains(ignored.appendingPathComponent("input.json")))
        var results: [Result<ConversionRecord, Error>] = []
        let service = AutomaticConverter(engine: try ConversionEngine(), historyDirectory: work.appendingPathComponent("history")) {
            results.append($0)
        }
        try service.start(folders: [watched], excluding: [link])
        defer { service.stop() }
        let bytes = Data(#"{"value":4}"#.utf8)
        for folder in [ignored, allowed] {
            let source = folder.appendingPathComponent("input.json")
            let target = folder.appendingPathComponent("input.yaml")
            try bytes.write(to: source)
            let move = Process()
            move.executableURL = URL(fileURLWithPath: "/bin/mv")
            move.arguments = [source.path, target.path]
            try move.run()
            move.waitUntilExit()
            XCTAssertEqual(move.terminationStatus, 0)
        }
        let deadline = Date().addingTimeInterval(8)
        while results.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(results.count, 1)
        let record = try XCTUnwrap(results.first).get()
        XCTAssertEqual(record.convertedURL.deletingLastPathComponent().path, allowed.path)
        XCTAssertEqual(try Data(contentsOf: ignored.appendingPathComponent("input.yaml")), bytes)
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: allowed.appendingPathComponent("input.json")), bytes)
        await service.stopAndWait()
    }
}
