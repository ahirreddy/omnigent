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
  name: "OmnigentViewTesting",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentViewTesting", targets: ["OmnigentViewTesting"])],
  targets: [
    .target(name: "OmnigentViewTesting", swiftSettings: strictSwiftSettings),
    .testTarget(
      name: "OmnigentViewTestingTests",
      dependencies: ["OmnigentViewTesting"],
      swiftSettings: strictSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
