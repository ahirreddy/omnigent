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
  name: "OmnigentTestSupport",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentTestSupport", targets: ["OmnigentTestSupport"])],
  dependencies: [.package(path: "../OmnigentCoreFFI")],
  targets: [
    .target(
      name: "OmnigentTestSupport",
      dependencies: [.product(name: "OmnigentCoreFFI", package: "OmnigentCoreFFI")],
      swiftSettings: strictSwiftSettings
    )
  ],
  swiftLanguageModes: [.v6]
)
