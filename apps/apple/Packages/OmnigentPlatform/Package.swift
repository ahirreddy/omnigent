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
  name: "OmnigentPlatform",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentPlatform", targets: ["OmnigentPlatform"])],
  targets: [
    .target(name: "OmnigentPlatform", swiftSettings: strictSwiftSettings),
    .testTarget(
      name: "OmnigentPlatformTests", dependencies: ["OmnigentPlatform"],
      swiftSettings: strictSwiftSettings),
  ],
  swiftLanguageModes: [.v6]
)
