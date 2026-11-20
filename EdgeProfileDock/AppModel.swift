import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let windowMonitor = ProfileWindowMonitor()
    @Published var selectedBrowser: EdgeBrowser = .edge
    @Published var availableBrowsers: [EdgeBrowser] = []
    @Published var profiles: [EdgeProfile] = []
    @Published var selectedProfileIDs: Set<String> = []
    @Published var createdLaunchers: [CreatedLauncher] = []
    @Published var selectedLauncherIDs: Set<String> = []
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var showOverwriteConfirm = false
    @Published var pendingCreateProfiles: [EdgeProfile] = []
    private var didBootstrap = false

    func bootstrap() {
        guard !didBootstrap else {
            windowMonitor.checkAccessibility()
            return
        }
        didBootstrap = true
        refresh()
    }

    func refresh() {
        refreshBrowsers()
        refreshProfiles()
        refreshCreated()
    }

    func refreshBrowsers() {
        availableBrowsers = BrowserDetector.availableBrowsers()
        if !availableBrowsers.contains(selectedBrowser), let first = availableBrowsers.first {
            selectedBrowser = first
        }
    }

    func refreshProfiles() {
        errorMessage = nil
        statusMessage = nil
        guard BrowserDetector.isInstalled(selectedBrowser) else {
            profiles = []
            selectedProfileIDs.removeAll()
            errorMessage = "未安装 \(selectedBrowser.displayName)。"
            return
        }
        do {
            profiles = try ProfileReader.loadProfiles(for: selectedBrowser)
            selectedProfileIDs.formIntersection(profiles.filter(\.isAvailable).map(\.id))
            windowMonitor.updateProfiles(profiles, for: selectedBrowser)
        } catch {
            profiles = []
            selectedProfileIDs.removeAll()
            errorMessage = error.localizedDescription
        }
    }

    func refreshCreated() {
        createdLaunchers = ManifestStore.load()
        selectedLauncherIDs = selectedLauncherIDs.intersection(Set(createdLaunchers.map(\.id)))
        windowMonitor.configure(createdLaunchers)
    }

    func toggleProfile(_ profile: EdgeProfile) {
        guard profile.isAvailable else { return }
        if selectedProfileIDs.contains(profile.id) {
            selectedProfileIDs.remove(profile.id)
        } else {
            selectedProfileIDs.insert(profile.id)
        }
    }

    func requestCreateSelected() {
        let chosen = profiles.filter { selectedProfileIDs.contains($0.id) && $0.isAvailable }
        guard !chosen.isEmpty else {
            errorMessage = "请先勾选要创建启动器的资料。"
            return
        }
        let paths = chosen.map { LauncherBuilder.launcherURL(for: $0).path.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(paths).count == paths.count else {
            errorMessage = "所选资料会生成同名启动器，请分开选择或先在 Edge 中改名。"
            return
        }
        let conflicts = chosen.filter { LauncherBuilder.exists(for: $0) && !LauncherBuilder.ownsLauncher(for: $0) }
        if conflicts.isEmpty {
            create(profiles: chosen, overwrite: false)
        } else {
            pendingCreateProfiles = chosen
            showOverwriteConfirm = true
        }
    }

    func confirmOverwriteCreate() {
        create(profiles: pendingCreateProfiles, overwrite: true)
        pendingCreateProfiles = []
        showOverwriteConfirm = false
    }

    func cancelOverwriteCreate() {
        pendingCreateProfiles = []
        showOverwriteConfirm = false
    }

    private func create(profiles: [EdgeProfile], overwrite: Bool) {
        errorMessage = nil
        statusMessage = nil
        var saved: [CreatedLauncher] = []
        do {
            for profile in profiles {
                let replace = overwrite || LauncherBuilder.ownsLauncher(for: profile)
                saved.append(try LauncherBuilder.create(for: profile, overwrite: replace))
                selectedProfileIDs.remove(profile.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshCreated()
        windowMonitor.refreshIcons(for: saved)
        if !saved.isEmpty { statusMessage = "已保存 \(saved.count) 个资料启动器。" }
    }

    func deleteSelectedLaunchers() {
        let paths = createdLaunchers.filter { selectedLauncherIDs.contains($0.id) }.map(\.appPath)
        guard !paths.isEmpty else {
            errorMessage = "请先勾选要删除的启动器。"
            return
        }
        do {
            try LauncherBuilder.delete(appPaths: paths)
            selectedLauncherIDs.removeAll()
            refreshCreated()
            statusMessage = "已删除 \(paths.count) 个启动器。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAllLaunchers() {
        do {
            try LauncherBuilder.deleteAllOwnedLaunchers()
            selectedLauncherIDs.removeAll()
            refreshCreated()
            statusMessage = "已清除全部启动器。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveToApplications() {
        do {
            _ = try UninstallService.moveToApplications()
        } catch {
            errorMessage = "移动失败：\(error.localizedDescription)。请手动拖到「应用程序」文件夹。"
        }
    }

    func uninstall(mode: UninstallMode) {
        do {
            try UninstallService.performUninstall(mode: mode)
        } catch {
            errorMessage = "卸载失败：\(error.localizedDescription)"
        }
    }
}
