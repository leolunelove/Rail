// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rail",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Rail", swiftSettings: [.swiftLanguageMode(.v5)])]
)
