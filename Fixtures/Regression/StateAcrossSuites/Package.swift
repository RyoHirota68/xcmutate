// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StateAcrossSuites",
    products: [.library(name: "StateAcrossSuites", targets: ["StateAcrossSuites"])],
    targets: [
        .target(name: "StateAcrossSuites"),
        .testTarget(name: "StateAcrossSuitesTests", dependencies: ["StateAcrossSuites"]),
    ]
)
