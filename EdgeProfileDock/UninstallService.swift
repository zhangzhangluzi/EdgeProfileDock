import AppKit
import Foundation
import Security
import ServiceManagement

enum UninstallMode {
    case keepLaunchers
    case removeEverything
}

enum InstallError: LocalizedError {
    case invalidSignature
    case incompatibleSignature
    case relaunchFailed

    var errorDescription: String? {
        switch self {
        case .invalidSignature: return "新版应用的签名无效。"
        case .incompatibleSignature: return "新版应用与已安装版本的签名身份不同。"
        case .relaunchFailed: return "已安装应用，但无法安排重新打开，请从「应用程序」打开。"
        }
    }
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
        try installCopy(from: source, to: destination)
        do {
            try relaunchAfterExit(destination, waitingFor: ProcessInfo.processInfo.processIdentifier)
        } catch {
            throw InstallError.relaunchFailed
        }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
        return destination
    }

    @discardableResult
    static func relaunchAfterExit(
        _ destination: URL,
        waitingFor pid: pid_t,
        using opener: URL = URL(fileURLWithPath: "/usr/bin/open")
    ) throws -> Process {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", """
            attempt=0
            while kill -0 "$1" 2>/dev/null; do
                [ "$attempt" -lt 100 ] || exit 1
                /bin/sleep 0.1
                attempt=$((attempt + 1))
            done
            exec "$3" -a "$2"
            """, "EdgeProfileDock", String(pid), destination.path, opener.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        return helper
    }

    static func installCopy(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let stage = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination.deletingLastPathComponent(),
            create: true
        )
        defer { try? fm.removeItem(at: stage) }
        let candidate = stage.appendingPathComponent(destination.lastPathComponent)
        try fm.copyItem(at: source, to: candidate)
        guard Bundle(url: candidate)?.bundleIdentifier == WindowDock.managerBundleIdentifier else {
            throw InstallError.invalidSignature
        }

        var candidateCode: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate)
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess,
              let candidateCode,
              SecStaticCodeCheckValidity(candidateCode, flags, nil) == errSecSuccess else {
            throw InstallError.invalidSignature
        }

        if fm.fileExists(atPath: destination.path) {
            var installedCode: SecStaticCode?
            var requirement: SecRequirement?
            guard SecStaticCodeCreateWithPath(destination as CFURL, [], &installedCode) == errSecSuccess,
                  let installedCode,
                  SecCodeCopyDesignatedRequirement(installedCode, [], &requirement) == errSecSuccess,
                  let requirement,
                  SecStaticCodeCheckValidity(candidateCode, flags, requirement) == errSecSuccess else {
                throw InstallError.incompatibleSignature
            }
            _ = try fm.replaceItemAt(destination, withItemAt: candidate, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: candidate, to: destination)
        }
    }

    static func performUninstall(mode: UninstallMode) throws {
        let loginItem = SMAppService.mainApp
        if loginItem.status == .enabled || loginItem.status == .requiresApproval {
            try loginItem.unregister()
        }
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
