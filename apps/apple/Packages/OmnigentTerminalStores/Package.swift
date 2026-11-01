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

/// The adapter between OmnigentStores and OmnigentTerminalUI: a `TerminalConnection` backed by
/// the core's terminal attach, and a per-session `TerminalStore` that keeps one surface per
/// terminal alive across view changes. It is its own package so OmnigentStores does not link
/// libghostty (a vendored build product) for every client and test.
let package = Package(
  name: "OmnigentTerminalStores",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentTerminalStores", targets: ["OmnigentTerminalStores"])],
  dependencies: [
    .package(path: "../OmnigentStores"),
    .package(path: "../OmnigentTerminalUI"),
    .package(path: "../OmnigentCoreFFI"),
    .package(path: "../OmnigentServices"),
    .package(path: "../OmnigentTestSupport"),
  ],
  targets: [
    .target(
      name: "OmnigentTerminalStores",
      dependencies: [
        .product(name: "OmnigentStores", package: "OmnigentStores"),
        .product(name: "OmnigentTerminalUI", package: "OmnigentTerminalUI"),
        .product(name: "OmnigentCoreFFI", package: "OmnigentCoreFFI"),
      ],
      swiftSettings: mainActorSwiftSettings
    ),
    .testTarget(
      name: "OmnigentTerminalStoresTests",
      dependencies: [
        "OmnigentTerminalStores",
        .product(name: "OmnigentStores", package: "OmnigentStores"),
        .product(name: "OmnigentTerminalUI", package: "OmnigentTerminalUI"),
        .product(name: "OmnigentCoreFFI", package: "OmnigentCoreFFI"),
        .product(name: "OmnigentServices", package: "OmnigentServices"),
        .product(name: "OmnigentTestSupport", package: "OmnigentTestSupport"),
      ],
      swiftSettings: mainActorSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
