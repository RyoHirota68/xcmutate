// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DependentSuites",
    products: [.library(name: "DependentSuites", targets: ["DependentSuites"])],
    targets: [
        .target(name: "DependentSuites"),
        .testTarget(name: "DependentSuitesTests", dependencies: ["DependentSuites"]),
    ]
)
