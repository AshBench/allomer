import AppKit
import ConversionCore

extension ConversionModel {
    func resolveFolders(key: String) -> [URL] {
        (defaults.array(forKey: key) as? [Data] ?? []).compactMap { data in
            do {
                var stale = false
                return try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                               bookmarkDataIsStale: &stale).resolvingSymlinksInPath().standardizedFileURL
            } catch {
                self.error = "A saved folder could not be found. Add that folder again."
                return nil
            }
        }
    }

    func chooseFolder(excluded: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = excluded ? "Exclude" : "Watch"
        guard panel.runModal() == .OK else { return }
        var selected = excluded ? exclusions : folders
        for url in panel.urls {
            let folder = url.resolvingSymlinksInPath().standardizedFileURL
            if !selected.contains(folder) { selected.append(folder) }
        }
        updateFolders(selected, excluded: excluded)
        if !excluded, !folders.isEmpty { setMonitoring(true) }
    }

    func removeFolder(_ url: URL, excluded: Bool) {
        updateFolders((excluded ? exclusions : folders).filter { $0 != url }, excluded: excluded)
    }

    private func updateFolders(_ selected: [URL], excluded: Bool) {
        // One folder that has since been deleted must not block removing or adding the others.
        var kept: [URL] = []
        var bookmarks: [Data] = []
        for url in selected {
            guard let data = try? url.bookmarkData() else { continue }
            kept.append(url)
            bookmarks.append(data)
        }
        if kept.count != selected.count { error = "A folder is no longer available. It was removed from the list." }
        defaults.set(bookmarks, forKey: excluded ? PreferenceKey.excludedFolders : PreferenceKey.watchedFolders)
        if excluded { exclusions = kept } else { folders = kept }
        if monitoring { setMonitoring(canMonitor) }
    }

    func setMonitoring(_ enabled: Bool) {
        guard let automatic else { return }
        do {
            if enabled {
                guard !watchWholeSystem || diskAccess == .available else {
                    throw ConversionError.message("Check Full Disk Access before starting whole-system monitoring.")
                }
                try automatic.start(folders: monitoringFolders, excluding: exclusions, ignoreSystemFiles: ignoreSystemFiles)
                automaticStatus = watchWholeSystem ? "Watching the system for extension changes." : "Watching for extension changes."
            } else {
                automatic.stop()
                automaticStatus = "Automatic conversion is paused."
            }
            defaults.set(enabled, forKey: PreferenceKey.monitoring)
        } catch {
            self.error = error.localizedDescription
            defaults.set(false, forKey: PreferenceKey.monitoring)
        }
    }

    func setWatchWholeSystem(_ enabled: Bool) async {
        if enabled { await refreshDiskAccess(enableWhenAvailable: true) }
        else {
            accessCheckGeneration = UUID()
            checkingDiskAccess = false
            applyWholeSystem(false)
        }
    }

    func refreshDiskAccess(enableWhenAvailable: Bool = false) async {
        guard (watchWholeSystem || enableWhenAvailable), !checkingDiskAccess, !isQuitting else { return }
        let generation = UUID()
        accessCheckGeneration = generation
        checkingDiskAccess = true
        let read = readDiskAccess
        let result = await Task.detached(priority: .utility) { read() }.value
        guard accessCheckGeneration == generation, !isQuitting else { return }
        checkingDiskAccess = false
        diskAccess = result
        if result != .available { applyWholeSystem(false) }
        else if enableWhenAvailable { applyWholeSystem(true) }
    }

    private func applyWholeSystem(_ enabled: Bool) {
        guard watchWholeSystem != enabled else { return }
        watchWholeSystem = enabled
        defaults.set(enabled, forKey: PreferenceKey.watchWholeSystem)
        if monitoring { setMonitoring(canMonitor) }
    }

}
