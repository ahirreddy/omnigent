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

/// Native input for web content that renders elsewhere: NSEvent to CEF-style pointer and key
/// values, and the `NSTextInputClient` IME state machine. Shared by the local Chromium view
/// (`OmnigentWebLayer`) and the remote browser (`OmnigentRemoteBrowser`); no Chromium code.
let package = Package(
  name: "OmnigentInput",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentInput", targets: ["OmnigentInput"])],
  targets: [
    .target(name: "OmnigentInput", swiftSettings: mainActorSwiftSettings),
    .testTarget(
      name: "OmnigentInputTests",
      dependencies: ["OmnigentInput"],
      swiftSettings: mainActorSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
