import AppKit
import ApplicationServices
import Combine

struct LauncherRetryState {
    private(set) var attempts = 0
    private(set) var retryAfter: TimeInterval = 0

    var exhausted: Bool { attempts >= 3 }

    mutating func recordFailure(at time: TimeInterval) {
        attempts += 1
        retryAfter = time + (attempts == 1 ? 1 : 4)
    }

    func canRetry(at time: TimeInterval) -> Bool {
        !exhausted && time >= retryAfter
    }
}

@MainActor
final class ProfileWindowMonitor: ObservableObject {
    private struct ProfileOpening {
        let pid: pid_t
        let expiresAt: TimeInterval
    }

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
    @Published private(set) var failedCount = 0

    private var launchers: [String: CreatedLauncher] = [:]
    private var trackers: [EdgeBrowser: EdgeWindows] = [:]
    private var snapshots: [EdgeBrowser: [String: [AXUIElement]]] = [:]
    private var desired: Set<String> = []
    private var running: [String: NSRunningApplication] = [:]
    private var pending: Set<String> = []
    private var failed: [String: LauncherRetryState] = [:]
    private var openingProfiles: [String: ProfileOpening] = [:]
    private var timer: Timer?
    private var refreshWork: DispatchWorkItem?
    private var followUpsRemaining = 3
    private var showingFocusError = false

