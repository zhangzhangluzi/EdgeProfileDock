import Foundation
import Carbon
import XCTest
@testable import EdgeProfileDock

final class EdgeProfileDockTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeProfileDockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func profile(_ name: String, browser: EdgeBrowser = .edge, directory: String = "Default") -> EdgeProfile {
        EdgeProfile(browser: browser, directory: directory, displayName: name, account: "", isAvailable: true, avatarURL: nil)
    }

    private func launcher(at url: URL, for profile: EdgeProfile) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "EPDOwner": "EdgeProfileDock",
            "EPDBrowser": profile.browser.rawValue,
            "EPDProfileDirectory": profile.directory
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    func testSameNameUsesDistinctPathsAndPreservesExistingLauncher() throws {
        let first = profile("同名")
        let beta = profile("同名", browser: .edgeBeta)
        let existing = LauncherBuilder.launcherURL(for: first, in: directory)
        try launcher(at: existing, for: first)

        let other = LauncherBuilder.launcherURL(for: beta, in: directory)
        XCTAssertNotEqual(existing, other)
        XCTAssertTrue(other.lastPathComponent.contains("Microsoft Edge Beta"))
        XCTAssertEqual(LauncherBuilder.launcherURL(for: first, in: directory).path, existing.path)

        try launcher(at: other, for: beta)
        XCTAssertEqual(LauncherBuilder.launcherURL(for: beta, in: directory).path, other.path)
        XCTAssertNotNil(LauncherBuilder.ownedLauncherInfo(at: existing, in: directory))
    }

    func testRenamedProfileKeepsItsOriginalPath() throws {
        let original = profile("原名称", directory: "Profile 1")
        let existing = LauncherBuilder.launcherURL(for: original, in: directory)
        try launcher(at: existing, for: original)

        let renamed = profile("新名称", directory: "Profile 1")
        XCTAssertEqual(LauncherBuilder.launcherURL(for: renamed, in: directory).path, existing.path)
    }

    func testForeignAndAlreadyOccupiedPathsAreNeverSelected() throws {
        let person = profile("资料", directory: "Profile 1")
        let preferred = LauncherBuilder.launcherURL(for: person, in: directory)
        try Data("foreign".utf8).write(to: preferred)
        let alternative = LauncherBuilder.launcherURL(for: person, in: directory)
        XCTAssertNotEqual(alternative, preferred)

        try Data("foreign".utf8).write(to: alternative)
        let numbered = LauncherBuilder.launcherURL(for: person, in: directory)
        XCTAssertNotEqual(numbered, preferred)
        XCTAssertNotEqual(numbered, alternative)
        XCTAssertEqual(try Data(contentsOf: preferred), Data("foreign".utf8))
        XCTAssertEqual(try Data(contentsOf: alternative), Data("foreign".utf8))
    }

    func testTransientLauncherFailuresHaveBoundedRetries() {
        var state = LauncherRetryState()
        XCTAssertTrue(state.canRetry(at: 0))
        state.recordFailure(at: 10)
        XCTAssertFalse(state.canRetry(at: 10.9))
        XCTAssertTrue(state.canRetry(at: 11))
        state.recordFailure(at: 11)
        XCTAssertFalse(state.canRetry(at: 14.9))
        XCTAssertTrue(state.canRetry(at: 15))
        state.recordFailure(at: 15)
        XCTAssertTrue(state.exhausted)
        XCTAssertFalse(state.canRetry(at: 100))
    }

    func testOnlyUnambiguousProfileAliasIsAccepted() {
        let profiles = [profile("甲"), profile("乙", directory: "Profile 1")]
        let alias = EdgeWindows.profileMenuAlias(["甲", "别名"], profiles: profiles)
        XCTAssertEqual(alias?.name, "别名")
        XCTAssertEqual(alias?.directory, "Profile 1")
        XCTAssertNil(EdgeWindows.profileMenuAlias(["别名一", "别名二"], profiles: profiles))
        XCTAssertNil(EdgeWindows.profileMenuAlias(["甲", "甲"], profiles: profiles))
    }

    func testLoginLaunchStaysInBackground() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        XCTAssertFalse(LoginLaunch.startsInBackground(event: event, loginEnabled: true))
        event.setParam(NSAppleEventDescriptor(enumCode: AEKeyword(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        XCTAssertTrue(LoginLaunch.startsInBackground(event: event, loginEnabled: true))
        XCTAssertTrue(LoginLaunch.startsInBackground(event: nil, loginEnabled: true))
        XCTAssertFalse(LoginLaunch.startsInBackground(event: nil, loginEnabled: false))
    }

    private func signedFixture(version: String, name: String) throws -> URL {
        let app = directory.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Fixture"))
        let info: [String: Any] = [
            "CFBundleIdentifier": WindowDock.managerBundleIdentifier,
            "CFBundleExecutable": "Fixture",
            "CFBundleName": "Fixture",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": version
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", app.path]
        try signer.run()
        signer.waitUntilExit()
        XCTAssertEqual(signer.terminationStatus, 0)
        return app
    }

    func testInstallStagesSameSignatureAndRejectsDifferentSignature() throws {
        let source = try signedFixture(version: "1", name: "Source.app")
        let destination = directory.appendingPathComponent("Installed.app", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: destination)
        try UninstallService.installCopy(from: source, to: destination)
        XCTAssertEqual(Bundle(url: destination)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "1")

        let different = try signedFixture(version: "2", name: "Different.app")
        XCTAssertThrowsError(try UninstallService.installCopy(from: different, to: destination))
        let info = try Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist"))
        let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any])
        XCTAssertEqual(decoded["CFBundleVersion"] as? String, "1")
    }

    func testRealSignedUpgradeWhenFixturesProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let oldPath = environment["EPD_TEST_INSTALLED"],
              let newPath = environment["EPD_TEST_CANDIDATE"] else {
            throw XCTSkip("未提供签名升级测试用的应用路径")
        }
        let old = URL(fileURLWithPath: oldPath, isDirectory: true)
        let candidate = URL(fileURLWithPath: newPath, isDirectory: true)
        let destination = directory.appendingPathComponent("Installed.app", isDirectory: true)
        try FileManager.default.copyItem(at: old, to: destination)
        try UninstallService.installCopy(from: candidate, to: destination)
        let version = Bundle(url: candidate)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertNotNil(version)
        XCTAssertEqual(Bundle(url: destination)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, version)
        let executable = "Contents/MacOS/EdgeProfileDock"
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(executable)),
                       try Data(contentsOf: candidate.appendingPathComponent(executable)))
    }

    func testRelaunchWaitsForPreviousProcess() throws {
        let opener = directory.appendingPathComponent("test opener")
        try "#!/bin/sh\nprintf '%s' \"$1\" > \"$2.received\"\n".write(
            to: opener, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        let previous = Process()
        previous.executableURL = URL(fileURLWithPath: "/bin/sleep")
        previous.arguments = ["1"]
        try previous.run()
        let destination = directory.appendingPathComponent("Installed App.app")
        let marker = URL(fileURLWithPath: destination.path + ".received")
        let helper = try UninstallService.relaunchAfterExit(destination, waitingFor: previous.processIdentifier, using: opener)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        previous.waitUntilExit()
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "-a")
    }
}
