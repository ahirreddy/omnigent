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

let macOS: [Platform] = [.macOS]
let iOS: [Platform] = [.iOS]

/// libghostty (`GhosttyKit.xcframework`), one binary shared by the macOS and iOS terminal UI.
///
/// The xcframework is a build product of `apps/apple/scripts/fetch-ghostty.sh`, staged in the
/// gitignored `apps/apple/Vendor/ghostty/out/`. Run that script (or `just apple-generate`) before
/// resolving this package. Its static library carries C++ objects (glslang, SPIRV-Cross), so
/// every client links libc++, plus the Apple frameworks the renderer and font stack use.
let package = Package(
  name: "OmnigentGhosttyKit",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [.library(name: "OmnigentGhosttyKit", targets: ["OmnigentGhosttyKit"])],
  targets: [
    .binaryTarget(
      name: "GhosttyKit",
      path: "../../Vendor/ghostty/out/GhosttyKit.xcframework"
    ),
    .target(
      name: "OmnigentGhosttyKit",
      dependencies: ["GhosttyKit"],
      swiftSettings: strictSwiftSettings,
      linkerSettings: [
        .linkedLibrary("c++"),
        .linkedFramework("Metal"),
        .linkedFramework("QuartzCore"),
        .linkedFramework("CoreText"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CoreFoundation"),
        .linkedFramework("CoreVideo"),
        .linkedFramework("IOSurface"),
        .linkedFramework("Foundation"),
        .linkedFramework("AppKit", .when(platforms: macOS)),
        .linkedFramework("Carbon", .when(platforms: macOS)),
        .linkedFramework("UIKit", .when(platforms: iOS)),
      ]
    ),
    .testTarget(
      name: "OmnigentGhosttyKitTests",
      dependencies: ["OmnigentGhosttyKit"],
      swiftSettings: strictSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
