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
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "OmnigentDesktop", targets: ["OmnigentDesktop"]),
    .executable(name: "OmnigentDesktopExample", targets: ["OmnigentDesktopExample"]),
  ],
  targets: [
    .target(name: "OmnigentDesktop", swiftSettings: mainActorSwiftSettings),
    .executableTarget(
      name: "OmnigentDesktopExample",
      dependencies: ["OmnigentDesktop"],
      swiftSettings: mainActorSwiftSettings
    ),
    .testTarget(
      name: "OmnigentDesktopTests",
      dependencies: ["OmnigentDesktop"],
      swiftSettings: strictSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
