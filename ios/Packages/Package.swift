// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PulsePackages",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AgentAPI", targets: ["AgentAPI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.8.0")
    ],
    targets: [
        .target(
            name: "AgentAPI",
            dependencies: [.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")],
            path: "AgentAPI/Sources"
        ),
        .testTarget(
            name: "AgentAPITests",
            dependencies: ["AgentAPI"],
            path: "AgentAPI/Tests/AgentAPITests"
        ),
    ]
)
