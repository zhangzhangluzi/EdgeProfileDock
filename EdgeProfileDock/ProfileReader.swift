import Foundation

enum ProfileReaderError: LocalizedError {
    case localStateMissing
    case localStateUnreadable
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .localStateMissing:
            return "未找到 Edge 资料配置（Local State）。"
        case .localStateUnreadable:
            return "无法读取 Edge 资料配置。"
        case .invalidJSON:
            return "Edge 资料配置格式无效。"
        }
    }
}

enum ProfileReader {
    static func loadProfiles(for browser: EdgeBrowser) throws -> [EdgeProfile] {
        let localStateURL = browser.localStateURL
        guard FileManager.default.fileExists(atPath: localStateURL.path) else {
            throw ProfileReaderError.localStateMissing
        }

        let data: Data
        do {
            data = try Data(contentsOf: localStateURL)
        } catch {
            throw ProfileReaderError.localStateUnreadable
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let profile = json["profile"] as? [String: Any],
            let infoCache = profile["info_cache"] as? [String: Any]
        else {
            throw ProfileReaderError.invalidJSON
        }

        var profiles: [EdgeProfile] = []
        for (directory, value) in infoCache {
            guard let meta = value as? [String: Any] else { continue }
            let rawName = (meta["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let account = firstNonEmpty([
                meta["user_name"] as? String,
                meta["gaia_name"] as? String,
                meta["user_email"] as? String
            ]) ?? ""
            let displayName: String
            if rawName.isEmpty {
                displayName = directory == "Default" ? "Profile" : directory
            } else {
                displayName = rawName
            }

            let profileDir = browser.userDataRoot.appendingPathComponent(directory)
            let available = FileManager.default.fileExists(atPath: profileDir.path)

            profiles.append(
                EdgeProfile(
                    browser: browser,
                    directory: directory,
                    displayName: displayName,
                    account: account,
                    isAvailable: available,
                    avatarURL: localAvatar(in: profileDir, fileName: meta["gaia_picture_file_name"] as? String)
                )
            )
        }

        return profiles.sorted { lhs, rhs in
            profileSortKey(lhs.directory) < profileSortKey(rhs.directory)
        }
    }

    private static func localAvatar(in directory: URL, fileName: String?) -> URL? {
        let root = directory.resolvingSymlinksInPath()
        for name in [fileName, "Edge Profile Picture.png"].compactMap({ $0 }) where !name.isEmpty {
            guard (name as NSString).lastPathComponent == name else { continue }
            let candidate = root.appendingPathComponent(name).resolvingSymlinksInPath()
            guard candidate.deletingLastPathComponent().path == root.path,
                  (try? candidate.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            return candidate
        }
        return nil
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func profileSortKey(_ directory: String) -> (Int, Int, String) {
        if directory == "Default" { return (0, 0, directory) }
        if directory.hasPrefix("Profile ") {
            let n = Int(directory.dropFirst("Profile ".count)) ?? Int.max
            return (1, n, directory)
        }
        return (2, Int.max, directory)
    }
}
