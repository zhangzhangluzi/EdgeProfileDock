import AppKit
import OSLog

@main
@MainActor
final class EdgeProfileDockApp: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model = AppModel()
    private let logger = Logger(subsystem: WindowDock.managerBundleIdentifier, category: "管理窗口")
    private var statusItem: NSStatusItem?
    private var managerWindow: NSWindow?

    static func main() {
        let application = NSApplication.shared
        let delegate = EdgeProfileDockApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.bootstrap()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "EdgeProfileDock")
            button.toolTip = "EdgeProfileDock"
            button.setAccessibilityLabel("EdgeProfileDock")
        }
        let menu = NSMenu(title: "EdgeProfileDock")
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        showManager()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.windowMonitor.checkAccessibility()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showManager()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === managerWindow else { return }
        managerWindow = nil
        DispatchQueue.main.async {
            window.contentViewController = nil
            window.contentView = nil
        }
    }

    private func showManager() {
        let window: NSWindow
        if let managerWindow {
            window = managerWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 670),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.identifier = NSUserInterfaceItemIdentifier("manager")
            window.title = "EdgeProfileDock"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = ManagerViewController(model: model)
            window.contentMinSize = NSSize(width: 555, height: 600)
            window.setContentSize(NSSize(width: 620, height: 670))
            window.center()
            managerWindow = window
        }

        model.windowMonitor.checkAccessibility()
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let monitor = model.windowMonitor
        monitor.checkAccessibility()
        menu.removeAllItems()
        let status = NSMenuItem(title: monitor.activityDescription, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        add("打开 EdgeProfileDock", action: #selector(openManager(_:)), to: menu)
        add(monitor.isEnabled ? "暂停窗口监听" : "启用窗口监听", action: #selector(toggleMonitoring), to: menu)
        if !monitor.hasAccessibility {
            add("打开辅助功能设置…", action: #selector(openAccessibilitySettings), to: menu)
        }
        menu.addItem(.separator())
        add("退出 EdgeProfileDock", action: #selector(quit), to: menu)
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
    }

    @objc private func openManager(_ sender: NSMenuItem) {
        // 菜单收起后再激活窗口，避免菜单恢复原前台应用。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.showManager()
            self.logger.info("已从菜单栏打开管理窗口")
        }
    }

    @objc private func toggleMonitoring() { model.windowMonitor.isEnabled.toggle() }
    @objc private func openAccessibilitySettings() { model.windowMonitor.openAccessibilitySettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
