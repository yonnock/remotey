// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Remotey",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Remotey",
            path: "Sources/Remotey",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "RemoteyTests", dependencies: ["Remotey"])
    ]
)
