import AppKit
import Foundation

final class StubApp: NSObject, NSApplicationDelegate {
    private var managerExit: DispatchSourceProcess?
    private var browser: EdgeBrowser {
        EdgeBrowser(rawValue: Bundle.main.object(forInfoDictionaryKey: "EPDBrowser") as? String ?? "") ?? .edge
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: WindowDock.monitorArgument) {
            if let pid = arguments.dropFirst(index + 1).first.flatMap(Int32.init),
               let manager = NSRunningApplication(processIdentifier: pid),
               !manager.isTerminated, manager.bundleIdentifier == WindowDock.managerBundleIdentifier,
               Bundle.main.object(forInfoDictionaryKey: "EPDWrapperStyle") as? String == WindowDock.style {
                showDockTile(untilExitOf: manager)
            } else {
                NSApp.terminate(nil)
            }
            return
        }

        defer { NSApp.terminate(nil) }
        let profileDirectory = Bundle.main.object(forInfoDictionaryKey: "EPDProfileDirectory") as? String ?? "Default"
        openProfile(profileDirectory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard managerExit != nil, let identifier = Bundle.main.bundleIdentifier else { return false }
        if let application = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier).first {
            NSApp.yieldActivation(to: application)
        }
        DistributedNotificationCenter.default().postNotificationName(
            WindowDock.focusNotification, object: identifier, userInfo: nil, deliverImmediately: true
        )
        return false
    }

    private func showDockTile(untilExitOf manager: NSRunningApplication) {
        let exit = DispatchSource.makeProcessSource(identifier: manager.processIdentifier, eventMask: .exit, queue: .main)
        exit.setEventHandler { NSApp.terminate(nil) }
        managerExit = exit
        exit.resume()
        // 由 Dock 直接使用启动器图标，运行和固定时显示同一张白底头像。
        guard !manager.isTerminated, NSApp.setActivationPolicy(.regular) else {
            NSApp.terminate(nil)
            return
        }
    }

    private func openProfile(_ profileDirectory: String) {
        let executable = URL(fileURLWithPath: browser.executablePath)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            presentError("未找到 \(browser.displayName)", "请先安装对应的浏览器。")
            return
        }

        // Edge 会把参数交给正在运行的实例。提供新标签页作为后备，已有窗口可以接收它。
        // --focus 优先复用目标资料已有的新标签页。
        let newTab = "edge://newtab/"
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--profile-directory=\(profileDirectory)",
            "--focus=\(newTab),chrome://newtab/",
            newTab
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            presentError("无法打开 \(browser.displayName)", error.localizedDescription)
        }
    }

    private func presentError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = StubApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
