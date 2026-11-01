import ProjectDescription
import ProjectDescriptionHelpers

let localPackages: [Package] = [
  .package(path: "Packages/OmnigentUI"),
  .package(path: "Packages/OmnigentStores"),
  .package(path: "Packages/OmnigentServices"),
  .package(path: "Packages/OmnigentPlatform"),
  .package(path: "Packages/OmnigentTestSupport"),
  .package(path: "Packages/OmnigentCoreFFI"),
  .package(path: "Packages/OmnigentBrowser"),
]

let appDependencies: [TargetDependency] = [
  .package(product: "OmnigentUI"),
  .package(product: "OmnigentStores"),
  .package(product: "OmnigentServices"),
  .package(product: "OmnigentCoreFFI"),
]

let unitTestDependencies: [TargetDependency] = [
  .package(product: "OmnigentStores"),
  .package(product: "OmnigentTestSupport"),
  .package(product: "OmnigentCoreFFI"),
]

/// Chromium (CEF) helpers and embed step for the Mac app; see Packages/OmnigentBrowser/README.md.
let macBrowser = BrowserTargets.Configuration(
  appTargetName: "OmnigentMac",
  appProductName: "Omnigent",
  appBundleId: "ai.omnigent.mac",
  deploymentTarget: Omnigent.deploymentVersion
)

let iOSApp = Target.target(
  name: "Omnigent",
  destinations: [.iPhone, .iPad],
  product: .app,
  bundleId: "ai.omnigent.ios",
  deploymentTargets: .iOS(Omnigent.deploymentVersion),
  infoPlist: Omnigent.infoPlist(extra: [
    "UILaunchScreen": [:],
    "UIApplicationSupportsIndirectInputEvents": true,
    "UISupportedInterfaceOrientations": [
      "UIInterfaceOrientationPortrait",
      "UIInterfaceOrientationLandscapeLeft",
      "UIInterfaceOrientationLandscapeRight",
    ],
    "UISupportedInterfaceOrientations~ipad": [
      "UIInterfaceOrientationPortrait",
      "UIInterfaceOrientationPortraitUpsideDown",
      "UIInterfaceOrientationLandscapeLeft",
      "UIInterfaceOrientationLandscapeRight",
    ],
  ]),
  sources: ["Apps/Omnigent-iOS/Sources/**"],
  resources: [
    "Apps/Omnigent-iOS/Resources/**",
    Omnigent.appIcon,
  ],
  dependencies: appDependencies,
  settings: Omnigent.appSettings(
    releaseBundleId: "ai.omnigent.ios",
    displayName: "Omnigent",
    extraBase: [
      "TARGETED_DEVICE_FAMILY": "1,2",
      "SUPPORTS_MACCATALYST": "NO",
      "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
      "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
    ]
  )
)

let macApp = Target.target(
  name: "OmnigentMac",
  destinations: [.mac],
  product: .app,
  productName: "Omnigent",
  bundleId: "ai.omnigent.mac",
  deploymentTargets: .macOS(Omnigent.deploymentVersion),
  infoPlist: Omnigent.infoPlist(extra: [
    "LSApplicationCategoryType": "public.app-category.developer-tools",
    "NSHumanReadableCopyright": "Copyright Omnigent contributors.",
  ]),
  sources: ["Apps/Omnigent-macOS/Sources/**"],
  resources: [Omnigent.appIcon],
  entitlements: .file(path: "Apps/Omnigent-macOS/OmnigentMac.entitlements"),
  scripts: BrowserTargets.appScripts(macBrowser),
  dependencies: appDependencies + [.package(product: "OmnigentBrowser")]
    + BrowserTargets.appDependencies(macBrowser),
  settings: Omnigent.appSettings(
    releaseBundleId: "ai.omnigent.mac",
    displayName: "Omnigent",
    extraBase: BrowserTargets.appSettings.merging([
      "ENABLE_HARDENED_RUNTIME": "YES",
      "COMBINE_HIDPI_IMAGES": "YES",
    ]) { _, new in new },
    debug: [
      "CODE_SIGN_IDENTITY": "-"
    ]
  )
)

func unitTests(
  name: String, host: String, destinations: Destinations, deployment: DeploymentTargets
) -> Target {
  .target(
    name: name,
    destinations: destinations,
    product: .unitTests,
    bundleId: "ai.omnigent.\(name.lowercased())",
    deploymentTargets: deployment,
    infoPlist: .default,
    sources: ["Tests/\(name)/**"],
    dependencies: [.target(name: host)] + unitTestDependencies,
    settings: Omnigent.testSettings()
  )
}

func uiTests(name: String, host: String, destinations: Destinations, deployment: DeploymentTargets)
  -> Target
{
  .target(
    name: name,
    destinations: destinations,
    product: .uiTests,
    bundleId: "ai.omnigent.\(name.lowercased())",
    deploymentTargets: deployment,
    infoPlist: .default,
    sources: ["Tests/\(name)/**"],
    dependencies: [.target(name: host)],
    settings: Omnigent.testSettings()
  )
}

let project = Project(
  name: "Omnigent",
  options: .options(
    automaticSchemesOptions: .disabled,
    defaultKnownRegions: ["en", "Base"],
    developmentRegion: "en"
  ),
  packages: localPackages,
  settings: Omnigent.projectSettings(),
  targets: [
    iOSApp,
    macApp,
    unitTests(
      name: "OmnigentTests", host: "Omnigent", destinations: [.iPhone, .iPad],
      deployment: .iOS(Omnigent.deploymentVersion)),
    uiTests(
      name: "OmnigentUITests", host: "Omnigent", destinations: [.iPhone, .iPad],
      deployment: .iOS(Omnigent.deploymentVersion)),
    unitTests(
      name: "OmnigentMacTests", host: "OmnigentMac", destinations: [.mac],
      deployment: .macOS(Omnigent.deploymentVersion)),
    uiTests(
      name: "OmnigentMacUITests", host: "OmnigentMac", destinations: [.mac],
      deployment: .macOS(Omnigent.deploymentVersion)),
  ] + BrowserTargets.helperTargets(macBrowser),
  schemes: [
    .scheme(
      name: "Omnigent",
      shared: true,
      buildAction: .buildAction(targets: ["Omnigent"]),
      testAction: .targets(
        ["OmnigentTests", "OmnigentUITests"],
        configuration: "Debug"
      ),
      runAction: .runAction(configuration: "Debug", executable: "Omnigent"),
      archiveAction: .archiveAction(configuration: "Release"),
      profileAction: .profileAction(configuration: "Release", executable: "Omnigent"),
      analyzeAction: .analyzeAction(configuration: "Debug")
    ),
    .scheme(
      name: "OmnigentMac",
      shared: true,
      buildAction: .buildAction(targets: ["OmnigentMac"]),
      testAction: .targets(
        ["OmnigentMacTests", "OmnigentMacUITests"],
        configuration: "Debug"
      ),
      runAction: .runAction(configuration: "Debug", executable: "OmnigentMac"),
      archiveAction: .archiveAction(configuration: "Release"),
      profileAction: .profileAction(configuration: "Release", executable: "OmnigentMac"),
      analyzeAction: .analyzeAction(configuration: "Debug")
    ),
  ]
)
