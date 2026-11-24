// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HiddenByOtherSuite",
    products: [.library(name: "HiddenByOtherSuite", targets: ["HiddenByOtherSuite"])],
    targets: [
        .target(name: "HiddenByOtherSuite"),
        .testTarget(name: "HiddenByOtherSuiteTests", dependencies: ["HiddenByOtherSuite"]),
    ]
)
