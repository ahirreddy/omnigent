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

/// Session workspace files: a lazily loaded file tree, a file viewer (text with line numbers
/// and highlighting, images), content search, the changed-files list, and a unified or
/// side-by-side diff viewer. Views read view-state types that mirror the Rust core's
/// `omnigent_core::workspace` records; the app supplies a `WorkspaceDataSource` backed by the
/// core. No dependency on the core itself, so previews and the gallery run on sample data.
let package = Package(
  name: "OmnigentWorkspaceUI",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentWorkspaceUI", targets: ["OmnigentWorkspaceUI"])],
  dependencies: [.package(path: "../OmnigentViewTesting")],
  targets: [
    .target(
      name: "OmnigentWorkspaceUI",
      swiftSettings: mainActorSwiftSettings
    ),
    .testTarget(
      name: "OmnigentWorkspaceUITests",
      dependencies: [
        .product(name: "OmnigentViewTesting", package: "OmnigentViewTesting"),
        "OmnigentWorkspaceUI",
      ],
      swiftSettings: mainActorSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
