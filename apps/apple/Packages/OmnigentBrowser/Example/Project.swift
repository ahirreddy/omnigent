import ProjectDescription
import ProjectDescriptionHelpers

let browser = BrowserTargets.Configuration(
  appTargetName: "BrowserExample",
  appProductName: "BrowserExample",
  appBundleId: "ai.omnigent.browser-example",
  browserPackagePath: "..",
  cefOutPath: "../../../Vendor/cef/out"
)

let app = Target.target(
  name: "BrowserExample",
  destinations: [.mac],
  product: .app,
  bundleId: "ai.omnigent.browser-example",
  deploymentTargets: .macOS("26.0"),
  infoPlist: .default,
  sources: ["Sources/**"],
  scripts: BrowserTargets.appScripts(browser),
  dependencies: [.package(product: "OmnigentBrowser")] + BrowserTargets.appDependencies(browser),
  settings: .settings(
    base: BrowserTargets.appSettings.merging([
      "SWIFT_VERSION": "6.0",
      "SWIFT_STRICT_CONCURRENCY": "complete",
      "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
      "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
      "SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY": "YES",
      "SWIFT_UPCOMING_FEATURE_INTERNAL_IMPORTS_BY_DEFAULT": "YES",
      "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
    ]) { _, new in new },
    configurations: [
      .debug(name: "Debug", settings: ["CODE_SIGN_IDENTITY": "-"]),
      .release(name: "Release", settings: ["CODE_SIGN_IDENTITY": "-"]),
    ]
  )
)

let project = Project(
  name: "BrowserExample",
  packages: [.package(path: "..")],
  settings: .settings(base: [
    "MACOSX_DEPLOYMENT_TARGET": "26.0",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
  ]),
  targets: [app] + BrowserTargets.helperTargets(browser)
)
