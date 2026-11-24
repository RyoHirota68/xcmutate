// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "xcmutate",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "xcmutate", targets: ["xcmutate"]),
        .library(name: "MutatorCore", targets: ["MutatorCore"]),
        .library(name: "MutatorRunner", targets: ["MutatorRunner"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    ],
    targets: [
        .target(
            name: "MutatorCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "MutatorRunner",
            dependencies: ["MutatorCore"]
        ),
        .executableTarget(
            name: "xcmutate",
            dependencies: [
                "MutatorCore",
                "MutatorRunner",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MutatorCoreTests",
            dependencies: ["MutatorCore", "MutatorRunner"]
        ),
    ]
)
