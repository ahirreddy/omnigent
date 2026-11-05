import ProjectDescription
import ProjectDescriptionHelpers

let localPackages: [Package] = [
  // The app assembly: store-to-view-state adapters, sign-in and the connected screens.
  .package(path: "Packages/OmnigentAppUI"),
  .package(path: "Packages/OmnigentUI"),
  .package(path: "Packages/OmnigentAuthUI"),
  .package(path: "Packages/OmnigentWorkspaceUI"),
  // libghostty terminals; GhosttyKit.xcframework comes from scripts/fetch-ghostty.sh.
  .package(path: "Packages/OmnigentGhosttyKit"),
  .package(path: "Packages/OmnigentTerminalUI"),
  .package(path: "Packages/OmnigentTerminalStores"),
  .package(path: "Packages/OmnigentStores"),
  .package(path: "Packages/OmnigentServices"),
  .package(path: "Packages/OmnigentPlatform"),
  .package(path: "Packages/OmnigentTestSupport"),
  .package(path: "Packages/OmnigentCoreFFI"),
  .package(path: "Packages/OmnigentBrowser"),
  // Remote agent browser tabs (video from the agent's machine) and the shared native input.
  .package(path: "Packages/OmnigentRemoteBrowser"),
  .package(path: "Packages/OmnigentInput"),
  // The Chromium web layer client; only OmnigentBrowserChromium (Developer ID) uses it.
  .package(path: "Packages/OmnigentWebLayer"),
  // macOS only, so it is a dependency of the Mac apps and not of `appDependencies`. Its
  // `OmnigentDesktopUpdate` product (Sparkle) is linked by the Developer ID edition only.
  .package(path: "Packages/OmnigentDesktop"),
]

let appDependencies: [TargetDependency] = [
  .package(product: "OmnigentAppUI"),
  .package(product: "OmnigentUI"),
  .package(product: "OmnigentUIComponents"),
  .package(product: "OmnigentAuthUI"),
  .package(product: "OmnigentWorkspaceUI"),
  .package(product: "OmnigentTerminalUI"),
  .package(product: "OmnigentTerminalStores"),
  .package(product: "OmnigentStores"),
  .package(product: "OmnigentServices"),
  .package(product: "OmnigentCoreFFI"),
  // The in-app browser (WebKit) and its tabs; Chromium is the Developer ID edition's addition.
  .package(product: "OmnigentBrowser"),
  .package(product: "OmnigentAppBrowser"),
]

let unitTestDependencies: [TargetDependency] = [
  .package(product: "OmnigentStores"),
  .package(product: "OmnigentTestSupport"),
  .package(product: "OmnigentCoreFFI"),
]

/// The out-of-process Chromium web host, its CEF helpers and the embed step for the Developer ID
/// app; see Packages/OmnigentWebLayer/DESIGN.md.
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
  infoPlist: Omnigent.infoPlist(
    extra: [
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
    ].merging(Omnigent.phoneSupervisionInfoPlist) { _, new in new }),
  sources: ["Apps/Omnigent-iOS/Sources/**"],
  resources: [
    "Apps/Omnigent-iOS/Resources/**",
    Omnigent.appIcon,
  ],
  scripts: [Acknowledgements.script],
  dependencies: appDependencies,
  settings: Omnigent.appSettings(
    releaseBundleId: "ai.omnigent.ios",
    displayName: "Omnigent",
    extraBase: [
      // libghostty's simulator slice is arm64 only.
      "EXCLUDED_ARCHS[sdk=iphonesimulator*]": "x86_64",
      "TARGETED_DEVICE_FAMILY": "1,2",
      "SUPPORTS_MACCATALYST": "NO",
      "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
      "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
    ]
  )
)

let macInfoPlistShared: [String: Plist.Value] = [
  "LSApplicationCategoryType": "public.app-category.developer-tools",
  "NSHumanReadableCopyright": "Copyright Omnigent contributors.",
]

/// Sparkle's feed for the Developer ID edition (see RELEASE.md, "Auto-update"). `SUPublicEDKey`
/// stays empty until the release EdDSA key exists; Sparkle then refuses to start, and the app
/// reports it in Settings instead of updating unsigned.
let sparkleInfoPlist: [String: Plist.Value] = [
  "SUFeedURL": "https://omnigent.ai/_desktop/updates/native/mac/appcast.xml",
  "SUPublicEDKey": "",
  "SUEnableAutomaticChecks": true,
]