    init() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(openProfileRequest(_:)), name: WindowDock.openProfileNotification,
            object: nil, suspensionBehavior: .deliverImmediately
        )
    }

    func configure(_ launchers: [CreatedLauncher]) {
        var tracked: [String: CreatedLauncher] = [:]
        for launcher in launchers {
            if let id = LauncherBuilder.windowDockIdentifier(for: launcher) {
                tracked[id] = launcher
            }
        }
        self.launchers = tracked
        openingProfiles = openingProfiles.filter { tracked[$0.key] != nil }
        supportsWindowIcons = !tracked.isEmpty
        trackers.values.forEach { $0.reloadProfiles(forceWindowNames: true) }
        failed.removeAll()
        updateFailedCount()
        updateMonitoring()
    }

    var activityDescription: String {
        guard isEnabled else { return "监听已暂停" }
        guard hasAccessibility else { return "等待辅助功能授权" }
        guard supportsWindowIcons else { return "等待创建资料启动器" }
        if failedCount > 0 { return "\(failedCount) 个资料图标启动失败 · 请刷新资料" }
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
            DistributedNotificationCenter.default().removeObserver(self, name: WindowDock.focusNotification, object: nil)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            trackers.removeAll()
            snapshots.removeAll()
            failed.removeAll()
            updateFailedCount()
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
            let tracker = tracker(for: browser, application: app)
            if let windows = tracker.byProfileDirectory() {
                snapshots[browser] = windows
                needsRecovery = needsRecovery || !tracker.observesWindowChanges
                needsFollowUp = needsFollowUp || tracker.needsFollowUp
            } else {
                needsRecovery = true
            }
        }
        let displayed = Set(launchers.compactMap { id, launcher in
            snapshots[launcher.browser]?[launcher.profileDirectory]?.isEmpty == false ? id : nil
        })
        if !openingProfiles.isEmpty {
            let now = ProcessInfo.processInfo.systemUptime
            openingProfiles = openingProfiles.filter { !displayed.contains($0.key) && $0.value.expiresAt > now }
        }
        let waitingForLauncher = reconcile(displayed)
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

    private func tracker(for browser: EdgeBrowser, application app: NSRunningApplication) -> EdgeWindows {
        if let tracker = trackers[browser], tracker.application.processIdentifier == app.processIdentifier {
            return tracker
        }
        let tracker = EdgeWindows(browser: browser, application: app) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                self.scheduleRefresh()
            }
        }
        if isEnabled {
            snapshots.removeValue(forKey: browser)
            trackers[browser] = tracker
        }
        return tracker
    }

    @discardableResult
    private func reconcile(_ ids: Set<String>) -> Bool {
        desired = ids
        failed = failed.filter { ids.contains($0.key) }
        updateFailedCount()
        for (id, app) in running where app.isTerminated || !ids.contains(id) {
            if !app.isTerminated { app.terminate() }
            running.removeValue(forKey: id)
        }
        updateDisplayedCount()

        var waitingForLauncher = false
        for id in ids where running[id] == nil && !pending.contains(id) {
            if let retry = failed[id], !retry.canRetry(at: ProcessInfo.processInfo.systemUptime) {
                waitingForLauncher = waitingForLauncher || !retry.exhausted
                continue
            }
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
                        self.failed.removeValue(forKey: id)
                        self.updateFailedCount()
                        self.running[id] = app
                        self.updateDisplayedCount()
                    } else {
                        var retry = self.failed[id] ?? LauncherRetryState()
                        retry.recordFailure(at: ProcessInfo.processInfo.systemUptime)
                        self.failed[id] = retry
                        self.updateFailedCount()
                        if !retry.exhausted { self.scheduleRefresh() }
                    }
                }
            }
        }
        return waitingForLauncher
    }

    private func updateDisplayedCount() {
        if displayedCount != running.count { displayedCount = running.count }
    }

    private func updateFailedCount() {
        let count = failed.values.filter(\.exhausted).count
        if failedCount != count { failedCount = count }
    }

    @objc private func openProfileRequest(_ notification: Notification) {
        guard let id = notification.object as? String, let launcher = launchers[id],
              let token = notification.userInfo?["request"] as? String, UUID(uuidString: token) != nil,
              let pid = notification.userInfo?["pid"] as? NSNumber,
              let sender = NSRunningApplication(processIdentifier: pid.int32Value), !sender.isTerminated,
              sender.bundleIdentifier == id,
              sender.bundleURL?.resolvingSymlinksInPath().path ==
                  URL(fileURLWithPath: launcher.appPath).resolvingSymlinksInPath().path else { return }

        let result = openProfile(launcher, identifier: id)
        DistributedNotificationCenter.default().postNotificationName(
            WindowDock.openProfileReply, object: token, userInfo: ["result": result.rawValue], deliverImmediately: true
        )
    }

    private func openProfile(_ launcher: CreatedLauncher, identifier: String) -> WindowDock.OpenResult {
        let browser = launcher.browser
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier)
            .first(where: { !$0.isTerminated }) else { return .browserClosed }
        guard AXIsProcessTrusted() else { return .accessibilityRequired }

        let tracker = tracker(for: browser, application: app)
        let windows = tracker.byProfileDirectory()
        if let target = windows?[launcher.profileDirectory]?.first {
            openingProfiles.removeValue(forKey: identifier)
            return tracker.focus(target) ? .handled : .unavailable
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let opening = openingProfiles[identifier], opening.pid == app.processIdentifier, opening.expiresAt > now {
            return .handled
        }
        guard windows != nil, !tracker.needsFollowUp,
              let result = tracker.openFromProfileMenu(launcher.profileDirectory),
              result == .success || result == .cannotComplete else { return .unavailable }

        // 等 Edge 完成开窗。即使辅助功能动作返回超时，也可能已经交给了 Edge。
        openingProfiles[identifier] = ProfileOpening(pid: app.processIdentifier, expiresAt: now + 8)
        if isEnabled { scheduleRefresh() }
        return .handled
    }

    @objc private func focusRequest(_ notification: Notification) {
        guard let id = notification.object as? String, let launcher = launchers[id] else { return }
        guard isEnabled, AXIsProcessTrusted(), let tracker = trackers[launcher.browser] else {
            showFocusError("请确认窗口监听已开启，且 EdgeProfileDock 已获得辅助功能授权。")
            return
        }
        var windows = tracker.byProfileDirectory()
        if windows?[launcher.profileDirectory]?.first == nil {
            tracker.reloadProfiles(forceWindowNames: true)
            windows = tracker.byProfileDirectory()
        }
        guard let target = windows?[launcher.profileDirectory]?.first, tracker.focus(target) else {
            scheduleRefresh()
            showFocusError("暂时无法确认该资料的窗口。请刷新资料后重试。")
            return
        }
    }

    private func showFocusError(_ message: String) {
        guard !showingFocusError else { return }
        showingFocusError = true
        defer { showingFocusError = false }
        let alert = NSAlert()
        alert.messageText = "无法切换资料窗口"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.runModal()
    }
}
