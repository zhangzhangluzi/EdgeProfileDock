import AppKit
import Combine

@MainActor
final class ManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: AppModel
    private var observation: AnyCancellable?
    private let browserPicker = NSSegmentedControl()
    private let monitorSwitch = NSSwitch()
    private let monitorStatus = NSTextField(labelWithString: "")
    private let permissionStatus = NSTextField(labelWithString: "")
    private let profileTable = NSTableView()
    private let launcherTable = NSTableView()
    private let chosenCount = NSTextField(labelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let profileEmpty = NSTextField(labelWithString: "暂无可显示的资料。")
    private let launcherEmpty = NSTextField(labelWithString: "勾选资料后可创建快捷方式。")
    private var profileScroll: NSScrollView!
    private var launcherScroll: NSScrollView!
    private var launcherBox: NSBox!
    private var profileActions: NSStackView!
    private var requestButton: NSButton!
    private var settingsRow: NSStackView!
    private var createButton: NSButton!
    private var deleteButton: NSButton!
    private var folderButton: NSButton!
    private var launcherMenu: NSPopUpButton!
    private var browsers: [EdgeBrowser] = []
    private var profiles: [EdgeProfile] = []
    private var launchers: [CreatedLauncher] = []
    private var selectedProfiles: Set<String> = []
    private var syncingSelection = false

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func loadView() {
        let root = NSView()
        let sections = stack(.vertical, spacing: 14, [makeHeader(), makeMonitor(), makeProfiles(), makeLaunchers(), feedback])
        pin(sections, in: root, inset: 20)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        syncView()
        observation = Publishers.Merge(model.objectWillChange, model.windowMonitor.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.syncView() }
    }

    private func makeHeader() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 46).isActive = true
        icon.heightAnchor.constraint(equalTo: icon.widthAnchor).isActive = true
        icon.setAccessibilityElement(false)
        let title = NSTextField(labelWithString: "EdgeProfileDock")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let description = detail("关闭窗口后，可从菜单栏重新打开。")
        var actions: [(String, Selector)] = []
        if !UninstallService.isRunningFromApplications() {
            actions.append(("移到应用程序…", #selector(moveToApplications)))
        }
        actions.append(("卸载 EdgeProfileDock…", #selector(showUninstall)))
        return stack(.horizontal, spacing: 12,
                     [icon, stack(.vertical, spacing: 3, [title, description], fillWidth: false),
                      spacer(), popup("更多", actions: actions)])
    }

    private func makeMonitor() -> NSView {
        monitorStatus.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        monitorSwitch.target = self
        monitorSwitch.action = #selector(toggleMonitoring)
        monitorSwitch.setAccessibilityLabel("监听资料窗口")
        requestButton = button("申请授权…", #selector(requestAccessibility))
        settingsRow = stack(.horizontal, spacing: 8, [button("打开辅助功能设置…", #selector(openAccessibilitySettings)), spacer()])
        let controls = stack(.horizontal, spacing: 8, [
            monitorStatus, spacer(), NSTextField(labelWithString: "监听资料窗口"), monitorSwitch
        ])
        let permissions = stack(.horizontal, spacing: 8, [
            permissionStatus, spacer(), button("重新检查", #selector(checkAccessibility)), requestButton
        ])
        return group("程序坞", [controls, permissions, settingsRow])
    }

    private func makeProfiles() -> NSView {
        browserPicker.trackingMode = .selectOne
        browserPicker.target = self
        browserPicker.action = #selector(selectBrowser)
        browserPicker.setAccessibilityLabel("浏览器")
        profileScroll = makeTable(profileTable, identifier: "profiles", height: 164, rowHeight: 44)
        profileTable.selectionHighlightStyle = .none
        profileTable.setAccessibilityLabel("浏览器资料")
        createButton = button("创建或更新所选图标", #selector(createLaunchers))
        createButton.keyEquivalent = "\r"
        chosenCount.textColor = .secondaryLabelColor
        profileEmpty.textColor = .secondaryLabelColor
        profileActions = stack(.horizontal, spacing: 8, [chosenCount, spacer(), createButton])
        return group("浏览器资料", [
            stack(.horizontal, spacing: 8, [browserPicker, spacer(), button("刷新资料", #selector(refresh))]),
            profileScroll, profileEmpty, profileActions
        ])
    }

    private func makeLaunchers() -> NSView {
        launcherScroll = makeTable(launcherTable, identifier: "launchers", height: 100, rowHeight: 40)
        launcherTable.allowsMultipleSelection = true
        launcherTable.setAccessibilityLabel("已创建启动器")
        let preferredHeight = launcherScroll.heightAnchor.constraint(equalToConstant: 122)
        preferredHeight.priority = .defaultHigh
        preferredHeight.isActive = true
        deleteButton = button("删除所选", #selector(deleteSelected))
        folderButton = button("打开文件夹", #selector(openFolder))
        launcherEmpty.textColor = .secondaryLabelColor
        launcherMenu = popup("管理", actions: [("清除全部启动器…", #selector(showClear))])
        launcherBox = group("已创建启动器", [
            launcherScroll, launcherEmpty,
            stack(.horizontal, spacing: 8,
                  [deleteButton, launcherMenu, spacer(), folderButton])
        ])
        return launcherBox
    }

    private func syncView() {
        let monitor = model.windowMonitor
        monitorStatus.stringValue = monitor.activityDescription
        monitorSwitch.state = monitor.isEnabled ? .on : .off
        permissionStatus.stringValue = monitor.hasAccessibility ? "辅助功能已授权" : "辅助功能待授权"
        requestButton.isHidden = monitor.hasAccessibility
        settingsRow.isHidden = monitor.hasAccessibility

        if browsers != model.availableBrowsers {
            browsers = model.availableBrowsers
            browserPicker.segmentCount = browsers.count
            for (index, browser) in browsers.enumerated() {
                browserPicker.setLabel(browser.displayName, forSegment: index)
            }
        }
        browserPicker.isEnabled = !browsers.isEmpty
        browserPicker.selectedSegment = browsers.firstIndex(of: model.selectedBrowser) ?? -1

        let launcherListChanged = launchers != model.createdLaunchers
        if profiles != model.profiles || launcherListChanged {
            profiles = model.profiles
            launchers = model.createdLaunchers
            profileTable.reloadData()
        }
        if selectedProfiles != model.selectedProfileIDs {
            selectedProfiles = model.selectedProfileIDs
            let visible = profileTable.rows(in: profileTable.visibleRect)
            if visible.location != NSNotFound {
                for row in visible.location..<NSMaxRange(visible) where profiles.indices.contains(row) {
                    let cell = profileTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSStackView
                    (cell?.arrangedSubviews.first as? NSButton)?.state = selectedProfiles.contains(profiles[row].id) ? .on : .off
                }
            }
        }
        profileScroll.isHidden = profiles.isEmpty
        profileEmpty.isHidden = !profiles.isEmpty
        profileActions.isHidden = profiles.isEmpty
        chosenCount.stringValue = "已选 \(selectedProfiles.count) 项"
        createButton.isEnabled = !selectedProfiles.isEmpty

        syncingSelection = true
        if launcherListChanged { launcherTable.reloadData() }
        let selection = IndexSet(launchers.indices.filter { model.selectedLauncherIDs.contains(launchers[$0].id) })
        if launcherTable.selectedRowIndexes != selection {
            launcherTable.selectRowIndexes(selection, byExtendingSelection: false)
        }
        syncingSelection = false
        launcherBox.title = "已创建启动器 · \(launchers.count)"
        launcherScroll.isHidden = launchers.isEmpty
        launcherEmpty.isHidden = !launchers.isEmpty
        launcherMenu.isHidden = launchers.isEmpty
        deleteButton.isHidden = launchers.isEmpty
        deleteButton.isEnabled = !selection.isEmpty
        folderButton.isEnabled = !launchers.isEmpty

        feedback.stringValue = model.errorMessage ?? model.statusMessage ?? ""
        feedback.textColor = model.errorMessage == nil ? .secondaryLabelColor : .systemRed
        feedback.isHidden = feedback.stringValue.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === profileTable ? profiles.count : launchers.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === profileTable {
            let profile = profiles[row]
            let selected = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleProfile(_:)))
            selected.tag = row
            selected.setAccessibilityLabel("选择 \(profile.displayName)")
            selected.isEnabled = profile.isAvailable
            selected.state = model.selectedProfileIDs.contains(profile.id) ? .on : .off
            let title = NSTextField(labelWithString: profile.displayName)
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            title.toolTip = profile.displayName
            let caption = detail(profile.account.isEmpty ? profile.directory : "\(profile.account) · \(profile.directory)")
            caption.toolTip = caption.stringValue
            let icon = avatar(for: profile)
            let status = detail(profile.isAvailable ? (launchers.contains {
                $0.browser == profile.browser && $0.profileDirectory == profile.directory
            } ? "已创建" : "") : "目录缺失")
            status.setContentHuggingPriority(.required, for: .horizontal)
            status.setContentCompressionResistancePriority(.required, for: .horizontal)
            return stack(.horizontal, spacing: 8, [selected, icon,
                                                stack(.vertical, spacing: 2, [title, caption], fillWidth: false),
                                                spacer(), status])
        }
        let launcher = launchers[row]
        let title = NSTextField(labelWithString: launcher.displayName)
        title.toolTip = launcher.displayName
        return stack(.vertical, spacing: 2, [title, detail("\(launcher.browser.displayName) · \(launcher.profileDirectory)")])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, notification.object as? NSTableView === launcherTable else { return }
        model.selectedLauncherIDs = Set(launcherTable.selectedRowIndexes.compactMap {
            launchers.indices.contains($0) ? launchers[$0].id : nil
        })
    }

    private func avatar(for profile: EdgeProfile) -> NSView {
        let avatar = NSImageView()
        avatar.widthAnchor.constraint(equalToConstant: 32).isActive = true
        avatar.heightAnchor.constraint(equalTo: avatar.widthAnchor).isActive = true
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 16
        avatar.layer?.masksToBounds = true
        avatar.layer?.backgroundColor = ProfileArtwork.color(for: profile).cgColor
        avatar.image = ProfileArtwork.portrait(for: profile, pixels: 68)
        avatar.setAccessibilityElement(false)
        if avatar.image == nil {
            let initial = NSTextField(labelWithString: ProfileArtwork.initial(for: profile))
            initial.font = .systemFont(ofSize: 14, weight: .semibold)
            initial.textColor = .white
            initial.setAccessibilityElement(false)
            initial.translatesAutoresizingMaskIntoConstraints = false
            avatar.addSubview(initial)
            NSLayoutConstraint.activate([initial.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
                                         initial.centerYAnchor.constraint(equalTo: avatar.centerYAnchor)])
        }
        return avatar
    }

    private func makeTable(_ table: NSTableView, identifier: String, height: CGFloat, rowHeight: CGFloat) -> NSScrollView {
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier)))
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 10, height: 0)
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        return scroll
    }

    private func stack(_ orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat,
                       _ views: [NSView], fillWidth: Bool = true) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.spacing = spacing
        stack.alignment = orientation == .vertical ? .leading : .centerY
        if orientation == .vertical && fillWidth {
            for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        return stack
    }

    private func group(_ title: String, _ rows: [NSView]) -> NSBox {
        let box = NSBox()
        box.title = title
        box.contentViewMargins = NSSize(width: 0, height: 0)
        pin(stack(.vertical, spacing: 8, rows), in: box.contentView!, inset: 10)
        return box
    }

    private func pin(_ child: NSView, in parent: NSView, inset: CGFloat) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func detail(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func popup(_ title: String, actions: [(String, Selector)]) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.addItem(withTitle: title)
        for (label, action) in actions {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self
            button.menu?.addItem(item)
        }
        return button
    }

    private func confirm(_ title: String, message: String, buttons: [String], completion: @escaping (Int) -> Void) {
        guard let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        for title in buttons { alert.addButton(withTitle: title) }
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { response in completion(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
    }

    @objc private func selectBrowser() {
        let index = browserPicker.selectedSegment
        guard browsers.indices.contains(index), model.selectedBrowser != browsers[index] else { return }
        model.selectedBrowser = browsers[index]
        model.refreshProfiles()
    }

    @objc private func toggleProfile(_ sender: NSButton) {
        guard profiles.indices.contains(sender.tag) else { return }
        model.toggleProfile(profiles[sender.tag])
    }

    @objc private func refresh() { model.refresh() }
    @objc private func toggleMonitoring() { model.windowMonitor.isEnabled = monitorSwitch.state == .on }
    @objc private func checkAccessibility() { model.windowMonitor.checkAccessibility() }
    @objc private func requestAccessibility() { model.windowMonitor.requestAccessibility() }
    @objc private func openAccessibilitySettings() { model.windowMonitor.openAccessibilitySettings() }
    @objc private func deleteSelected() { model.deleteSelectedLaunchers() }
    @objc private func openFolder() { NSWorkspace.shared.open(LauncherBuilder.applicationsDirectory) }
    @objc private func moveToApplications() { model.moveToApplications() }

    @objc private func createLaunchers() {
        model.requestCreateSelected()
        if model.showOverwriteConfirm {
            confirm("发现同名启动器", message: "替换会把同名快捷方式改成当前所选资料。",
                    buttons: ["替换", "取消"]) { [model] response in
                if response == 0 { model.confirmOverwriteCreate() } else { model.cancelOverwriteCreate() }
            }
        }
    }

    @objc private func showClear() {
        confirm("清除全部启动器？", message: "将删除本工具创建的快捷方式。Edge 资料会保留。",
                buttons: ["清除", "取消"]) { [model] response in
            if response == 0 { model.clearAllLaunchers() }
        }
    }

    @objc private func showUninstall() {
        confirm("卸载 EdgeProfileDock", message: "Edge 的资料和浏览数据会保留。",
                buttons: ["卸载工具并保留启动器", "卸载工具和启动器", "取消"]) { [model] response in
            switch response {
            case 0: model.uninstall(mode: .keepLaunchers)
            case 1: model.uninstall(mode: .removeEverything)
            default: break
            }
        }
    }
}
