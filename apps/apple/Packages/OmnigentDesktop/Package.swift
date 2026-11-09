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

/// App-facing targets run on the main actor unless a declaration opts out with `nonisolated`.
let mainActorSwiftSettings = strictSwiftSettings + [.defaultIsolation(MainActor.self)]

let package = Package(
  name: "OmnigentDesktop",
  // iOS builds only `OmnigentDeepLinks`; the desktop targets are macOS only.
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [
    .library(name: "OmnigentDesktop", targets: ["OmnigentDesktop"]),
    // `omnigent://` link parsing and window routing, shared with the iOS app.
    .library(name: "OmnigentDeepLinks", targets: ["OmnigentDeepLinks"]),
    // Sparkle updates, for the Developer ID edition only: the App Store edition must never link
    // Sparkle, so it is a separate product (see RELEASE.md, "Auto-update").
    .library(name: "OmnigentDesktopUpdate", targets: ["OmnigentDesktopUpdate"]),
    .executable(name: "OmnigentDesktopExample", targets: ["OmnigentDesktopExample"]),
  ],
  dependencies: [
    // Keep equal to SPARKLE_VERSION in scripts/release/fetch-sparkle-tools.sh.
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    .package(path: "../OmnigentViewTesting"),
  ],
  targets: [
    .target(name: "OmnigentDeepLinks", swiftSettings: mainActorSwiftSettings),
    .target(
      name: "OmnigentDesktop", dependencies: ["OmnigentDeepLinks"], exclude: ["Update"],
      swiftSettings: mainActorSwiftSettings),
    .target(
      name: "OmnigentDesktopUpdate",
      dependencies: [.product(name: "Sparkle", package: "Sparkle")],
      path: "Sources/OmnigentDesktop/Update",
      swiftSettings: mainActorSwiftSettings
    ),
    .executableTarget(
      name: "OmnigentDesktopExample",
      dependencies: ["OmnigentDesktop"],
      swiftSettings: mainActorSwiftSettings
    ),
    .testTarget(
      name: "OmnigentDeepLinksTests",
      dependencies: [
        .product(name: "OmnigentViewTesting", package: "OmnigentViewTesting"), "OmnigentDeepLinks",
      ],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "OmnigentDesktopTests",
      dependencies: [
        .product(name: "OmnigentViewTesting", package: "OmnigentViewTesting"),
        .product(name: "OmnigentViewTextReading", package: "OmnigentViewTesting"),
        "OmnigentDesktop",
      ],
      swiftSettings: strictSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
