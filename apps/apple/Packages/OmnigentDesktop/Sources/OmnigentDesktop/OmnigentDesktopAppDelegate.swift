public import AppKit

/// App delegate for `@NSApplicationDelegateAdaptor`. Owns the `DesktopController`, installs the
/// notification delegate before launch finishes, and receives `omnigent://` URLs.
///
/// Implementing `application(_:open:)` makes AppKit hand URLs here instead of SwiftUI opening a
/// new window for each one, so the router decides which window shows the link.
///
/// At launch it hands the local server manager its chance to reuse or start a server, and at
/// quit it stops the server and host the app started (never ones it adopted), delaying
/// termination until they exit.
///
/// Apps may subclass it to bind `desktop` to their own services before launch finishes; call
/// `super` from overrides. A subclass that needs a configured controller (for example the App
/// Store edition's `.unavailable` local-server capability) overrides `init()` and calls
/// `init(desktop:)`.
open class OmnigentDesktopAppDelegate: NSObject, NSApplicationDelegate {
  /// The shell services.
  public let desktop: DesktopController

  /// Creates the delegate with `desktop`.
  /// - Parameter desktop: The shell services.
  public init(desktop: DesktopController) {
    self.desktop = desktop
    super.init()
  }

  /// Creates the delegate with a default `DesktopController`.
  override public convenience init() {
    self.init(desktop: DesktopController())
  }

  /// Installs the notification delegate so a notification that launched the app is delivered.
  /// - Parameter notification: The launch notification.
  open func applicationWillFinishLaunching(_ notification: Notification) {
    do {
      try desktop.notifications.installAsDelegate()
    } catch {
      desktop.onIssue(.notificationFailed(error))
    }
  }

  /// Lets the local server manager reuse a running server or start one (Settings > Local
  /// Server > Start when Omnigent opens).
  /// - Parameter notification: The launch notification.
  open func applicationDidFinishLaunching(_ notification: Notification) {
    let localServer = desktop.localServer
    Task { await localServer.launch() }
  }

  /// Delays quitting until the server and host the app started have stopped. Adopted processes
  /// keep running.
  /// - Parameter sender: The app.
  /// - Returns: `.terminateLater` while processes stop, else `.terminateNow`.
  open func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let localServer = desktop.localServer
    guard localServer.hasProcessesToStopOnQuit else { return .terminateNow }
    Task {
      await localServer.stopOwnedProcesses()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Routes opened `omnigent://` URLs.
  /// - Parameters:
  ///   - application: The app.
  ///   - urls: The URLs.
  open func application(_ application: NSApplication, open urls: [URL]) {
    desktop.router.open(urls)
  }
}
