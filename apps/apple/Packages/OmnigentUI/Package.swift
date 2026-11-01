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

let package = Package(
  name: "OmnigentUI",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentUI", targets: ["OmnigentUI"])],
  dependencies: [
    .package(path: "../OmnigentStores"),
    .package(path: "../OmnigentPlatform"),
    .package(path: "../OmnigentCoreFFI"),
  ],
  targets: [
    .target(
      name: "OmnigentUI",
      dependencies: [
        .product(name: "OmnigentStores", package: "OmnigentStores"),
        .product(name: "OmnigentPlatform", package: "OmnigentPlatform"),
        .product(name: "OmnigentCoreFFI", package: "OmnigentCoreFFI"),
      ],
      swiftSettings: mainActorSwiftSettings
    )
  ],
  swiftLanguageModes: [.v6]
)
