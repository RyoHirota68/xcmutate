// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnceOutsideGate",
    products: [.library(name: "OnceOutsideGate", targets: ["OnceOutsideGate"])],
    targets: [
        .target(name: "OnceOutsideGate"),
        .testTarget(name: "OnceOutsideGateTests", dependencies: ["OnceOutsideGate"]),
    ]
)
