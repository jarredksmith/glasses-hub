// swift-tools-version:5.9
import PackageDescription

// Everything in Glasses Hub that doesn't need an iPhone: the glasses wire format, the display session,
// text layout and the apps' logic. It builds and tests on any machine with Swift (`swift test`).
let package = Package(
    name: "HubCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "HubCore", targets: ["HubCore"])],
    targets: [
        .target(name: "HubCore"),
        .testTarget(name: "HubCoreTests", dependencies: ["HubCore"]),
    ]
)
