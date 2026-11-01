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
  name: "OmnigentStores",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentStores", targets: ["OmnigentStores"])],
  dependencies: [
    .package(path: "../OmnigentServices"),
    .package(path: "../OmnigentCoreFFI"),
    .package(path: "../OmnigentTestSupport"),
  ],
  targets: [
    .target(
      name: "OmnigentStores",
      dependencies: [
        .product(name: "OmnigentServices", package: "OmnigentServices"),
        .product(name: "OmnigentCoreFFI", package: "OmnigentCoreFFI"),
      ],
      swiftSettings: mainActorSwiftSettings
    ),
    .testTarget(
      name: "OmnigentStoresTests",
      dependencies: [
        "OmnigentStores",
        .product(name: "OmnigentCoreFFI", package: "OmnigentCoreFFI"),
        .product(name: "OmnigentServices", package: "OmnigentServices"),
        .product(name: "OmnigentTestSupport", package: "OmnigentTestSupport"),
      ],
      swiftSettings: mainActorSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
