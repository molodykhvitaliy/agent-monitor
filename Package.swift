// swift-tools-version: 6.2
//
// AgentBar's logic lives in SPM modules so `swift test` exercises it without an
// Xcode build (ADR-0003). The app and helper bundles are described separately in
// project.yml.
//
// The module graph is the architecture: dependencies point inward, AgentBarCore
// depends on nothing, and no adapter depends on another adapter. See
// docs/dev/architecture.md.

import PackageDescription

/// Tools version 6.2 rather than 6.3: nothing here needs 6.3, and the lower
/// floor keeps the package buildable on any Xcode 26 toolchain rather than only
/// the newest one on a CI image.
let package = Package(
    name: "AgentBar",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AgentBarCore", targets: ["AgentBarCore"]),
        .library(name: "AgentBarJSON", targets: ["AgentBarJSON"]),
        .library(name: "AgentBarIngest", targets: ["AgentBarIngest"]),
        .library(name: "ClaudeCodeAdapter", targets: ["ClaudeCodeAdapter"]),
        .library(name: "CodexAdapter", targets: ["CodexAdapter"]),
        .library(name: "CodexAppServer", targets: ["CodexAppServer"]),
        .library(name: "AgentBarNotifications", targets: ["AgentBarNotifications"]),
        .library(name: "AgentBarPower", targets: ["AgentBarPower"]),
        .library(name: "AgentBarUI", targets: ["AgentBarUI"]),
    ],
    targets: [
        // Provider-neutral domain. No I/O, no platform imports — enforced by
        // ArchitectureTests, because a system framework needs no package
        // dependency and so the module graph alone cannot police this.
        .target(name: "AgentBarCore"),

        // Ordered, lossless JSON, shared by the two adapters because both merge
        // into a configuration file the user owns. Depends on nothing but
        // Foundation and knows nothing about either provider — it moved out of
        // ClaudeCodeAdapter in step 09 rather than being copied into the second
        // adapter, because no adapter may import another.
        .target(name: "AgentBarJSON"),

        .target(name: "AgentBarIngest", dependencies: ["AgentBarCore"]),
        // Reaches AgentBarIngest for `EventDecoding`, the seam the endpoint
        // publishes for adapters. Every other edge points straight at the core.
        .target(
            name: "ClaudeCodeAdapter",
            dependencies: ["AgentBarCore", "AgentBarIngest", "AgentBarJSON"]),
        // The same two edges as the Claude Code adapter, for the same two
        // reasons. `agentbar-helper` links this module as well as the app does:
        // the relay is the adapter's transport, and putting it here is what lets
        // `swift test` exercise the code the hook actually runs.
        .target(
            name: "CodexAdapter", dependencies: ["AgentBarCore", "AgentBarIngest", "AgentBarJSON"]),
        .target(name: "CodexAppServer", dependencies: ["AgentBarCore"]),
        .target(name: "AgentBarNotifications", dependencies: ["AgentBarCore"]),
        .target(name: "AgentBarPower", dependencies: ["AgentBarCore"]),

        // Views and view models are main-actor by nature, so the module opts
        // into MainActor as its default isolation instead of annotating every
        // declaration. Every other module stays nonisolated by default.
        .target(
            name: "AgentBarUI",
            dependencies: ["AgentBarCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),

        .testTarget(name: "AgentBarCoreTests", dependencies: ["AgentBarCore"]),
        .testTarget(name: "AgentBarJSONTests", dependencies: ["AgentBarJSON"]),
        .testTarget(
            name: "AgentBarIngestTests", dependencies: ["AgentBarIngest", "AgentBarCore"]),
        .testTarget(
            name: "ClaudeCodeAdapterTests",
            dependencies: ["ClaudeCodeAdapter", "AgentBarIngest", "AgentBarCore", "AgentBarJSON"],
            resources: [.copy("Fixtures")]),
        .testTarget(
            name: "CodexAdapterTests",
            dependencies: ["CodexAdapter", "AgentBarIngest", "AgentBarCore", "AgentBarJSON"],
            resources: [.copy("Fixtures")]),

        .testTarget(name: "AgentBarUITests", dependencies: ["AgentBarUI", "AgentBarCore"]),
        .testTarget(
            name: "AgentBarNotificationsTests",
            dependencies: ["AgentBarNotifications", "AgentBarCore"]),
        .testTarget(name: "AgentBarPowerTests", dependencies: ["AgentBarPower", "AgentBarCore"]),

        // Reads source files rather than symbols: it guards boundaries the
        // compiler cannot express.
        .testTarget(name: "ArchitectureTests"),
    ],
    swiftLanguageModes: [.v6]
)
