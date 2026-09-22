import XCTest
@testable import ConvertApp

/// Watched and excluded folders are the only preference stored as bookmarks. Everything automatic
/// stops working if they do not come back, so the round trip is checked against real directories.
final class WatchedFolderTests: XCTestCase {
    @MainActor
    func testWatchedAndExcludedFoldersSurviveRelaunch() throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watched = work.appendingPathComponent("watched")
        let second = work.appendingPathComponent("second")
        let excluded = watched.appendingPathComponent("excluded")
        for folder in [watched, second, excluded] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? manager.removeItem(at: work) }

        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ConversionModel(defaults: defaults)

        // removeFolder is the only path into the bookmark write that does not open a panel.
        let extra = work.appendingPathComponent("removed")
        try manager.createDirectory(at: extra, withIntermediateDirectories: true)
        model.folders = [watched, second, extra]
        model.exclusions = [excluded]
        model.removeFolder(extra, excluded: false)
        model.removeFolder(work.appendingPathComponent("never-added"), excluded: true)

        XCTAssertEqual(model.folders, [watched, second])
        XCTAssertEqual((defaults.array(forKey: "watchedFolders") as? [Data])?.count, 2)
        XCTAssertEqual((defaults.array(forKey: "excludedFolders") as? [Data])?.count, 1)

        let relaunched = ConversionModel(defaults: defaults)
        XCTAssertEqual(relaunched.resolveFolders(key: "watchedFolders").map(\.path),
                       [watched, second].map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        XCTAssertEqual(relaunched.resolveFolders(key: "excludedFolders").map(\.path),
                       [excluded.resolvingSymlinksInPath().standardizedFileURL.path])
        XCTAssertNil(relaunched.error)

        // A folder that moved away is dropped with a message instead of resolving to a stale path.
        try manager.removeItem(at: second)
        let missing = ConversionModel(defaults: defaults)
        XCTAssertEqual(missing.resolveFolders(key: "watchedFolders").map(\.path),
                       [watched.resolvingSymlinksInPath().standardizedFileURL.path])
        XCTAssertNotNil(missing.error)

        // A folder deleted from disk must not block editing the rest of the list.
        model.removeFolder(watched, excluded: false)
        XCTAssertEqual(model.folders, [])
        XCTAssertNotNil(model.error)

        // Removing the last folder must clear the saved list, not leave the previous bookmarks.
        model.removeFolder(second, excluded: false)
        XCTAssertEqual((defaults.array(forKey: "watchedFolders") as? [Data])?.count, 0)
        XCTAssertFalse(model.canMonitor)
        XCTAssertEqual((defaults.array(forKey: "excludedFolders") as? [Data])?.count, 1)
        XCTAssertEqual(ConversionModel(defaults: defaults).resolveFolders(key: "watchedFolders"), [])
    }
}
