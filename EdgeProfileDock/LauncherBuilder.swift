import AppKit
import Foundation

enum LauncherBuilderError: LocalizedError {
    case applicationsNotWritable
    case browserMissing(EdgeBrowser)
    case stubMissing
    case launcherNotOwned(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationsNotWritable:
            return "无法写入 ~/Applications，请检查文件夹权限。"
        case .browserMissing(let browser):
            return "未找到 \(browser.displayName)。"
        case .stubMissing:
            return "缺少启动器内核（LauncherStub）。请重新运行 ./scripts/build.sh。"
        case .launcherNotOwned(let name):
            return "已取消删除「\(name)」。此操作仅适用于 EdgeProfileDock 创建的启动器。"
        case .writeFailed(let message):
            return "创建启动器失败：\(message)"
        }
    }
}

enum LauncherBuilder {
    static var applicationsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }

    /// 优先使用 App 内的启动器内核。
    static func stubBinaryURL() -> URL? {
        let candidates: [URL] = [
            Bundle.main.resourceURL?
                .appendingPathComponent("LauncherStub"),
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("LauncherStub"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("EdgeProfileDock/build/LauncherStub")
        ].compactMap { $0 }

        let fm = FileManager.default
        for url in candidates {
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static func ensureApplicationsDirectory() throws {
        let fm = FileManager.default
        let dir = applicationsDirectory
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw LauncherBuilderError.applicationsNotWritable
        }
        guard fm.isWritableFile(atPath: dir.path) else {
            throw LauncherBuilderError.applicationsNotWritable
        }
    }

    static func launcherURL(for profile: EdgeProfile) -> URL {
        let safe = sanitizeFileName(profile.displayName)
        return applicationsDirectory.appendingPathComponent("Edge Profile - \(safe).app")
    }

    static func exists(for profile: EdgeProfile) -> Bool {
        FileManager.default.fileExists(atPath: launcherURL(for: profile).path)
    }

    static func ownedLauncherInfo(at url: URL) -> NSDictionary? {
        guard url.pathExtension == "app",
              url.deletingLastPathComponent().standardizedFileURL.path == applicationsDirectory.standardizedFileURL.path,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink == false,
              let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              info["EPDOwner"] as? String == "EdgeProfileDock" else { return nil }
        return info
    }

    static func ownsLauncher(for profile: EdgeProfile) -> Bool {
        guard let info = ownedLauncherInfo(at: launcherURL(for: profile)) else { return false }
        return info["EPDBrowser"] as? String == profile.browser.rawValue
            && info["EPDProfileDirectory"] as? String == profile.directory
    }

    /// 创建独立资料入口，供快捷启动与窗口图标使用。
    @discardableResult
    static func create(for profile: EdgeProfile, overwrite: Bool) throws -> CreatedLauncher {
        try ensureApplicationsDirectory()
        let fm = FileManager.default
        guard fm.fileExists(atPath: profile.browser.appPath) else {
            throw LauncherBuilderError.browserMissing(profile.browser)
        }
        guard let stubSource = stubBinaryURL() else {
            throw LauncherBuilderError.stubMissing
        }

        let appURL = launcherURL(for: profile)
        guard overwrite || !fm.fileExists(atPath: appURL.path) else {
            throw LauncherBuilderError.writeFailed("启动器已存在。")
        }

        let stagingDirectory = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: applicationsDirectory,
            create: true
        )
        defer { try? fm.removeItem(at: stagingDirectory) }
        let stagedApp = stagingDirectory.appendingPathComponent(appURL.lastPathComponent)
        let contents = stagedApp.appendingPathComponent("Contents")
        let macos = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let execName = "EdgeProfileLauncher"
        let execURL = macos.appendingPathComponent(execName)
        try fm.copyItem(at: stubSource, to: execURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)

        let display = "Edge Profile - \(sanitizeFileName(profile.displayName))"
        let bundleID = bundleIdentifier(browser: profile.browser, directory: profile.directory)
        let usedAvatar = try ProfileArtwork.writeIcon(for: profile, to: resources.appendingPathComponent("AppIcon.icns"))

        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "zh-Hans",
            "CFBundleDisplayName": display,
            "CFBundleExecutable": execName,
            "CFBundleIconFile": "AppIcon",
            "CFBundleIdentifier": bundleID,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": display,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "5",
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            "NSSupportsAutomaticTermination": false,
            "NSSupportsSuddenTermination": false,
            "EPDOwner": "EdgeProfileDock",
            "EPDBrowser": profile.browser.rawValue,
            "EPDProfileDirectory": profile.directory,
            "EPDWrapperStyle": WindowDock.style,
            "EPDIconSource": usedAvatar ? "local-avatar" : "initial"
        ]

        let infoURL = contents.appendingPathComponent("Info.plist")
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: infoURL, options: .atomic)
        try "APPL????".write(to: contents.appendingPathComponent("PkgInfo"), atomically: true, encoding: .utf8)

        // Avoid Gatekeeper quarantine blocking first launch
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", stagedApp.path]
        if (try? task.run()) != nil {
            task.waitUntilExit()
        }

        if overwrite && fm.fileExists(atPath: appURL.path) {
            if ownsLauncher(for: profile) {
                // 保留外层 App 的文件标识，程序坞的固定引用才能继续指向它。
                let installedContents = appURL.appendingPathComponent("Contents", isDirectory: true)
                _ = try fm.replaceItemAt(installedContents, withItemAt: contents, options: .usingNewMetadataOnly)
            } else {
                _ = try fm.replaceItemAt(appURL, withItemAt: stagedApp, options: .usingNewMetadataOnly)
            }
        } else {
            try fm.moveItem(at: stagedApp, to: appURL)
        }

        let launcher = CreatedLauncher(
            browser: profile.browser,
            profileDirectory: profile.directory,
            displayName: profile.displayName,
            appPath: appURL.path,
            createdAt: Date()
        )
        try ManifestStore.upsert(launcher)
        return launcher
    }

    static func windowDockIdentifier(for launcher: CreatedLauncher) -> String? {
        let url = URL(fileURLWithPath: launcher.appPath)
        let identifier = bundleIdentifier(browser: launcher.browser, directory: launcher.profileDirectory)
        guard let info = ownedLauncherInfo(at: url),
              info["EPDWrapperStyle"] as? String == WindowDock.style,
              info["EPDBrowser"] as? String == launcher.browser.rawValue,
              info["EPDProfileDirectory"] as? String == launcher.profileDirectory,
              info["CFBundleIdentifier"] as? String == identifier else { return nil }
        return identifier
    }

    static func delete(appPaths: [String]) throws {
        let fm = FileManager.default
        let existing = appPaths.filter { fm.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if let foreign = existing.first(where: { ownedLauncherInfo(at: $0) == nil }) {
            throw LauncherBuilderError.launcherNotOwned(foreign.lastPathComponent)
        }
        for url in existing {
            try fm.removeItem(at: url)
        }
        try ManifestStore.remove(appPaths: Set(appPaths))
    }

    static func deleteAllOwnedLaunchers() throws {
        try delete(appPaths: ManifestStore.load().map(\.appPath))
    }

    static func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let parts = name.components(separatedBy: invalid)
        let joined = parts.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "Profile" : joined
    }

    private static func sanitizeBundleToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private static func bundleIdentifier(browser: EdgeBrowser, directory: String) -> String {
        "com.local.EdgeProfileDock.launcher.\(browser.rawValue).\(sanitizeBundleToken(directory))"
    }
}
