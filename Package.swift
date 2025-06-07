// swift-tools-version: 6.0
// Swift Package manifest for the Thought Crystallizer app.
import PackageDescription

let package = Package(
    name: "fHUD",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "fHUD", targets: ["fHUD"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "fHUD",
            path: "Sources"
        ),
    ]
)