/// Developer ID edition: distributed outside the Mac App Store, no App Sandbox, hardened runtime
/// (Release), Chromium as the default engine. Chromium runs out of process in
/// `Contents/Helpers/Omnigent Web Host.app`, which carries CEF and its five helpers.
let macApp = Target.target(
  name: "OmnigentMac",
  destinations: [.mac],
  product: .app,
  productName: "Omnigent",
  bundleId: "ai.omnigent.mac",
  deploymentTargets: .macOS(Omnigent.deploymentVersion),
  infoPlist: Omnigent.infoPlist(
    extra: macInfoPlistShared.merging(sparkleInfoPlist) { _, new in new }),
  sources: ["Apps/Omnigent-macOS/Sources/**"],
  resources: [Omnigent.appIcon],
  entitlements: .file(path: "Apps/Omnigent-macOS/OmnigentMac.entitlements"),
  scripts: BrowserTargets.appScripts(macBrowser) + [Acknowledgements.script],
  dependencies: appDependencies + [
    .package(product: "OmnigentDesktop"),
    .package(product: "OmnigentBrowserChromium"),
    .package(product: "OmnigentDesktopUpdate"),
  ] + BrowserTargets.appDependencies(macBrowser),
  settings: Omnigent.appSettings(
    releaseBundleId: "ai.omnigent.mac",
    displayName: "Omnigent",
    extraBase: BrowserTargets.appSettings.merging(
      [
        "ENABLE_HARDENED_RUNTIME": "YES",
        "COMBINE_HIDPI_IMAGES": "YES",
        // Distinct per edition: both write their module to the shared products directory for
        // `@testable import`.
        "PRODUCT_MODULE_NAME": "OmnigentMac",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) OMNIGENT_CHROMIUM",
      ].merging(Omnigent.desktopDatabricksRedirect) { _, new in new }
    ) { _, new in new },
    debug: [
      "CODE_SIGN_IDENTITY": "-",
      // Ad-hoc signing cannot carry keychain-access-groups; see the file's comment.
      "CODE_SIGN_ENTITLEMENTS": "Apps/Omnigent-macOS/OmnigentMac-Debug.entitlements",
    ]
  )
)

/// Mac App Store edition: App Sandbox, no Chromium (it never links `OmnigentBrowserChromium` or
/// embeds the web host, and a build step fails if either appears), the system engine only, and
/// managed preferences from its own domain only.
let macAppStoreApp = Target.target(
  name: "OmnigentMacAppStore",
  destinations: [.mac],
  product: .app,
  productName: "OmnigentAppStore",
  bundleId: "ai.omnigent.mac.appstore",
  deploymentTargets: .macOS(Omnigent.deploymentVersion),
  infoPlist: Omnigent.infoPlist(
    extra: macInfoPlistShared.merging([
      "OmnigentManagedPreferencesOwnDomainOnly": true
    ]) { _, new in new }),
  sources: ["Apps/Omnigent-macOS/Sources/**"],
  resources: [Omnigent.appIcon],
  entitlements: .file(path: "Apps/Omnigent-macOS/OmnigentMacAppStore.entitlements"),
  scripts: [Acknowledgements.script] + BrowserTargets.appStoreGuardScripts(),
  dependencies: appDependencies + [
    .package(product: "OmnigentDesktop")
  ],
  settings: Omnigent.appSettings(
    releaseBundleId: "ai.omnigent.mac.appstore",
    displayName: "Omnigent",
    extraBase: [
      "ENABLE_HARDENED_RUNTIME": "YES",
      "COMBINE_HIDPI_IMAGES": "YES",
      "PRODUCT_MODULE_NAME": "OmnigentMacAppStore",
    ].merging(Omnigent.desktopDatabricksRedirect) { _, new in new },
    debug: [
      "CODE_SIGN_IDENTITY": "-",
      "CODE_SIGN_ENTITLEMENTS": "Apps/Omnigent-macOS/OmnigentMacAppStore-Debug.entitlements",
      "APP_DISPLAY_NAME": "Omnigent Lab (App Store)",
    ],
    // Debug keeps a distinct bundle name so both editions can share one build directory;
    // App Store archives ship as Omnigent.app.
    release: [
      "PRODUCT_NAME": "Omnigent"
    ]
  )
)

