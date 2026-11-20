import AppKit
import ApplicationServices
import Combine

@MainActor
final class ProfileWindowMonitor: ObservableObject {
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "ShowProfileWindowIcons") {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: "ShowProfileWindowIcons")
            updateMonitoring()
        }
    }
    @Published private(set) var hasAccessibility = AXIsProcessTrusted()
    @Published private(set) var displayedCount = 0
    @Published private(set) var supportsWindowIcons = false

    private var launchers: [String: CreatedLauncher] = [:]
    private var trackers: [EdgeBrowser: EdgeWindows] = [:]
    private var snapshots: [EdgeBrowser: [String: [AXUIElement]]] = [:]
    private var desired: Set<String> = []
    private var running: [String: NSRunningApplication] = [:]
    private var pending: Set<String> = []
    private var failed: Set<String> = []
    private var timer: Timer?
    private var refreshWork: DispatchWorkItem?
    private var followUpsRemaining = 3

    func configure(_ launchers: [CreatedLauncher]) {
        var tracked: [String: CreatedLauncher] = [:]
        for launcher in launchers {
            if let id = LauncherBuilder.windowDockIdentifier(for: launcher) {
                tracked[id] = launcher
            }
        }
        self.launchers = tracked
        supportsWindowIcons = !tracked.isEmpty
        trackers.values.forEach { $0.reloadProfiles() }
        failed.removeAll()
        updateMonitoring()
    }

    var activityDescription: String {
        guard isEnabled else { return "监听已暂停" }
        guard hasAccessibility else { return "等待辅助功能授权" }
        guard supportsWindowIcons else { return "等待创建资料启动器" }
        return "正在监听 · \(displayedCount) 个资料图标"
    }

    func openAccessibilitySettings() {
        checkAccessibility()
        if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(settings)
        }
    }

    func requestAccessibility() {
        let flag = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([flag: true] as CFDictionary)
        checkAccessibility()
    }

    func checkAccessibility() {
        if isEnabled {
            refresh()
        } else {
            readAccessibility()
        }
    }

    func updateProfiles(_ profiles: [EdgeProfile], for browser: EdgeBrowser) {
        guard let tracker = trackers[browser] else { return }
        tracker.updateProfiles(profiles)
        scheduleRefresh()
    }

    func refreshIcons(for launchers: [CreatedLauncher]) {
        for launcher in launchers {
            if let id = LauncherBuilder.windowDockIdentifier(for: launcher), let app = running[id], app.terminate() {
                running.removeValue(forKey: id)
            }
        }
        refresh()
        scheduleRefresh()
    }

    private func readAccessibility() {
        let trusted = AXIsProcessTrusted()
        if hasAccessibility != trusted { hasAccessibility = trusted }
    }

    private func updateMonitoring() {
        guard isEnabled else {
            timer?.invalidate()
            timer = nil
            refreshWork?.cancel()
            refreshWork = nil
            DistributedNotificationCenter.default().removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            trackers.removeAll()
            snapshots.removeAll()
            failed.removeAll()
            followUpsRemaining = 3
            reconcile([])
            return
        }

        if timer == nil {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(focusRequest(_:)), name: WindowDock.focusNotification,
                object: nil, suspensionBehavior: .deliverImmediately
            )
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                         NSWorkspace.didWakeNotification] {
                NSWorkspace.shared.notificationCenter.addObserver(
                    self, selector: #selector(workspaceChanged(_:)), name: name, object: nil
                )
            }
        }
        refresh()
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        if notification.name != NSWorkspace.didWakeNotification {
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  launchers.values.contains(where: { $0.browser.bundleIdentifier == app.bundleIdentifier }) else { return }
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        followUpsRemaining = 3
        enqueueRefresh(after: 0.15)
    }

    private func enqueueRefresh(after delay: TimeInterval) {
        guard refreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.refreshWork = nil
            self?.refresh()
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setFallbackInterval(_ interval: TimeInterval) {
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = interval / 12
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        guard isEnabled else { return }
        readAccessibility()
        guard hasAccessibility else {
            trackers.removeAll()
            snapshots.removeAll()
            reconcile([])
            setFallbackInterval(2.5)
            return
        }

        var needsRecovery = false
        var needsFollowUp = false
        let browsers = Set(launchers.values.map(\.browser))
        for browser in EdgeBrowser.allCases {
            guard browsers.contains(browser),
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier)
                      .first(where: { !$0.isTerminated }) else {
                trackers.removeValue(forKey: browser)
                snapshots.removeValue(forKey: browser)
                continue
            }
            if trackers[browser]?.application.processIdentifier != app.processIdentifier {
                snapshots.removeValue(forKey: browser)
                trackers[browser] = EdgeWindows(browser: browser, application: app) { [weak self] in
                    Task { @MainActor [weak self] in self?.scheduleRefresh() }
                }
            }
            guard let tracker = trackers[browser] else { continue }
            if let windows = tracker.byProfileDirectory() {
                snapshots[browser] = windows
                needsRecovery = needsRecovery || !tracker.observesWindowChanges
                needsFollowUp = needsFollowUp || tracker.needsFollowUp
            } else {
                needsRecovery = true
            }
        }
        let waitingForLauncher = reconcile(Set(launchers.compactMap { id, launcher in
            snapshots[launcher.browser]?[launcher.profileDirectory]?.isEmpty == false ? id : nil
        }))
        setFallbackInterval(needsRecovery || waitingForLauncher ? 2.5 : 12)
        if needsRecovery || needsFollowUp || waitingForLauncher {
            // 窗口创建通知有时早于工具栏出现。
            if followUpsRemaining > 0 && refreshWork == nil {
                followUpsRemaining -= 1
                enqueueRefresh(after: 0.4)
            }
        } else {
            followUpsRemaining = 3
        }
    }

    @discardableResult
    private func reconcile(_ ids: Set<String>) -> Bool {
        desired = ids
        failed.formIntersection(ids)
        for (id, app) in running where app.isTerminated || !ids.contains(id) {
            if !app.isTerminated { app.terminate() }
            running.removeValue(forKey: id)
        }
        updateDisplayedCount()

        var waitingForLauncher = false
        for id in ids where running[id] == nil && !pending.contains(id) && !failed.contains(id) {
            guard let launcher = launchers[id] else { continue }
            let url = URL(fileURLWithPath: launcher.appPath)
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { !$0.isTerminated }) else {
                waitingForLauncher = true
                continue
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.promptsUserIfNeeded = false
            configuration.arguments = [WindowDock.monitorArgument, String(ProcessInfo.processInfo.processIdentifier)]
            pending.insert(id)
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pending.remove(id)
                    guard self.desired.contains(id), self.launchers[id]?.appPath == launcher.appPath else {
                        app?.terminate()
                        return
                    }
                    if error == nil, let app, !app.isTerminated {
                        self.running[id] = app
                        self.updateDisplayedCount()
                    } else {
                        self.failed.insert(id)
                    }
                }
            }
        }
        return waitingForLauncher
    }

    private func updateDisplayedCount() {
        if displayedCount != running.count { displayedCount = running.count }
    }

    @objc private func focusRequest(_ notification: Notification) {
        guard isEnabled, AXIsProcessTrusted(),
              let id = notification.object as? String, let launcher = launchers[id],
              let tracker = trackers[launcher.browser],
              let windows = tracker.byProfileDirectory(),
              let target = windows[launcher.profileDirectory]?.first else { return }
        tracker.focus(target)
    }
}
