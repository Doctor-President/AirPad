// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Harness",
            path: "Sources/Harness",
            swiftSettings: [
                .unsafeFlags(["-target", "arm64-apple-macosx26.0"])
            ]
        )
    ]
)
