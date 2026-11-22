// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PulsePackages",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AgentAPI", targets: ["AgentAPI"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "Fixtures", targets: ["Fixtures"]),
        .library(name: "Overview", targets: ["Overview"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "ServerList", targets: ["ServerList"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
        // Pinned to the merge of `withExec` (stdin for exec, needed by `sudo -S`), the last commit before
        // 0.12.1 moved swift-nio-ssh to a third-party fork. Until then Citadel uses its author's fork,
        // which adds RSA and other algorithms to Apple's swift-nio-ssh. Move to a release that keeps it.
        .package(url: "https://github.com/orlandos-nl/Citadel", revision: "69d80d39ca3b0bac5f04551a97af5dd7a827f887"),
        // Citadel's own dependencies; AgentKit uses their key and buffer types directly.
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0"),
        .package(url: "https://github.com/Joannis/swift-nio-ssh.git", "0.3.4"..<"0.4.0"),
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
        .target(
            name: "AgentKit",
            dependencies: [
                "AgentAPI",
                "Fixtures",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ],
            path: "AgentKit/Sources"
        ),
        .testTarget(
            name: "AgentKitTests",
            dependencies: [
                "AgentKit", "AgentAPI", "Fixtures",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ],
            path: "AgentKit/Tests/AgentKitTests"
        ),
        .target(
            name: "DesignSystem",
            dependencies: ["AgentKit"],
            path: "DesignSystem/Sources",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem", "AgentKit"],
            path: "DesignSystem/Tests/DesignSystemTests"
        ),
        .target(
            name: "Fixtures",
            path: "Fixtures/Sources",
            // A symlink to the repository's fixtures/, so the app and the agent share one copy.
            resources: [.copy("fixtures")]
        ),
        .testTarget(
            name: "FixturesTests",
            dependencies: ["Fixtures"],
            path: "Fixtures/Tests/FixturesTests"
        ),
        .target(
            name: "Overview",
            dependencies: ["AgentKit", "DesignSystem"],
            path: "Features/Overview/Sources/Overview",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OverviewTests",
            dependencies: ["Overview", "AgentKit"],
            path: "Features/Overview/Tests/OverviewTests"
        ),
        .target(
            name: "ServerList",
            dependencies: ["AgentKit", "DesignSystem", "Persistence"],
            path: "Features/ServerList/Sources/ServerList",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ServerListTests",
            dependencies: ["ServerList", "AgentKit", "Persistence"],
            path: "Features/ServerList/Tests/ServerListTests"
        ),
        .target(
            name: "Persistence",
            path: "Persistence/Sources"
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence"],
            path: "Persistence/Tests/PersistenceTests"
        ),
    ]
)
