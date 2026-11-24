// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shapes",
    products: [.library(name: "Shapes", targets: ["Shapes"])],
    targets: [
        .target(name: "Shapes"),
        .testTarget(name: "ShapesTests", dependencies: ["Shapes"]),
    ]
)
