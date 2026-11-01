import ProjectDescription

/// A gallery app for OmnigentTerminalUI on macOS, iPhone and iPad. It renders fake connections
/// (and, with `-attach`, a live local-server terminal) for manual testing and screenshots.
let strictSettings: SettingsDictionary = [
  "SWIFT_VERSION": "6.0",
  "SWIFT_STRICT_CONCURRENCY": "complete",
  "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
  "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
  "SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY": "YES",
  "SWIFT_UPCOMING_FEATURE_INTERNAL_IMPORTS_BY_DEFAULT": "YES",
  "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
  "CODE_SIGN_IDENTITY": "-",
  "CODE_SIGNING_REQUIRED": "NO",
]

let app = Target.target(
  name: "TerminalGallery",
  destinations: [.mac, .iPhone, .iPad],
  product: .app,
  bundleId: "ai.omnigent.terminal-gallery",
  deploymentTargets: .multiplatform(iOS: "26.0", macOS: "26.0"),
  infoPlist: .extendingDefault(with: [
    "UILaunchScreen": .dictionary([:]),
    "NSAppTransportSecurity": .dictionary(["NSAllowsLocalNetworking": .boolean(true)]),
    "UISupportedInterfaceOrientations": .array([
      .string("UIInterfaceOrientationPortrait"),
      .string("UIInterfaceOrientationLandscapeLeft"),
      .string("UIInterfaceOrientationLandscapeRight"),
    ]),
  ]),
  sources: ["Sources/**"],
  dependencies: [.package(product: "OmnigentTerminalUI")],
  settings: .settings(base: strictSettings)
)

let project = Project(
  name: "TerminalGallery",
  packages: [.package(path: "..")],
  targets: [app]
)
