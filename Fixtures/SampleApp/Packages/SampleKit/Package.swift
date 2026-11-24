// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SampleKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "SampleKit", targets: ["SampleKit"])],
    targets: [.target(name: "SampleKit")]
)
