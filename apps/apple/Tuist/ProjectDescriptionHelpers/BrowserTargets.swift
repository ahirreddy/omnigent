import ProjectDescription

/// Tuist building blocks for the Chromium engine of a macOS app: the out-of-process web host
/// (`Omnigent Web Host.app`, see `WebHost/` and `Packages/OmnigentWebLayer/DESIGN.md`) with its
/// five CEF helpers, embedded in the app's `Contents/Helpers`.
///
/// Self-contained on purpose: `Packages/OmnigentWebLayer/Example` and
/// `Packages/OmnigentBrowser/Example` symlink this file so the samples build exactly what the
/// product ships.
///
/// Layout produced:
/// ```
/// <App>.app/Contents/Helpers/Omnigent Web Host.app/Contents/
///   MacOS/Omnigent Web Host                      the Chromium browser process
///   Frameworks/Chromium Embedded Framework.framework
///   Frameworks/Omnigent Web Host Helper.app      plus (GPU), (Renderer), (Plugin), (Alerts)
/// ```
/// The app itself never links or loads CEF. Only Developer ID builds may use these hooks; the
/// Mac App Store edition must not, and `appStoreGuardScripts` fails its build if CEF appears.
public enum BrowserTargets {
  /// Must match `CEF_VERSION` in `scripts/fetch-cef.sh`; the build checks the staged stamp.
  public static let cefVersion = "156.0.15+gcf671c0+chromium-156.0.8078.80"
  /// Product name of the host app and the base name of its helpers.
  public static let hostProductName = "Omnigent Web Host"

  /// Where the Chromium pieces come from, relative to the Tuist project root.
  public struct Configuration: Sendable {
    /// Name of the app target that embeds the host.
    public var appTargetName: String
    /// The app's `PRODUCT_NAME`. Kept for logs; the host's name is fixed.
    public var appProductName: String
    /// Base bundle id; the host uses "<base>.webhost", helpers "<base>.webhost.helper[.gpu]".
    public var appBundleId: String
    /// macOS deployment target.
    public var deploymentTarget: String
    /// Path to the OmnigentBrowser package. Unused by the host; kept for source compatibility.
    public var browserPackagePath: String
    /// Path to the web host sources (`WebHost`).
    public var webHostPath: String
    /// Path to the OmnigentWebLayer package, whose `OWLProtocol` sources the host compiles.
    public var webLayerPackagePath: String
    /// Path to the staged CEF output (`Vendor/cef/out`).
    public var cefOutPath: String
    /// Apple development team, if signing with one.
    public var developmentTeam: String?
    /// Extra Debug settings for the host and helpers; should mirror the app's signing.
    public var helperDebugSettings: SettingsDictionary
    /// Extra Release settings for the host and helpers.
    public var helperReleaseSettings: SettingsDictionary

    /// Creates a configuration.
    public init(
      appTargetName: String,
      appProductName: String,
      appBundleId: String,
      deploymentTarget: String = "26.0",
      browserPackagePath: String = "Packages/OmnigentBrowser",
      webHostPath: String = "WebHost",
      webLayerPackagePath: String = "Packages/OmnigentWebLayer",
      cefOutPath: String = "Vendor/cef/out",
      developmentTeam: String? = nil,
      helperDebugSettings: SettingsDictionary = ["CODE_SIGN_IDENTITY": "-"],
      helperReleaseSettings: SettingsDictionary = [:]
    ) {
      self.appTargetName = appTargetName
      self.appProductName = appProductName
      self.appBundleId = appBundleId
      self.deploymentTarget = deploymentTarget
      self.browserPackagePath = browserPackagePath
      self.webHostPath = webHostPath
      self.webLayerPackagePath = webLayerPackagePath
      self.cefOutPath = cefOutPath
      self.developmentTeam = developmentTeam
      self.helperDebugSettings = helperDebugSettings
      self.helperReleaseSettings = helperReleaseSettings
    }
  }

  /// One helper flavor. Entitlements follow Chrome's per-helper set, plus allow-jit on the base
  /// helper: under hardened runtime CEF 156 runs Blink/V8 there too and fails to reserve its
  /// V8 CodeRange without it.
  public struct HelperVariant: Sendable {
    /// Suffix appended to "<Host> Helper", e.g. " (GPU)".
    public let nameSuffix: String
    /// Suffix for target names and bundle ids, e.g. "GPU".
    public let identifier: String
    /// Hardened-runtime exceptions for this helper.
    public let entitlements: [String: Plist.Value]
  }

