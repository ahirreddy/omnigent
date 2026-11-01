public import AppKit

/// App delegate for `@NSApplicationDelegateAdaptor`. Owns the `DesktopController`, installs the
/// notification delegate before launch finishes, and receives `omnigent://` URLs.
///
/// Implementing `application(_:open:)` makes AppKit hand URLs here instead of SwiftUI opening a
/// new window for each one, so the router decides which window shows the link.
public final class OmnigentDesktopAppDelegate: NSObject, NSApplicationDelegate {
  /// The shell services.
  public let desktop = DesktopController()

  /// Installs the notification delegate so a notification that launched the app is delivered.
  /// - Parameter notification: The launch notification.
  public func applicationWillFinishLaunching(_ notification: Notification) {
    do {
      try desktop.notifications.installAsDelegate()
    } catch {
      desktop.onIssue(.notificationFailed(error))
    }
  }

  /// Routes opened `omnigent://` URLs.
  /// - Parameters:
  ///   - application: The app.
  ///   - urls: The URLs.
  public func application(_ application: NSApplication, open urls: [URL]) {
    desktop.router.open(urls)
  }
}
