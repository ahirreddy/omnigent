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

// The app assembly: thin adapters from the core-backed stores (`OmnigentStores`,
// `OmnigentTerminalStores`) to the components' view state (`OmnigentUIComponents`,
// `OmnigentAuthUI`, `OmnigentWorkspaceUI`, `OmnigentTerminalUI`), the sign-in flow controller,
// and the connected screen both apps show. The components stay free of the Rust core;
// everything that knows both sides lives here. The macOS-only desktop bridges (notifications,
// Dock badge, menu bar) build only for macOS.
let package = Package(
  name: "OmnigentAppUI",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentAppUI", targets: ["OmnigentAppUI"])],
  dependencies: [
    .package(path: "../OmnigentStores"),
    .package(path: "../OmnigentServices"),
    .package(path: "../OmnigentCoreFFI"),
    .package(path: "../OmnigentUI"),
    .package(path: "../OmnigentAuthUI"),
    .package(path: "../OmnigentWorkspaceUI"),
    .package(path: "../OmnigentDesktop"),
    .package(path: "../OmnigentTerminalUI"),
    .package(path: "../OmnigentTerminalStores"),
  ],
  targets: [
    .target(
      name: "OmnigentAppUI",
      dependencies: [
        .product(name: "OmnigentStores", package: "OmnigentStores"),
        .product(name: "OmnigentServices", package: "OmnigentServices"),
        .product(name: "OmnigentCoreFFI", package: "OmnigentCoreFFI"),
        .product(name: "OmnigentUIComponents", package: "OmnigentUI"),
        .product(name: "OmnigentAuthUI", package: "OmnigentAuthUI"),
        .product(name: "OmnigentWorkspaceUI", package: "OmnigentWorkspaceUI"),
        .product(name: "OmnigentTerminalUI", package: "OmnigentTerminalUI"),
        .product(name: "OmnigentTerminalStores", package: "OmnigentTerminalStores"),
        .product(
          name: "OmnigentDesktop", package: "OmnigentDesktop",
          condition: .when(platforms: [.macOS])),
      ],
      swiftSettings: mainActorSwiftSettings
    ),
    .testTarget(
      name: "OmnigentAppUITests",
      dependencies: [
        "OmnigentAppUI",
        .product(name: "OmnigentStores", package: "OmnigentStores"),
        .product(name: "OmnigentCoreFFI", package: "OmnigentCoreFFI"),
        .product(name: "OmnigentUIComponents", package: "OmnigentUI"),
        .product(name: "OmnigentAuthUI", package: "OmnigentAuthUI"),
      ],
      swiftSettings: mainActorSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
