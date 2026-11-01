import ProjectDescription

/// Tuist building blocks for embedding Chromium (CEF) in a macOS app target.
///
/// Self-contained on purpose: `Packages/OmnigentBrowser/Example` symlinks this file into its own
/// helpers directory so the sample app exercises exactly what the product uses.
///
/// A CEF app on macOS needs, inside `<App>.app/Contents/Frameworks`:
/// - `Chromium Embedded Framework.framework` (from `scripts/fetch-cef.sh`, never linked; it is
///   loaded at runtime by the bridge and by `CefScopedLibraryLoader` in each helper)
/// - five helper apps: `<App> Helper`, `(GPU)`, `(Renderer)`, `(Plugin)`, `(Alerts)`
/// `NSApp` must implement `CefAppProtocol`; the bridge adds it to SwiftUI's application class at
/// start-up, so no `NSPrincipalClass` is needed.
public enum BrowserTargets {
  /// Must match `CEF_VERSION` in `scripts/fetch-cef.sh`; the embed step checks the staged stamp.
  public static let cefVersion = "156.0.15+gcf671c0+chromium-156.0.8078.80"

  /// Where the app's CEF pieces come from, relative to the Tuist project root.
  public struct Configuration: Sendable {
    /// Name of the app target that embeds the helpers.
    public var appTargetName: String
    /// The app's `PRODUCT_NAME`; helpers are named "<appProductName> Helper (…)".
    public var appProductName: String
    /// Base bundle id; helpers use "<base>.helper", "<base>.helper.gpu", …
    public var appBundleId: String
    /// macOS deployment target.
    public var deploymentTarget: String
    /// Path to the OmnigentBrowser package.
    public var browserPackagePath: String
    /// Path to the staged CEF output (`Vendor/cef/out`).
    public var cefOutPath: String
    /// Apple development team, if signing with one.
    public var developmentTeam: String?
    /// Extra Debug settings for helpers; should mirror the app's signing (ad-hoc by default).
    public var helperDebugSettings: SettingsDictionary
    /// Extra Release settings for helpers.
    public var helperReleaseSettings: SettingsDictionary

    /// Creates a configuration.
    public init(
      appTargetName: String,
      appProductName: String,
      appBundleId: String,
      deploymentTarget: String = "26.0",
      browserPackagePath: String = "Packages/OmnigentBrowser",
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
      self.cefOutPath = cefOutPath
      self.developmentTeam = developmentTeam
      self.helperDebugSettings = helperDebugSettings
      self.helperReleaseSettings = helperReleaseSettings
    }
  }

  /// One helper flavor. Entitlements follow Chrome's per-helper set, plus allow-jit on the base
  /// helper: under hardened runtime CEF 156 runs Blink/V8 there too and fails to reserve its
  /// V8 CodeRange without it (verified with the Example app).
  public struct HelperVariant: Sendable {
    /// Suffix appended to "<App> Helper", e.g. " (GPU)".
    public let nameSuffix: String
    /// Suffix for target names and bundle ids, e.g. "GPU".
    public let identifier: String
    /// Hardened-runtime exceptions for this helper.
    public let entitlements: [String: Plist.Value]
  }

  /// Every helper CEF expects next to the framework.
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

  /// The helper app targets. Add them to `Project.targets`.
  public static func helperTargets(_ configuration: Configuration) -> [Target] {
    helperVariants.map { helperTarget(configuration, variant: $0) }
  }

  /// Build-order dependencies the app target needs on its helpers.
  public static func appDependencies(_ configuration: Configuration) -> [TargetDependency] {
    helperVariants.map { .target(name: helperTargetName(configuration, variant: $0)) }
  }

