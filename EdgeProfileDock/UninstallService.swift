import AppKit
import Foundation

enum UninstallMode {
    case keepLaunchers
    case removeEverything
}

enum UninstallService {
    static func preferredInstallPath() -> String {
        "/Applications/EdgeProfileDock.app"
    }

    static func currentAppURL() -> URL {
        Bundle.main.bundleURL
    }

    static func isRunningFromApplications() -> Bool {
        let path = currentAppURL().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/")
    }

    /// Copy this app to /Applications (or ~/Applications fallback) and relaunch.
    static func moveToApplications() throws -> URL {
        let fm = FileManager.default
        let source = currentAppURL()
        var destination = URL(fileURLWithPath: preferredInstallPath())

        let appsDir = URL(fileURLWithPath: "/Applications")
        if !fm.isWritableFile(atPath: appsDir.path) {
            let userApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            try fm.createDirectory(at: userApps, withIntermediateDirectories: true)
            destination = userApps.appendingPathComponent("EdgeProfileDock.app")
        }

        guard source.standardizedFileURL.path != destination.standardizedFileURL.path else {
            return destination
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        NSWorkspace.shared.open(destination)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
        return destination
    }

    static func performUninstall(mode: UninstallMode) throws {
        if mode == .removeEverything {
            try LauncherBuilder.deleteAllOwnedLaunchers()
        }

        ManifestStore.clearSupportFiles()

        // Clear preferences domain
        if let bid = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bid)
        }

        let appPath = currentAppURL().path
        let escaped = shellEscape(appPath)
        let script = """
        #!/bin/bash
        sleep 1
        rm -rf \(escaped)
        rm -rf "$HOME/Library/Application Support/EdgeProfileDock"
        rm -f "$HOME/Library/Preferences/\(Bundle.main.bundleIdentifier ?? "com.local.EdgeProfileDock").plist"
        """

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("epd-uninstall-\(UUID().uuidString).sh")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [tmp.path]
        try process.run()

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    private static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