  /// Every helper CEF expects next to its framework.
  public static let helperVariants: [HelperVariant] = [
    HelperVariant(
      nameSuffix: "", identifier: "",
      entitlements: ["com.apple.security.cs.allow-jit": true]),
    HelperVariant(
      nameSuffix: " (GPU)", identifier: "GPU",
      entitlements: ["com.apple.security.cs.allow-jit": true]),
    HelperVariant(
      nameSuffix: " (Renderer)", identifier: "Renderer",
      entitlements: ["com.apple.security.cs.allow-jit": true]),
    HelperVariant(
      nameSuffix: " (Plugin)", identifier: "Plugin",
      entitlements: [
        "com.apple.security.cs.allow-unsigned-executable-memory": true,
        "com.apple.security.cs.disable-library-validation": true,
      ]),
    HelperVariant(nameSuffix: " (Alerts)", identifier: "Alerts", entitlements: [:]),
  ]

  /// The host app target and its helper targets. Add them to `Project.targets`.
  public static func helperTargets(_ configuration: Configuration) -> [Target] {
    [hostTarget(configuration)]
      + helperVariants.map { helperTarget(configuration, variant: $0) }
  }

  /// Build-order dependency the app target needs on the host.
  public static func appDependencies(_ configuration: Configuration) -> [TargetDependency] {
    [.target(name: hostTargetName(configuration))]
  }

  /// Post-build step that copies the host into the app's `Contents/Helpers`. Add to the app
  /// target's `scripts`.
  public static func appScripts(_ configuration: Configuration) -> [TargetScript] {
    // Tuist pastes arguments into the phase unquoted, so quote them here.
    [
      .post(
        path: .relativeToRoot("\(configuration.webHostPath)/Scripts/embed-web-host.sh"),
        arguments: ["\"\(hostProductName)\""],
        name: "Embed Omnigent Web Host",
        basedOnDependencyAnalysis: false
      )
    ]
  }

  /// Post-build step for builds that must never contain Chromium (the Mac App Store edition):
  /// fails when the host or CEF is anywhere in the product.
  public static func appStoreGuardScripts(webHostPath: String = "WebHost") -> [TargetScript] {
    [
      .post(
        path: .relativeToRoot("\(webHostPath)/Scripts/check-no-chromium.sh"),
        arguments: [],
        name: "Check that Chromium is absent",
        // Declared so the check runs with user script sandboxing on: the script itself and the
        // bundle it searches.
        inputPaths: [
          "$(SRCROOT)/\(webHostPath)/Scripts/check-no-chromium.sh",
          "$(TARGET_BUILD_DIR)/$(WRAPPER_NAME)",
        ],
        basedOnDependencyAnalysis: false
      )
    ]
  }

  /// Build settings the app target needs.
  ///
  /// `ENABLE_USER_SCRIPT_SANDBOXING = NO`: the embed step copies a whole signed bundle tree out
  /// of `BUILT_PRODUCTS_DIR`, which the per-file script sandbox cannot express.
  public static let appSettings: SettingsDictionary = [
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "ENABLE_HARDENED_RUNTIME": "YES",
  ]

  /// Entitlement keys the app must not carry while it ships the stock CEF host: Chromium's helper
  /// sandbox cannot nest inside App Sandbox.
  public static let incompatibleAppEntitlements = ["com.apple.security.app-sandbox"]

  static func hostTargetName(_ configuration: Configuration) -> String {
    "\(configuration.appTargetName)WebHost"
  }

  static func helperTargetName(_ configuration: Configuration, variant: HelperVariant) -> String {
    "\(configuration.appTargetName)WebHostHelper\(variant.identifier)"
  }

  private static func hostTarget(_ configuration: Configuration) -> Target {
    let host = configuration.webHostPath
    let protocolSources = "\(configuration.webLayerPackagePath)/Sources/OWLProtocol"
    var settings = cefSettings(configuration, productName: hostProductName)
    settings["HEADER_SEARCH_PATHS"] = .array([
      "$(SRCROOT)/\(protocolSources)/include", "$(SRCROOT)/\(host)/Sources",
    ])
    settings["OTHER_LDFLAGS"] = [
      "-lcef_dll_wrapper", "-lbsm", "-framework", "AppKit", "-framework", "QuartzCore",
      "-framework", "Metal", "-framework", "IOSurface",
    ]
    settings["CLANG_ENABLE_OBJC_ARC"] = "YES"
    settings["GCC_C_LANGUAGE_STANDARD"] = "c17"
    return .target(
      name: hostTargetName(configuration),
      destinations: [.mac],
      product: .app,
      bundleId: "\(configuration.appBundleId).webhost",
      deploymentTargets: .macOS(configuration.deploymentTarget),
      infoPlist: .dictionary(bundleInfoPlist),
      sources: [
        .glob(.relativeToRoot("\(host)/Sources/*.mm")),
        .glob(.relativeToRoot("\(protocolSources)/*.c")),
      ],
      // Pages ask for the camera, microphone and location through our prompts; under hardened
      // runtime the host also needs these entitlements, or macOS denies the device outright.
      entitlements: .dictionary(hostEntitlements),
      scripts: [
        checkScript(configuration),
        .post(
          path: .relativeToRoot("\(host)/Scripts/embed-cef.sh"),
          arguments: [
            "\"${SRCROOT}/\(configuration.cefOutPath)\"", cefVersion,
            "\"\(hostProductName) Helper\"",
          ],
          name: "Embed Chromium Embedded Framework and helpers",
          basedOnDependencyAnalysis: false
        ),
      ],
      dependencies: helperVariants.map {
        .target(name: helperTargetName(configuration, variant: $0))
      },
      settings: .settings(
        base: settings,
        configurations: [
          .debug(name: "Debug", settings: configuration.helperDebugSettings),
          .release(name: "Release", settings: configuration.helperReleaseSettings),
        ]
      )
    )
  }

