// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Reopen",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Reopen", path: "Sources/Reopen")
    ]
)
