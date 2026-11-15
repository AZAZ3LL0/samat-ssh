// swift-tools-version: 6.0
import PackageDescription

// Pins swift-openapi-generator for `make generate` without pulling it into the app package graph.
let package = Package(
    name: "Tools",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.4")
    ],
    targets: []
)
