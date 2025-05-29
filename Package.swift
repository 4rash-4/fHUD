// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "fHUD",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "fHUD", targets: ["fHUD"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "fHUD",
            path: "Sources"
        )
    ]
)