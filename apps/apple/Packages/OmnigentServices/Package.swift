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

let package = Package(
  name: "OmnigentServices",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentServices", targets: ["OmnigentServices"])],
  dependencies: [
    .package(path: "../OmnigentCoreFFI"),
    .package(path: "../OmnigentTestSupport"),
  ],
  targets: [
    .target(
      name: "OmnigentServices",
      dependencies: [.product(name: "OmnigentCoreFFI", package: "OmnigentCoreFFI")],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "OmnigentServicesTests",
      dependencies: [
        "OmnigentServices",
        .product(name: "OmnigentCoreFFI", package: "OmnigentCoreFFI"),
        .product(name: "OmnigentTestSupport", package: "OmnigentTestSupport"),
      ],
      swiftSettings: strictSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
