import ProjectDescription
import ProjectDescriptionHelpers

let webHost = BrowserTargets.Configuration(
  appTargetName: "WebLayerExample",
  appProductName: "WebLayerExample",
  appBundleId: "ai.omnigent.weblayer-example",
  webHostPath: "../../../WebHost",
  webLayerPackagePath: "..",
  cefOutPath: "../../../Vendor/cef/out"
)

let app = Target.target(
  name: "WebLayerExample",
  destinations: [.mac],
  product: .app,
  bundleId: "ai.omnigent.weblayer-example",
  deploymentTargets: .macOS("26.0"),
  infoPlist: .extendingDefault(with: ["NSPrincipalClass": "NSApplication"]),
  sources: ["Sources/**"],
  scripts: BrowserTargets.appScripts(webHost),
  dependencies: [
    .package(product: "OmnigentWebLayer"), .package(product: "OmnigentBrowser"),
    .package(product: "OmnigentBrowserChromium"),
  ] + BrowserTargets.appDependencies(webHost),
  settings: .settings(
    base: BrowserTargets.appSettings.merging([
      "SWIFT_VERSION": "6.0",
      "SWIFT_STRICT_CONCURRENCY": "complete",
      "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
      "SWIFT_STRICT_MEMORY_SAFETY": "YES",
      "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
      "SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY": "YES",
      "SWIFT_UPCOMING_FEATURE_INTERNAL_IMPORTS_BY_DEFAULT": "YES",
      "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
      "SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES": "YES",
      "SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT": "YES",
    ]) { _, new in new },
    configurations: [
      .debug(name: "Debug", settings: ["CODE_SIGN_IDENTITY": "-"]),
      .release(name: "Release", settings: ["CODE_SIGN_IDENTITY": "-"]),
    ]
  )
)

let project = Project(
  name: "WebLayerExample",
  packages: [.package(path: ".."), .package(path: "../../OmnigentBrowser")],
  settings: .settings(base: [
    "MACOSX_DEPLOYMENT_TARGET": "26.0",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
  ]),
  targets: [app] + BrowserTargets.helperTargets(webHost)
)
