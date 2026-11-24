// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StateLeak",
    products: [.library(name: "StateLeak", targets: ["StateLeak"])],
    targets: [
        .target(name: "StateLeak"),
        .testTarget(name: "StateLeakTests", dependencies: ["StateLeak"]),
    ]
)
