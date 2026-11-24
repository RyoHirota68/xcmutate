// swift-tools-version: 6.0
import PackageDescription

// A package with no host app: its tests run in the `xctest` agent, on an iOS simulator or on macOS.
// Used to measure what a mutant costs when no app has to be installed and launched (docs/speed.md).
let package = Package(
    name: "LogicKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "LogicKit", targets: ["LogicKit"])],
    targets: [
        .target(name: "LogicKit"),
        .testTarget(name: "LogicKitTests", dependencies: ["LogicKit"]),
    ]
)
