// swift-tools-version: 6.2
import PackageDescription

let macOS: [Platform] = [.macOS]

let strictSwift: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .treatAllWarnings(as: .error),
]
let swiftSettings: [SwiftSetting] = strictSwift + [.defaultIsolation(MainActor.self)]

let package = Package(
  name: "OmnigentBrowser",
  platforms: [.macOS("26.0"), .iOS("26.0")],
  products: [
    // Engine-neutral API and the system (WebKit) engine. Never links or launches Chromium.
    .library(name: "OmnigentBrowser", targets: ["OmnigentBrowser"]),
    // The Chromium engine (macOS): a client of the out-of-process web host through
    // OmnigentWebLayer. Only Developer ID builds, which embed the host, depend on it.
    .library(name: "OmnigentBrowserChromium", targets: ["OmnigentBrowserChromium"]),
  ],
  dependencies: [
    .package(path: "../OmnigentViewTesting"),
    .package(path: "../OmnigentWebLayer"),
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
        .product(
          name: "OmnigentWebLayer", package: "OmnigentWebLayer", condition: .when(platforms: macOS)),
      ],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "OmnigentBrowserTests",
      dependencies: [
        .product(name: "OmnigentViewTesting", package: "OmnigentViewTesting"), "OmnigentBrowser",
      ],
      swiftSettings: strictSwift
    ),
    .testTarget(
      name: "OmnigentBrowserChromiumTests",
      dependencies: [
        .product(name: "OmnigentViewTesting", package: "OmnigentViewTesting"), "OmnigentBrowser",
        "OmnigentBrowserChromium",
      ],
      swiftSettings: strictSwift
    ),
  ]
)
