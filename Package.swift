// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EdgeProfileDock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EdgeProfileDock",
            path: "EdgeProfileDock",
            exclude: ["Info.plist", "AppIcon.icns"]
        )
    ]
)
