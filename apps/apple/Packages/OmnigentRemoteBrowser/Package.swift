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

/// A browser running on the agent's machine, shown as a local tab: H.264 decoded in hardware
/// through `AVSampleBufferDisplayLayer`, input mapped to the remote viewport, and minimal browser
/// chrome. `RemoteBrowserStore` talks to a `RemoteBrowserDriving` (the Rust core's driver in the
/// app, a fixture player in previews and tests). See `docs/remote-browser-design.md`.
let package = Package(
  name: "OmnigentRemoteBrowser",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentRemoteBrowser", targets: ["OmnigentRemoteBrowser"])],
  dependencies: [
    .package(path: "../OmnigentViewTesting"),
    .package(path: "../OmnigentInput"),
    .package(path: "../OmnigentCoreFFI"),
    // The omnibox's URL-or-search interpretation, shared with the local browser.
    .package(path: "../OmnigentBrowser"),
    // Tests only: the live host test's transports and secure store.
    .package(path: "../OmnigentServices"),
    .package(path: "../OmnigentTestSupport"),
  ],
  targets: [
    .target(
      name: "OmnigentRemoteBrowser",
      dependencies: [
        .product(name: "OmnigentInput", package: "OmnigentInput"),
        .product(name: "OmnigentBrowser", package: "OmnigentBrowser"),
        .product(name: "OmnigentCoreFFI", package: "OmnigentCoreFFI"),
      ],
      // The shared protocol fixtures from client-core/fixtures/remote_browser (symlinks), played
      // by the fixture driver in previews, the playground and tests.
      resources: [
        .copy("Resources/testsrc_1280x800.annexb"),
        .copy("Resources/testsrc_1280x800.frames.json"),
        .copy("Resources/testsrc_640x400.annexb"),
        .copy("Resources/testsrc_640x400.frames.json"),
        .copy("Resources/thumbnail_320x200.jpg"),
      ],
      swiftSettings: mainActorSwiftSettings
    ),
    .testTarget(
      name: "OmnigentRemoteBrowserTests",
      dependencies: [
        .product(name: "OmnigentViewTesting", package: "OmnigentViewTesting"),
        "OmnigentRemoteBrowser", .product(name: "OmnigentInput", package: "OmnigentInput"),
        .product(name: "OmnigentCoreFFI", package: "OmnigentCoreFFI"),
        .product(name: "OmnigentServices", package: "OmnigentServices"),
        .product(name: "OmnigentTestSupport", package: "OmnigentTestSupport"),
      ],
      swiftSettings: mainActorSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
