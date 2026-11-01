// swift-tools-version: 6.2
import Foundation
import PackageDescription

// CEF (Chromium) is macOS-only and comes from apps/apple/scripts/fetch-cef.sh, which stages
// headers and libcef_dll_wrapper.a under apps/apple/Vendor/cef/out. Without it the Chromium
// engine still compiles, but reports itself as not bundled at runtime. Re-resolve packages
// (or re-run `tuist generate`) after fetching so this manifest is re-evaluated.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let cefOut = packageDirectory.appendingPathComponent("../../Vendor/cef/out").standardizedFileURL
let cefWrapper = cefOut.appendingPathComponent("lib/libcef_dll_wrapper.a")
let cefStaged = FileManager.default.fileExists(atPath: cefWrapper.path)
let macOS: [Platform] = [.macOS]

let cefCxxSettings: [CXXSetting] =
  cefStaged
  ? [
    .define("OMNIGENT_CEF_LINKED", to: "1", .when(platforms: macOS)),
    // libcef_dll_wrapper is built Release (NDEBUG); CEF base headers change layout with DCHECKs.
    .define("NDEBUG", .when(platforms: macOS)),
    // CEF headers are third-party; -isystem scopes warning exemptions to them only.
    .unsafeFlags(["-isystem", cefOut.path], .when(platforms: macOS)),
  ]
  : []
let cefLinkerSettings: [LinkerSetting] =
  cefStaged
  ? [
    .unsafeFlags(["-L", cefOut.appendingPathComponent("lib").path], .when(platforms: macOS)),
    .linkedLibrary("cef_dll_wrapper", .when(platforms: macOS)),
  ]
  : []

let strictSwift: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .treatAllWarnings(as: .error),
]
let swiftSettings: [SwiftSetting] = strictSwift + [.defaultIsolation(MainActor.self)]

let strictClang: [CXXSetting] = [
  .unsafeFlags(["-Wall", "-Wextra", "-Wpedantic", "-Werror", "-fobjc-arc"])
]

let package = Package(
  name: "OmnigentBrowser",
  platforms: [.macOS("26.0"), .iOS("26.0")],
  products: [
    // Engine-neutral API and the system (WebKit) engine. Never links CEF.
    .library(name: "OmnigentBrowser", targets: ["OmnigentBrowser"]),
    // The Chromium engine (macOS). Only builds that ship CEF depend on it.
    .library(name: "OmnigentBrowserChromium", targets: ["OmnigentBrowserChromium"]),
  ],
  targets: [
    .target(
      name: "OmnigentBrowser",
      swiftSettings: swiftSettings
    ),
    .target(
      name: "OmnigentBrowserChromium",
      dependencies: [
        "OmnigentBrowser",
        .target(name: "OmnigentCEFBridge", condition: .when(platforms: macOS)),
      ],
      swiftSettings: swiftSettings
    ),
    .target(
      name: "OmnigentCEFBridge",
      cxxSettings: strictClang + cefCxxSettings,
      linkerSettings: cefLinkerSettings + [
        .linkedFramework("AppKit", .when(platforms: macOS))
      ]
    ),
    .testTarget(
      name: "OmnigentBrowserTests",
      dependencies: ["OmnigentBrowser"],
      swiftSettings: strictSwift
    ),
    .testTarget(
      name: "OmnigentBrowserChromiumTests",
      dependencies: ["OmnigentBrowser", "OmnigentBrowserChromium"],
      swiftSettings: strictSwift
    ),
  ],
  cxxLanguageStandard: .cxx20
)
