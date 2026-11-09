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
  products: [
    .library(name: "OmnigentViewTesting", targets: ["OmnigentViewTesting"]),
    // Opt-in: a test target that links this records SwiftUI's view tree in its whole process.
    .library(name: "OmnigentViewTextReading", targets: ["OmnigentViewTextReading"]),
  ],
  targets: [
    .target(name: "OmnigentViewTesting", swiftSettings: strictSwiftSettings),
    // Tells SwiftUI to record its view tree, which must happen before the process's first view.
    .target(name: "OmnigentViewDebugBootstrap"),
    .target(
      name: "OmnigentViewTextReading",
      dependencies: ["OmnigentViewTesting", "OmnigentViewDebugBootstrap"],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "OmnigentViewTestingTests",
      dependencies: ["OmnigentViewTesting"],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "OmnigentViewTextReadingTests",
      dependencies: ["OmnigentViewTesting", "OmnigentViewTextReading"],
      swiftSettings: strictSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
