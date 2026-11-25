// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PhotoBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PhotoBridge",
            path: "Sources/PhotoBridge",
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .release))],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
