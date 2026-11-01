import ProjectDescription

/// Shared build configuration for the Omnigent Apple project.
public enum Omnigent {
  /// Apple Developer team that signs Release builds.
  public static let developmentTeam = "8RMX4WU6F8"
  /// Minimum iOS and macOS version.
  public static let deploymentVersion = "26.0"
  /// `CFBundleShortVersionString` for every app.
  public static let marketingVersion = "0.1.0"
  /// `CFBundleVersion` for both apps.
  public static let buildNumber = "1"

  /// Icon Composer source shared with the web shell's iOS app.
  public static let appIcon: ResourceFileElement = .glob(
    pattern: "../../web/platform-assets/AppIcon.icon")

  /// Strictness applied to every target. Mirrors `strictSwiftSettings` in the local packages.
  public static let strictBase: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
    "GCC_TREAT_WARNINGS_AS_ERRORS": "YES",
    "SWIFT_STRICT_MEMORY_SAFETY": "YES",
    "SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY": "YES",
    "SWIFT_UPCOMING_FEATURE_INTERNAL_IMPORTS_BY_DEFAULT": "YES",
    "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
    "SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES": "YES",
    "SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "DEAD_CODE_STRIPPING": "YES",
    "RUN_CLANG_STATIC_ANALYZER": "YES",
    "CLANG_STATIC_ANALYZER_MODE_ON_ANALYZE": "deep",
  ]

  /// Project-level settings: strictness, deployment targets, versions and per-configuration tuning.
  /// - Returns: The settings for the `Omnigent` project.
  public static func projectSettings() -> Settings {
    .settings(
      base: strictBase.merging([
        "IPHONEOS_DEPLOYMENT_TARGET": .string(deploymentVersion),
        "MACOSX_DEPLOYMENT_TARGET": .string(deploymentVersion),
        "DEVELOPMENT_TEAM": .string(developmentTeam),
        "MARKETING_VERSION": .string(marketingVersion),
        "CURRENT_PROJECT_VERSION": .string(buildNumber),
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
      ]) { _, new in new },
      configurations: [
        .debug(
          name: "Debug",
          settings: [
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            "ONLY_ACTIVE_ARCH": "YES",
            "CLANG_STATIC_ANALYZER_MODE": "deep",
          ]),
        .release(
          name: "Release",
          settings: [
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
            "SWIFT_COMPILATION_MODE": "wholemodule",
          ]),
      ],
      defaultSettings: .recommended
    )
  }

  /// App target settings. Release ships `releaseBundleId`; Debug installs side by side as the
  /// ".lab" build.
  /// - Parameters:
  ///   - releaseBundleId: Bundle identifier of the Release build.
  ///   - displayName: User-visible app name; Debug appends " Lab".
  ///   - extraBase: Additional settings for every configuration.
  ///   - debug: Additional Debug-only settings.
  ///   - release: Additional Release-only settings.
  /// - Returns: The target settings.
  public static func appSettings(
    releaseBundleId: String,
    displayName: String,
    extraBase: SettingsDictionary = [:],
    debug: SettingsDictionary = [:],
    release: SettingsDictionary = [:]
  ) -> Settings {
    .settings(
      base: [
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "APP_DISPLAY_NAME": .string(displayName),
        "CODE_SIGN_STYLE": "Automatic",
        "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        // The public Databricks OAuth client (web/ios/docs/databricks-oauth.md).
        "DATABRICKS_OAUTH_CLIENT_ID": "omnigent",
        "DATABRICKS_OAUTH_REDIRECT_URL": "https://login.databricks.com/mobile-redirect",
      ].merging(extraBase) { _, new in new },
      configurations: [
        .debug(
          name: "Debug",
          settings: [
            "PRODUCT_BUNDLE_IDENTIFIER": .string("\(releaseBundleId).lab"),
            "APP_DISPLAY_NAME": .string("\(displayName) Lab"),
          ].merging(debug) { _, new in new }),
        .release(
          name: "Release",
          settings: [
            "PRODUCT_BUNDLE_IDENTIFIER": .string(releaseBundleId)
          ].merging(release) { _, new in new }),
      ]
    )
  }

  /// Settings for unit and UI test bundles.
  /// - Parameter extra: Additional settings, such as compilation conditions.
  /// - Returns: The target settings.
  public static func testSettings(extra: SettingsDictionary = [:]) -> Settings {
    .settings(base: ["CODE_SIGN_STYLE": "Automatic"].merging(extra) { _, new in new })
  }

  /// Usage strings for web pages that ask for the camera, microphone or location through the
  /// browser's permission prompt. macOS refuses the device without them even after the user
  /// allows it in the page prompt.
  public static let webDeviceUsage: [String: Plist.Value] = [
    "NSCameraUsageDescription": "Web pages you open in Omnigent can use the camera when you allow it.",
    "NSMicrophoneUsageDescription":
      "Web pages you open in Omnigent can use the microphone when you allow it.",
    "NSLocationUsageDescription":
      "Web pages you open in Omnigent can use your location when you allow it.",
    "NSLocationWhenInUseUsageDescription":
      "Web pages you open in Omnigent can use your location when you allow it.",
  ]

  /// The Databricks workspace OAuth client (public configuration, as in `web/ios`; see
  /// `web/ios/docs/databricks-oauth.md`). Override with `DATABRICKS_OAUTH_CLIENT_ID` and
  /// `DATABRICKS_OAUTH_REDIRECT_URL` build settings.
  public static let databricksOAuth: [String: Plist.Value] = [
    "DatabricksOAuthClientID": "$(DATABRICKS_OAUTH_CLIENT_ID)",
    "DatabricksOAuthRedirectURL": "$(DATABRICKS_OAUTH_REDIRECT_URL)",
  ]

  /// Info.plist shared by both apps: deep-link scheme, local-network ATS exception, usage
  /// strings and the Databricks OAuth client.
  /// - Parameter extra: Platform-specific keys, which win over the shared ones.
  /// - Returns: The Info.plist definition.
  public static func infoPlist(extra: [String: Plist.Value]) -> InfoPlist {
    let shared: [String: Plist.Value] = [
      "CFBundleDisplayName": "$(APP_DISPLAY_NAME)",
      "CFBundleShortVersionString": "$(MARKETING_VERSION)",
      "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
      "CFBundleURLTypes": [
        [
          "CFBundleURLName": "$(PRODUCT_BUNDLE_IDENTIFIER).deeplink",
          "CFBundleURLSchemes": ["omnigent"],
        ]
      ],
      "NSAppTransportSecurity": [
        "NSAllowsLocalNetworking": true
      ],
      "NSLocalNetworkUsageDescription":
        "Omnigent connects to Omnigent servers running on your computer or local network.",
      "ITSAppUsesNonExemptEncryption": false,
    ].merging(webDeviceUsage) { _, new in new }.merging(databricksOAuth) { _, new in new }
    return .extendingDefault(with: shared.merging(extra) { _, new in new })
  }
}
