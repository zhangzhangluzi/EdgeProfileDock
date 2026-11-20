import AppKit
import Foundation

@MainActor
final class StubApp: NSObject, NSApplicationDelegate {
    private var managerExit: DispatchSourceProcess?
    private var replyTimeout: DispatchWorkItem?
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

        openProfile()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard managerExit != nil, let identifier = Bundle.main.bundleIdentifier else { return false }
        if let application = runningBrowser {
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

    private var runningBrowser: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier)
            .first(where: { !$0.isTerminated })
    }

    private func openProfile() {
        guard let application = runningBrowser else {
            launchBrowser()
            return
        }
        guard let identifier = Bundle.main.bundleIdentifier,
              NSRunningApplication.runningApplications(withBundleIdentifier: WindowDock.managerBundleIdentifier)
                  .contains(where: { !$0.isTerminated }) else {
            finishOpen(error: "请先打开 EdgeProfileDock，或使用浏览器的「个人资料」菜单。")
            return
        }

        let token = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self, selector: #selector(openReply(_:)), name: WindowDock.openProfileReply,
            object: token, suspensionBehavior: .deliverImmediately
        )
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishOpen(error: "EdgeProfileDock 未响应。请确认管理工具和启动器都已更新，再试一次。")
        }
        replyTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        NSApp.yieldActivation(to: application)
        center.postNotificationName(
            WindowDock.openProfileNotification, object: identifier,
            userInfo: ["request": token, "pid": ProcessInfo.processInfo.processIdentifier], deliverImmediately: true
        )
    }

    @objc private func openReply(_ notification: Notification) {
        guard let value = notification.userInfo?["result"] as? String,
              let result = WindowDock.OpenResult(rawValue: value) else { return }
        switch result {
        case .handled:
            finishOpen()
        case .browserClosed:
            if runningBrowser == nil {
                stopWaitingForReply()
                launchBrowser()
            } else {
                finishOpen(error: "浏览器正在启动，请稍后再试。")
            }
        case .accessibilityRequired:
            finishOpen(error: "请在系统设置中为 EdgeProfileDock 开启辅助功能权限，再试一次。")
        case .unavailable:
            finishOpen(error: "无法确认资料窗口。请刷新 EdgeProfileDock 中的资料，或使用浏览器的「个人资料」菜单。")
        }
    }

    private func launchBrowser() {
        guard FileManager.default.isExecutableFile(atPath: browser.executablePath) else {
            finishOpen(error: "请先安装 \(browser.displayName)。")
            return
        }
        let directory = Bundle.main.object(forInfoDictionaryKey: "EPDProfileDirectory") as? String ?? "Default"
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--profile-directory=\(directory)"]
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: browser.appPath), configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                self?.finishOpen(error: error?.localizedDescription ?? (app == nil ? "没有收到浏览器启动结果。" : nil))
            }
        }
    }

    private func stopWaitingForReply() {
        replyTimeout?.cancel()
        replyTimeout = nil
        DistributedNotificationCenter.default().removeObserver(self, name: WindowDock.openProfileReply, object: nil)
    }

    private func finishOpen(error: String? = nil) {
        stopWaitingForReply()
        if let error {
            presentError("无法打开资料", error)
        }
        NSApp.terminate(nil)
    }

    private func presentError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = StubApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
