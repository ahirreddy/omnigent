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
    .package(path: "../OmnigentStores"),
    .package(path: "../OmnigentPlatform"),
    .package(path: "../OmnigentCoreFFI"),
    // The playground only: real Files, Changes and Terminals content for the right panel.
    .package(path: "../OmnigentWorkspaceUI"),
    .package(path: "../OmnigentTerminalUI"),
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
        .product(name: "Markdown", package: "swift-markdown"),
      ],
      swiftSettings: mainActorSwiftSettings
    ),
    .executableTarget(
      name: "OmnigentPlayground",
      dependencies: [
        "OmnigentUIComponents",
        .product(name: "OmnigentWorkspaceUI", package: "OmnigentWorkspaceUI"),
        .product(name: "OmnigentTerminalUI", package: "OmnigentTerminalUI"),
      ],
      path: "Playground",
      swiftSettings: mainActorSwiftSettings
    ),
    .testTarget(
      name: "OmnigentUIComponentTests",
      dependencies: ["OmnigentUIComponents"],
      swiftSettings: mainActorSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
