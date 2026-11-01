// swift-tools-version: 6.2
import PackageDescription

/// Mirrors `Omnigent.strictBase` in Tuist/ProjectDescriptionHelpers.
let strictSwiftSettings: [SwiftSetting] = [
  .treatAllWarnings(as: .error),
  .strictMemorySafety(),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let mainActorSwiftSettings = strictSwiftSettings + [.defaultIsolation(MainActor.self)]

/// Session terminals rendered by libghostty on macOS and iOS: the surface view, the session's
/// harness TUI view, the terminal list, and a gallery. The view talks to a `TerminalConnection`;
/// the app backs it with the Rust attach state machine and the URLSession WebSocket transport.
let package = Package(
  name: "OmnigentTerminalUI",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentTerminalUI", targets: ["OmnigentTerminalUI"])],
  dependencies: [
    .package(path: "../OmnigentGhosttyKit")
  ],
  targets: [
    .target(
      name: "OmnigentTerminalUI",
      dependencies: [.product(name: "OmnigentGhosttyKit", package: "OmnigentGhosttyKit")],
      resources: [.copy("Resources/repl-tui.jsonl")],
      swiftSettings: mainActorSwiftSettings
    ),
    .testTarget(
      name: "OmnigentTerminalUITests",
      dependencies: ["OmnigentTerminalUI"],
      swiftSettings: mainActorSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
