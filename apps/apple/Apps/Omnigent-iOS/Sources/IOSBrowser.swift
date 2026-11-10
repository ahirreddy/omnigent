import Foundation
import OSLog
import OmnigentAppBrowser
import OmnigentBrowser
import UIKit

/// The in-app browser on iPhone and iPad: WebKit only (App Store rules), one environment for
/// every scene, so a page keeps its state when its tab moves between iPad windows. iOS runs no
/// agent browser; agents' pages are remote browser tabs instead.
@MainActor
enum IOSBrowser {
  private static let logger = Logger(subsystem: "ai.omnigent.ios", category: "browser")

  /// Browser tabs across scenes. Pages install their own shortcuts for iPad keyboards.
  static let tabs: BrowserTabHost = {
    let provider = DefaultBrowserEngineProvider()
    let preferences = BrowserPreferences(defaults: .standard, provider: provider)
    let environment = BrowserEnvironment(
      directory: BrowserEnvironment.standardDirectory, provider: provider,
      preferences: preferences)
    // iOS may end a backgrounded app without notice: write history and closed tabs now.
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { flush(environment) }
    }
    return BrowserTabHost(
      environment: environment, agent: nil, logger: logger, keyboardShortcuts: true)
  }()

  private static func flush(_ environment: BrowserEnvironment) {
    do {
      try environment.flush()
    } catch {
      logger.error(
        "Saving browser data failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
