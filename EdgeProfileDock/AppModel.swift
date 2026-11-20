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
        create(profiles: chosen)
    }

    private func create(profiles: [EdgeProfile]) {
        errorMessage = nil
        statusMessage = nil
        var saved: [CreatedLauncher] = []
        do {
            for profile in profiles {
                saved.append(try LauncherBuilder.create(for: profile))
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
            if error is InstallError {
                errorMessage = error.localizedDescription
            } else {
                errorMessage = "移动失败：\(error.localizedDescription)。请手动拖到「应用程序」文件夹。"
            }
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
