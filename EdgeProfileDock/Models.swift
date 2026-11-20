import Foundation

enum EdgeBrowser: String, CaseIterable, Identifiable, Codable {
    case edge = "edge"
    case edgeBeta = "edgeBeta"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .edge: return "Microsoft Edge"
        case .edgeBeta: return "Microsoft Edge Beta"
        }
    }

    var appName: String {
        switch self {
        case .edge: return "Microsoft Edge.app"
        case .edgeBeta: return "Microsoft Edge Beta.app"
        }
    }

    var appPath: String {
        "/Applications/\(appName)"
    }

    var bundleIdentifier: String {
        switch self {
        case .edge: return "com.microsoft.edgemac"
        case .edgeBeta: return "com.microsoft.edgemac.Beta"
        }
    }

    var executablePath: String {
        "\(appPath)/Contents/MacOS/\(displayName)"
    }

    var supportFolderName: String {
        switch self {
        case .edge: return "Microsoft Edge"
        case .edgeBeta: return "Microsoft Edge Beta"
        }
    }

    var localStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(supportFolderName)/Local State")
    }

    var userDataRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(supportFolderName)")
    }
}

struct EdgeProfile: Identifiable, Hashable {
    var id: String { "\(browser.rawValue)::\(directory)" }
    let browser: EdgeBrowser
    let directory: String
    let displayName: String
    let account: String
    let isAvailable: Bool
    let avatarURL: URL?
}

struct CreatedLauncher: Identifiable, Codable, Hashable {
    var id: String { appPath }
    let browser: EdgeBrowser
    let profileDirectory: String
    let displayName: String
    let appPath: String
    let createdAt: Date
}

enum WindowDock {
    static let style = "window-dock"
    static let monitorArgument = "--edge-profile-dock-monitor"
    static let managerBundleIdentifier = "com.local.EdgeProfileDock"
    static let focusNotification = Notification.Name("com.local.EdgeProfileDock.focusWindow")
}
