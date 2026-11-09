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

/// UI-facing code runs on the main actor unless a declaration opts out with `nonisolated`.
let mainActorSwiftSettings = strictSwiftSettings + [.defaultIsolation(MainActor.self)]

let package = Package(
  name: "OmnigentWebLayer",
  platforms: [.macOS("26.0")],
  products: [
    // The OWL client: Session, Profile, WebView, WebContentRenderer, LayerHost.
    .library(name: "OmnigentWebLayer", targets: ["OmnigentWebLayer"])
  ],
  dependencies: [
    // NSEvent translation and IME composition, shared with the remote browser.
    .package(path: "../OmnigentInput"),
    .package(path: "../OmnigentViewTesting"),
  ],
  targets: [
    // The wire schema and Mach transport, shared with the host (apps/apple/WebHost), which
    // compiles these same files.
    .target(
      name: "OWLProtocol",
      cSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Wpedantic", "-Werror"])]
    ),
    .target(
      name: "OmnigentWebLayer",
      dependencies: ["OWLProtocol", .product(name: "OmnigentInput", package: "OmnigentInput")],
      swiftSettings: mainActorSwiftSettings,
      linkerSettings: [.linkedLibrary("bsm")]
    ),
    .testTarget(
      name: "OmnigentWebLayerTests",
      dependencies: [
        .product(name: "OmnigentViewTesting", package: "OmnigentViewTesting"), "OmnigentWebLayer",
        "OWLProtocol",
        .product(name: "OmnigentInput", package: "OmnigentInput"),
      ],
      swiftSettings: mainActorSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6],
  cLanguageStandard: .c2x
)
