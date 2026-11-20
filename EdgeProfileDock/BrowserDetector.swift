import Foundation

enum BrowserDetector {
    static func isInstalled(_ browser: EdgeBrowser) -> Bool {
        FileManager.default.fileExists(atPath: browser.appPath)
    }

    static func availableBrowsers() -> [EdgeBrowser] {
        EdgeBrowser.allCases.filter(isInstalled)
    }
}
