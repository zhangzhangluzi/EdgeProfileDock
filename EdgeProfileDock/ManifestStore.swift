import Foundation

enum ManifestStore {
    private static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EdgeProfileDock")
    }

    private static var manifestURL: URL {
        supportDirectory.appendingPathComponent("created_launchers.json")
    }

    static func load() -> [CreatedLauncher] {
        repairFromDisk(loadRaw())
    }

    static func save(_ launchers: [CreatedLauncher]) throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(launchers)
        try data.write(to: manifestURL, options: .atomic)
    }

    static func upsert(_ launcher: CreatedLauncher) throws {
        var items = load()
        items.removeAll { $0.appPath == launcher.appPath }
        items.append(launcher)
        items.sort { $0.createdAt < $1.createdAt }
        try save(items)
    }

    static func remove(appPaths: Set<String>) throws {
        var items = load()
        items.removeAll { appPaths.contains($0.appPath) }
        try save(items)
    }

    static func clearSupportFiles() {
        let fm = FileManager.default
        try? fm.removeItem(at: supportDirectory)
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.local.EdgeProfileDock")
    }

    private static func loadRaw() -> [CreatedLauncher] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([CreatedLauncher].self, from: data)
        } catch {
            return []
        }
    }

    private static func repairFromDisk(_ items: [CreatedLauncher]) -> [CreatedLauncher] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: LauncherBuilder.applicationsDirectory, includingPropertiesForKeys: nil
        ) else { return [] }
        let previous = Dictionary(items.map { ($0.appPath, $0) }, uniquingKeysWith: { first, _ in first })
        let repaired: [CreatedLauncher] = contents.compactMap { url in
            guard let info = LauncherBuilder.ownedLauncherInfo(at: url) else { return nil }
            let browser = (info["EPDBrowser"] as? String).flatMap(EdgeBrowser.init(rawValue:)) ?? .edge
            let directory = info["EPDProfileDirectory"] as? String ?? "Default"
            let saved = previous[url.path]
            let displayName = (info["CFBundleDisplayName"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let prefix = "Edge Profile - "
            let bundleName = displayName.hasPrefix(prefix) ? String(displayName.dropFirst(prefix.count)) : displayName
            let originalName = saved.flatMap { $0.browser == browser && $0.profileDirectory == directory ? $0.displayName : nil }
            return CreatedLauncher(
                browser: browser,
                profileDirectory: directory,
                displayName: originalName ?? bundleName,
                appPath: url.path,
                createdAt: saved?.createdAt
                    ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            )
        }.sorted { left, right in
            (left.createdAt, left.appPath) < (right.createdAt, right.appPath)
        }
        if repaired != items {
            try? save(repaired)
        }
        return repaired
    }
}
