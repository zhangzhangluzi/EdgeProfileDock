import AppKit
import ApplicationServices

final class EdgeWindows {
    private struct ProfileStateStamp: Equatable {
        let modified: Date
        let size: UInt64
        let fileNumber: UInt64
    }

    private struct TrackedWindow {
        let element: AXUIElement
        var profileName: String?
        let observesDestruction: Bool
    }

    let application: NSRunningApplication
    private(set) var needsFollowUp = false
    private let browser: EdgeBrowser
    private let element: AXUIElement
    private let onChange: () -> Void
    private var observer: AXObserver?
    private var observesCreation = false
    private var profiles: [EdgeProfile] = []
    private var windows: [TrackedWindow] = []
    private var profileStateStamp: ProfileStateStamp?

    var observesWindowChanges: Bool {
        observesCreation && windows.allSatisfy(\.observesDestruction)
    }

    init(browser: EdgeBrowser, application: NSRunningApplication, onChange: @escaping () -> Void) {
        self.browser = browser
        self.application = application
        self.onChange = onChange
        element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        reloadProfiles()
    }

    private func startObserving() {
        guard observer == nil else { return }

        var observer: AXObserver?
        AXObserverCreate(application.processIdentifier, { _, _, _, context in
            guard let context else { return }
            Unmanaged<EdgeWindows>.fromOpaque(context).takeUnretainedValue().onChange()
        }, &observer)
        if let observer {
            self.observer = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    func reloadProfiles(forceWindowNames: Bool = false) {
        let before = currentProfileStateStamp()
        guard let loaded = try? ProfileReader.loadProfiles(for: browser) else { return }
        let after = currentProfileStateStamp()
        if forceWindowNames || loaded.filter(\.isAvailable) != profiles { updateProfiles(loaded) }
        profileStateStamp = before == after ? after : nil
    }

    private func currentProfileStateStamp() -> ProfileStateStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: browser.localStateURL.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return ProfileStateStamp(modified: modified, size: size.uint64Value, fileNumber: fileNumber.uint64Value)
    }

    func updateProfiles(_ profiles: [EdgeProfile]) {
        self.profiles = profiles.filter(\.isAvailable)
        for index in windows.indices {
            windows[index].profileName = nil
        }
    }

    func byProfileDirectory() -> [String: [AXUIElement]]? {
        if let current = currentProfileStateStamp(), current != profileStateStamp {
            reloadProfiles()
        }
        startObserving()
        if !observesCreation {
            observesCreation = observe(kAXWindowCreatedNotification, on: element)
        }
        guard let live: [AXUIElement] = attribute(element, kAXWindowsAttribute) else { return nil }
        needsFollowUp = false
        windows = live.compactMap { window -> TrackedWindow? in
            guard let subrole: String = attribute(window, kAXSubroleAttribute) else {
                needsFollowUp = true
                return nil
            }
            guard subrole == kAXStandardWindowSubrole else { return nil }
            let previous = windows.first { CFEqual($0.element, window) }
            return TrackedWindow(
                element: window,
                profileName: previous?.profileName ?? profileName(in: window),
                observesDestruction: previous?.observesDestruction == true ||
                    observe(kAXUIElementDestroyedNotification, on: window)
            )
        }

        let profilesByName = Dictionary(grouping: profiles, by: \.displayName)
        var directories = profilesByName.compactMapValues { $0.count == 1 ? $0.first?.directory : nil }
        if windows.contains(where: { $0.profileName.map { profilesByName[$0] == nil } ?? false }),
           let alias = Self.profileMenuAlias(profileMenuItems().map(\.name), profiles: profiles) {
            directories[alias.name] = alias.directory
        }
        var result: [String: [AXUIElement]] = [:]
        for index in windows.indices {
            let window = windows[index]
            if let directory = window.profileName.flatMap({ directories[$0] }) {
                result[directory, default: []].append(window.element)
            } else {
                needsFollowUp = true
                windows[index].profileName = nil
            }
        }
        return result
    }

    @discardableResult
    func focus(_ window: AXUIElement) -> Bool {
        if (attribute(window, kAXMinimizedAttribute) as Bool?) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return false }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        if AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) != .success {
            return application.isActive || application.activate()
        }
        return true
    }

    func openFromProfileMenu(_ directory: String) -> AXError? {
        guard let profile = profiles.first(where: { $0.directory == directory }) else { return nil }
        let items = profileMenuItems()
        let names = items.map(\.name)
        let expected = Set(profiles.map(\.displayName))
        let actual = Set(names)
        guard expected.count == profiles.count, names.count == profiles.count, actual.count == names.count else { return nil }
        let alias = Self.profileMenuAlias(names, profiles: profiles)
        guard actual == expected || alias != nil else { return nil }
        let title = alias.flatMap { $0.directory == directory ? $0.name : nil } ?? profile.displayName
        guard let item = items.first(where: { $0.name == title }),
              (attribute(item.element, kAXEnabledAttribute) as Bool?) == true else { return nil }
        return AXUIElementPerformAction(item.element, kAXPressAction as CFString)
    }

    private func observe(_ notification: String, on element: AXUIElement) -> Bool {
        guard let observer else { return false }
        let result = AXObserverAddNotification(
            observer, element, notification as CFString, Unmanaged.passUnretained(self).toOpaque()
        )
        return result == .success || result == .notificationAlreadyRegistered
    }

    private func attribute<T>(_ element: AXUIElement, _ key: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    private func profileName(in window: AXUIElement) -> String? {
        let names = Set(toolbars(in: window).flatMap { toolbar in
            children(of: toolbar).compactMap { button -> String? in
                guard (attribute(button, kAXRoleAttribute) as String?) == kAXButtonRole,
                      let label: String = attribute(button, kAXTitleAttribute) else { return nil }
                for suffix in [" 个人资料", " 個人資料", " 設定檔", ", profile", " profile"] {
                    if let range = label.range(of: suffix, options: [.anchored, .backwards, .caseInsensitive]) {
                        let name = label[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                        return name.isEmpty ? nil : name
                    }
                }
                return nil
            }
        })
        return names.count == 1 ? names.first : nil
    }

    private func toolbars(in element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth <= 10 else { return [] }
        let role: String? = attribute(element, kAXRoleAttribute)
        if role == kAXToolbarRole { return [element] }
        guard depth == 0 || role == kAXGroupRole else { return [] }
        return children(of: element).flatMap { toolbars(in: $0, depth: depth + 1) }
    }

    private func profileMenuItems() -> [(name: String, element: AXUIElement)] {
        guard let menuBar: AXUIElement = attribute(element, kAXMenuBarAttribute),
              let item = children(of: menuBar).first(where: {
                  ["个人资料", "個人資料", "設定檔", "Profiles"].contains(attribute($0, kAXTitleAttribute) ?? "")
              }),
              let menu = children(of: item).first else { return [] }

        var profiles: [(name: String, element: AXUIElement)] = []
        // 第一个分隔符以上是资料，以下是管理命令。
        for item in children(of: menu) {
            guard (attribute(item, kAXRoleAttribute) as String?) == kAXMenuItemRole,
                  let name: String = attribute(item, kAXTitleAttribute), !name.isEmpty else { break }
            profiles.append((name, item))
        }
        return profiles
    }

    static func profileMenuAlias(_ names: [String], profiles: [EdgeProfile]) -> (name: String, directory: String)? {
        guard Set(names).count == profiles.count, names.count == profiles.count else { return nil }
        let profileNames = Set(profiles.map(\.displayName))
        let aliases = Set(names).subtracting(profileNames)
        let missing = profiles.filter { !names.contains($0.displayName) }
        guard aliases.count == 1, let name = aliases.first, missing.count == 1, let profile = missing.first else { return nil }
        return (name, profile.directory)
    }
}