  /// Post-build step that copies the framework and helpers into `Contents/Frameworks` and signs
  /// the framework. Add to the app target's `scripts`.
  public static func appScripts(_ configuration: Configuration) -> [TargetScript] {
    // Tuist pastes arguments into the phase unquoted, so quote them here.
    [
      .post(
        path: .relativeToRoot("\(configuration.browserPackagePath)/Scripts/embed-cef.sh"),
        arguments: [
          "\"${SRCROOT}/\(configuration.cefOutPath)\"", cefVersion,
          "\"\(configuration.appProductName) Helper\"",
        ],
        name: "Embed Chromium Embedded Framework",
        basedOnDependencyAnalysis: false
      )
    ]
  }

  /// Build settings the app target needs.
  ///
  /// `ENABLE_USER_SCRIPT_SANDBOXING = NO`: the embed step copies whole bundle trees out of
  /// `Vendor/` and `BUILT_PRODUCTS_DIR` and re-signs them, which the per-file script sandbox
  /// cannot express.
  public static let appSettings: SettingsDictionary = [
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "ENABLE_HARDENED_RUNTIME": "YES",
  ]

  /// Entitlement keys the app must NOT carry while it embeds stock CEF: Chromium's helper
  /// sandbox cannot nest inside App Sandbox. See Packages/OmnigentBrowser/README.md.
  public static let incompatibleAppEntitlements = ["com.apple.security.app-sandbox"]

  static func helperTargetName(_ configuration: Configuration, variant: HelperVariant) -> String {
    "\(configuration.appTargetName)Helper\(variant.identifier)"
  }

  private static func helperTarget(_ configuration: Configuration, variant: HelperVariant)
    -> Target
  {
    let productName = "\(configuration.appProductName) Helper\(variant.nameSuffix)"
    let bundleSuffix = variant.identifier.isEmpty ? "" : ".\(variant.identifier.lowercased())"
    return .target(
      name: helperTargetName(configuration, variant: variant),
      destinations: [.mac],
      product: .app,
      bundleId: "\(configuration.appBundleId).helper\(bundleSuffix)",
      deploymentTargets: .macOS(configuration.deploymentTarget),
      infoPlist: .dictionary(helperInfoPlist),
      sources: [.glob(.relativeToRoot("\(configuration.browserPackagePath)/Helper/*.cc"))],
      entitlements: .dictionary(variant.entitlements),
      scripts: [
        .pre(
          path: .relativeToRoot("\(configuration.browserPackagePath)/Scripts/check-cef.sh"),
          arguments: ["\"${SRCROOT}/\(configuration.cefOutPath)\"", cefVersion],
          name: "Check staged CEF",
          basedOnDependencyAnalysis: false
        )
      ],
      settings: .settings(
        base: helperSettings(configuration, productName: productName),
        configurations: [
          .debug(name: "Debug", settings: configuration.helperDebugSettings),
          .release(name: "Release", settings: configuration.helperReleaseSettings),
        ]
      )
    )
  }

  private static func helperSettings(_ configuration: Configuration, productName: String)
    -> SettingsDictionary
  {
    let cefOut = "$(SRCROOT)/\(configuration.cefOutPath)"
    // PRODUCT_NAME is set here, not via `productName:`, because Tuist rejects spaces there and
    // CEF requires the exact "<App> Helper (Variant)" names.
    var settings: SettingsDictionary = [
      "PRODUCT_NAME": .string(productName),
      "SYSTEM_HEADER_SEARCH_PATHS": .string(cefOut),
      "LIBRARY_SEARCH_PATHS": .string("\(cefOut)/lib"),
      "OTHER_LDFLAGS": ["-lcef_dll_wrapper", "-framework", "AppKit"],
      "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
      "GCC_PREPROCESSOR_DEFINITIONS": ["NDEBUG=1", "CEF_USE_SANDBOX=1"],
      "WARNING_CFLAGS": ["-Wall", "-Wextra", "-Wpedantic"],
      "GCC_TREAT_WARNINGS_AS_ERRORS": "YES",
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

  private static let helperInfoPlist: [String: Plist.Value] = [
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
  ]
}