/// A unit test bundle hosted by `host`.
/// - Parameters:
///   - name: Target name.
///   - host: The app the tests run in.
///   - destinations: Platforms.
///   - deployment: Deployment target.
///   - sourceDirectory: Directory under `Tests/`; defaults to `name`. Both Mac editions share
///     `OmnigentMacTests`.
///   - extraDependencies: Packages the tests import beyond `unitTestDependencies`.
///   - settings: Extra build settings, such as the edition's compilation conditions.
/// - Returns: The test target.
func unitTests(
  name: String, host: String, destinations: Destinations, deployment: DeploymentTargets,
  sourceDirectory: String? = nil, extraDependencies: [TargetDependency] = [],
  settings: SettingsDictionary = [:]
) -> Target {
  .target(
    name: name,
    destinations: destinations,
    product: .unitTests,
    bundleId: "ai.omnigent.\(name.lowercased())",
    deploymentTargets: deployment,
    infoPlist: .default,
    sources: ["Tests/\(sourceDirectory ?? name)/**"],
    dependencies: [.target(name: host)] + unitTestDependencies + extraDependencies,
    settings: Omnigent.testSettings(extra: settings)
  )
}

/// A UI test bundle for `host`. `sourceDirectory` and `settings` as for `unitTests`.
func uiTests(
  name: String, host: String, destinations: Destinations, deployment: DeploymentTargets,
  sourceDirectory: String? = nil, settings: SettingsDictionary = [:]
) -> Target {
  .target(
    name: name,
    destinations: destinations,
    product: .uiTests,
    bundleId: "ai.omnigent.\(name.lowercased())",
    deploymentTargets: deployment,
    infoPlist: .default,
    sources: ["Tests/\(sourceDirectory ?? name)/**"],
    dependencies: [.target(name: host)],
    settings: Omnigent.testSettings(extra: settings)
  )
}

let macTestDependencies: [TargetDependency] = [
  .package(product: "OmnigentDesktop"),
  .package(product: "OmnigentBrowser"),
]
let developerIDTestSettings: SettingsDictionary = [
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) OMNIGENT_CHROMIUM"
]

/// Scheme for one Mac edition: build, test (unit + UI), run, archive.
func macScheme(_ name: String, tests: [TargetReference]) -> Scheme {
  .scheme(
    name: name,
    shared: true,
    buildAction: .buildAction(targets: [.target(name)]),
    testAction: .targets(
      tests.map { .testableTarget(target: $0) },
      configuration: "Debug"
    ),
    runAction: .runAction(configuration: "Debug", executable: .target(name)),
    archiveAction: .archiveAction(configuration: "Release"),
    profileAction: .profileAction(configuration: "Release", executable: .target(name)),
    analyzeAction: .analyzeAction(configuration: "Debug")
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
    macAppStoreApp,
    unitTests(
      name: "OmnigentMacTests", host: "OmnigentMac", destinations: [.mac],
      deployment: .macOS(Omnigent.deploymentVersion),
      extraDependencies: macTestDependencies, settings: developerIDTestSettings),
    uiTests(
      name: "OmnigentMacUITests", host: "OmnigentMac", destinations: [.mac],
      deployment: .macOS(Omnigent.deploymentVersion), settings: developerIDTestSettings),
    unitTests(
      name: "OmnigentMacAppStoreTests", host: "OmnigentMacAppStore", destinations: [.mac],
      deployment: .macOS(Omnigent.deploymentVersion), sourceDirectory: "OmnigentMacTests",
      extraDependencies: macTestDependencies,
      // Tuist derives the host path from the Release PRODUCT_NAME override ("Omnigent"); the
      // Debug host the tests run in is OmnigentAppStore.app.
      settings: [
        "TEST_HOST":
          "$(BUILT_PRODUCTS_DIR)/OmnigentAppStore.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/OmnigentAppStore"
      ]),
    uiTests(
      name: "OmnigentMacAppStoreUITests", host: "OmnigentMacAppStore", destinations: [.mac],
      deployment: .macOS(Omnigent.deploymentVersion), sourceDirectory: "OmnigentMacUITests"),
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
    macScheme("OmnigentMac", tests: ["OmnigentMacTests", "OmnigentMacUITests"]),
    macScheme(
      "OmnigentMacAppStore", tests: ["OmnigentMacAppStoreTests", "OmnigentMacAppStoreUITests"]),
  ]
)
