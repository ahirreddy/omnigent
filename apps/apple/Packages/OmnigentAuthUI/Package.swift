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

// Sign-in and connection UI. It has no dependencies on purpose: its view state mirrors the
// `omnigent-ffi` auth records field for field, and a thin adapter in the stores maps the FFI
// types onto it. That keeps the package buildable, previewable and testable without the Rust
// xcframework.
let package = Package(
  name: "OmnigentAuthUI",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentAuthUI", targets: ["OmnigentAuthUI"])],
  dependencies: [.package(path: "../OmnigentViewTesting")],
  targets: [
    .target(name: "OmnigentAuthUI", swiftSettings: mainActorSwiftSettings),
    .testTarget(
      name: "OmnigentAuthUITests",
      dependencies: [
        .product(name: "OmnigentViewTesting", package: "OmnigentViewTesting"), "OmnigentAuthUI",
      ],
      swiftSettings: mainActorSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