  private static func helperTarget(_ configuration: Configuration, variant: HelperVariant)
    -> Target
  {
    let productName = "\(hostProductName) Helper\(variant.nameSuffix)"
    let bundleSuffix = variant.identifier.isEmpty ? "" : ".\(variant.identifier.lowercased())"
    var settings = cefSettings(configuration, productName: productName)
    settings["OTHER_LDFLAGS"] = ["-lcef_dll_wrapper", "-framework", "AppKit"]
    settings["GCC_PREPROCESSOR_DEFINITIONS"] = ["NDEBUG=1", "CEF_USE_SANDBOX=1"]
    return .target(
      name: helperTargetName(configuration, variant: variant),
      destinations: [.mac],
      product: .app,
      bundleId: "\(configuration.appBundleId).webhost.helper\(bundleSuffix)",
      deploymentTargets: .macOS(configuration.deploymentTarget),
      infoPlist: .dictionary(bundleInfoPlist),
      sources: [.glob(.relativeToRoot("\(configuration.webHostPath)/Helper/*.cc"))],
      entitlements: .dictionary(variant.entitlements),
      scripts: [checkScript(configuration)],
      settings: .settings(
        base: settings,
        configurations: [
          .debug(name: "Debug", settings: configuration.helperDebugSettings),
          .release(name: "Release", settings: configuration.helperReleaseSettings),
        ]
      )
    )
  }

  private static func checkScript(_ configuration: Configuration) -> TargetScript {
    .pre(
      path: .relativeToRoot("\(configuration.webHostPath)/Scripts/check-cef.sh"),
      arguments: ["\"${SRCROOT}/\(configuration.cefOutPath)\"", cefVersion],
      name: "Check staged CEF",
      basedOnDependencyAnalysis: false
    )
  }

  /// Settings shared by the host and its helpers. CEF headers come in through
  /// `SYSTEM_HEADER_SEARCH_PATHS` (-isystem), so the strict warning set applies only to our code.
  private static func cefSettings(_ configuration: Configuration, productName: String)
    -> SettingsDictionary
  {
    let cefOut = "$(SRCROOT)/\(configuration.cefOutPath)"
    // PRODUCT_NAME is set here, not via `productName:`, because Tuist rejects spaces there and
    // CEF requires the exact "<Host> Helper (Variant)" names.
    var settings: SettingsDictionary = [
      "PRODUCT_NAME": .string(productName),
      "SYSTEM_HEADER_SEARCH_PATHS": .string(cefOut),
      "LIBRARY_SEARCH_PATHS": .string("\(cefOut)/lib"),
      "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
      // libcef_dll_wrapper is built Release; CEF base headers change layout with DCHECKs.
      "GCC_PREPROCESSOR_DEFINITIONS": ["NDEBUG=1"],
      "WARNING_CFLAGS": ["-Wall", "-Wextra", "-Wpedantic"],
      "GCC_TREAT_WARNINGS_AS_ERRORS": "YES",
      "RUN_CLANG_STATIC_ANALYZER": "YES",
      "ENABLE_HARDENED_RUNTIME": "YES",
      "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
      "SKIP_INSTALL": "YES",
      "DEAD_CODE_STRIPPING": "YES",
      "ASSETCATALOG_COMPILER_APPICON_NAME": "",
    ]
    if let team = configuration.developmentTeam {
      settings["DEVELOPMENT_TEAM"] = .string(team)
    }
    return settings
  }

  /// Hardened-runtime device access for the host, which captures on behalf of web pages.
  static let hostEntitlements: [String: Plist.Value] = [
    "com.apple.security.device.camera": true,
    "com.apple.security.device.audio-input": true,
    "com.apple.security.personal-information.location": true,
  ]

  private static let bundleInfoPlist: [String: Plist.Value] = Omnigent.webDeviceUsage.merging([
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "$(PRODUCT_NAME)",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)",
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "$(PRODUCT_NAME)",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LSEnvironment": ["MallocNanoZone": "0"],
    "LSFileQuarantineEnabled": true,
    "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
    "LSUIElement": "1",
    "NSSupportsAutomaticGraphicsSwitching": true,
  ]) { _, new in new }
}
