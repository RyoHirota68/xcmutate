// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SharedState",
    products: [.library(name: "SharedState", targets: ["SharedState"])],
    targets: [
        .target(name: "SharedState"),
        .testTarget(name: "SharedStateTests", dependencies: ["SharedState"]),
    ]
)
