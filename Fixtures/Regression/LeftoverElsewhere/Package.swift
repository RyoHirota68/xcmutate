// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LeftoverElsewhere",
    products: [.library(name: "LeftoverElsewhere", targets: ["LeftoverElsewhere"])],
    targets: [
        .target(name: "LeftoverElsewhere"),
        .testTarget(name: "LeftoverElsewhereTests", dependencies: ["LeftoverElsewhere"]),
    ]
)
