// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentRuntimeKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "AgentRuntimeCore", targets: ["AgentRuntimeCore"]),
        .library(name: "AgentRuntimeProviders", targets: ["AgentRuntimeProviders"]),
        .library(name: "AgentRuntimeMemory", targets: ["AgentRuntimeMemory"]),
        .library(name: "AgentRuntimeFileMemory", targets: ["AgentRuntimeFileMemory"]),
        .library(name: "AgentRuntimeApple", targets: ["AgentRuntimeApple"]),
        .library(name: "AgentRuntimeMCP", targets: ["AgentRuntimeMCP"]),
        .library(name: "AgentRuntimeTestKit", targets: ["AgentRuntimeTestKit"]),
    ],
    targets: [
        .target(name: "AgentRuntimeCore"),
        .target(
            name: "AgentRuntimeProviders",
            dependencies: ["AgentRuntimeCore"]
        ),
        .target(
            name: "CAgentSQLite",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "AgentRuntimeMemory",
            dependencies: ["AgentRuntimeCore", "CAgentSQLite"]
        ),
        .target(
            name: "AgentRuntimeFileMemory",
            dependencies: ["AgentRuntimeCore", "AgentRuntimeMemory"],
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "AgentRuntimeApple",
            dependencies: [
                "AgentRuntimeCore",
                "AgentRuntimeMemory",
                "AgentRuntimeFileMemory",
            ],
            resources: [.process("Resources/PrivacyInfo.xcprivacy")],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "AgentRuntimeMCP",
            dependencies: ["AgentRuntimeCore"]
        ),
        .target(
            name: "AgentRuntimeTestKit",
            dependencies: ["AgentRuntimeCore"]
        ),
        .testTarget(
            name: "AgentRuntimeCoreTests",
            dependencies: ["AgentRuntimeCore"]
        ),
        .testTarget(
            name: "AgentRuntimeProvidersTests",
            dependencies: ["AgentRuntimeProviders", "AgentRuntimeCore"]
        ),
        .testTarget(
            name: "AgentRuntimeMemoryTests",
            dependencies: ["AgentRuntimeMemory", "AgentRuntimeCore", "CAgentSQLite"]
        ),
        .testTarget(
            name: "AgentRuntimeFileMemoryTests",
            dependencies: [
                "AgentRuntimeFileMemory",
                "AgentRuntimeMemory",
                "AgentRuntimeCore",
            ]
        ),
        .testTarget(
            name: "AgentRuntimeAppleTests",
            dependencies: [
                "AgentRuntimeApple",
                "AgentRuntimeCore",
                "AgentRuntimeMemory",
                "AgentRuntimeFileMemory",
            ]
        ),
        .testTarget(
            name: "AgentRuntimeMCPTests",
            dependencies: ["AgentRuntimeMCP", "AgentRuntimeCore"]
        ),
        .testTarget(
            name: "AgentRuntimeTestKitTests",
            dependencies: ["AgentRuntimeTestKit", "AgentRuntimeCore"]
        ),
        .testTarget(
            name: "AgentRuntimeLiveTests",
            dependencies: [
                "AgentRuntimeCore",
                "AgentRuntimeProviders",
                "AgentRuntimeTestKit",
            ]
        ),
    ]
)
