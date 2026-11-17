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

/// What each OmnigentUIComponents test target links. The tests are split by feature area, so a
/// change to a declaration rebuilds only the areas whose tests it touches.
let componentTestDependencies: [Target.Dependency] = [
  .product(name: "OmnigentViewTesting", package: "OmnigentViewTesting"),
  .product(name: "OmnigentViewTextReading", package: "OmnigentViewTesting"),
  "OmnigentUIComponents", "OmnigentUITestSupport",
  .product(name: "OmnigentAuthUI", package: "OmnigentAuthUI"),
  .product(name: "OmnigentPlatform", package: "OmnigentPlatform"),
  .product(name: "OmnigentWorkspaceUI", package: "OmnigentWorkspaceUI"),
]

let package = Package(
  name: "OmnigentUI",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [
    // Store-bound screens (connect, root, settings); re-exports OmnigentUIComponents.
    .library(name: "OmnigentUI", targets: ["OmnigentUI"]),
    // Views, view state, design system, sample data and the gallery. No Rust core dependency.
    .library(name: "OmnigentUIComponents", targets: ["OmnigentUIComponents"]),
    // A macOS app showing the full layout with sample data: `swift run OmnigentPlayground`.
    .executable(name: "OmnigentPlayground", targets: ["OmnigentPlayground"]),
  ],
  dependencies: [
    .package(path: "../OmnigentViewTesting"),
    .package(path: "../OmnigentStores"),
    .package(path: "../OmnigentPlatform"),
    .package(path: "../OmnigentCoreFFI"),
    // Sign-in screens for the gallery's sign-in pages and flow; it has no dependencies.
    .package(path: "../OmnigentAuthUI"),
    // The shared syntax highlighter for markdown code blocks; in the playground, real Files,
    // Changes and Terminals content for the right panel.
    .package(path: "../OmnigentWorkspaceUI"),
    .package(path: "../OmnigentTerminalUI"),
    // The playground only: a remote browser tab playing the recorded fixture.
    .package(path: "../OmnigentRemoteBrowser"),
    // Markdown parsing (CommonMark + GFM tables) for the transcript renderer. Pinned exactly.
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
  ],
  targets: [
    .target(
      name: "OmnigentUI",
      dependencies: [
        "OmnigentUIComponents",
        .product(name: "OmnigentStores", package: "OmnigentStores"),
        .product(name: "OmnigentPlatform", package: "OmnigentPlatform"),
        .product(name: "OmnigentCoreFFI", package: "OmnigentCoreFFI"),
      ],
      swiftSettings: mainActorSwiftSettings
    ),
    .target(
      name: "OmnigentUIComponents",
      dependencies: [
        .product(name: "OmnigentPlatform", package: "OmnigentPlatform"),
        .product(name: "OmnigentAuthUI", package: "OmnigentAuthUI"),
        .product(name: "OmnigentWorkspaceUI", package: "OmnigentWorkspaceUI"),
        .product(name: "Markdown", package: "swift-markdown"),
      ],
      // KaTeX and Mermaid for typeset math and diagrams (scripts/vendor-rich-render.sh).
      resources: [.copy("Resources/RichRender")],
      swiftSettings: mainActorSwiftSettings
    ),
    .executableTarget(
      name: "OmnigentPlayground",
      dependencies: [
        "OmnigentUIComponents",
        .product(name: "OmnigentWorkspaceUI", package: "OmnigentWorkspaceUI"),
        .product(name: "OmnigentTerminalUI", package: "OmnigentTerminalUI"),
        .product(name: "OmnigentRemoteBrowser", package: "OmnigentRemoteBrowser"),
      ],
      path: "Playground",
      swiftSettings: mainActorSwiftSettings
    ),
    // Helpers that tests in more than one area use; the area targets `@testable import` it.
    .target(
      name: "OmnigentUITestSupport",
      dependencies: [
        .product(name: "OmnigentViewTesting", package: "OmnigentViewTesting"),
        .product(name: "OmnigentViewTextReading", package: "OmnigentViewTesting"),
        "OmnigentUIComponents",
      ],
      path: "Tests/OmnigentUITestSupport",
      swiftSettings: mainActorSwiftSettings
    ),
    // Design system, shell, layout, view state and the rest.
    .testTarget(
      name: "OmnigentUIComponentTests", dependencies: componentTestDependencies,
      swiftSettings: mainActorSwiftSettings),
    .testTarget(
      name: "OmnigentUITranscriptTests", dependencies: componentTestDependencies,
      swiftSettings: mainActorSwiftSettings),
    // Markdown, code blocks, links and the CLI look.
    .testTarget(
      name: "OmnigentUIMarkdownTests", dependencies: componentTestDependencies,
      swiftSettings: mainActorSwiftSettings),
    .testTarget(
      name: "OmnigentUIComposerTests", dependencies: componentTestDependencies,
      swiftSettings: mainActorSwiftSettings),
    .testTarget(
      name: "OmnigentUITabsTests", dependencies: componentTestDependencies,
      swiftSettings: mainActorSwiftSettings),
    .testTarget(
      name: "OmnigentUISessionListTests", dependencies: componentTestDependencies,
      swiftSettings: mainActorSwiftSettings),
    .testTarget(
      name: "OmnigentUISettingsTests", dependencies: componentTestDependencies,
      swiftSettings: mainActorSwiftSettings),
    // Inspector, workspace panel and sandbox status.
    .testTarget(
      name: "OmnigentUIInspectorTests", dependencies: componentTestDependencies,
      swiftSettings: mainActorSwiftSettings),
    // Decisions, new session, inbox, palette, commands, automations and usage.
    .testTarget(
      name: "OmnigentUIPagesTests", dependencies: componentTestDependencies,
      swiftSettings: mainActorSwiftSettings),
    // The gallery and its whole-catalog renders (the slow lane).
    .testTarget(
      name: "OmnigentUIGalleryTests", dependencies: componentTestDependencies,
      swiftSettings: mainActorSwiftSettings),
  ],
  swiftLanguageModes: [.v6]
)
