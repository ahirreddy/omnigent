import AppKit
import OmnigentDesktop
import SwiftUI

/// `--screenshots=<dir>`: runs a real local server from the source checkout in an isolated
/// directory (`<dir>/lsm-shot`), captures the local-server surfaces as PNGs, stops it and quits.
enum Screenshots {
  private static var started = false

  static var directory: URL? {
    CommandLine.arguments.first { $0.hasPrefix("--screenshots=") }
      .map {
        URL(filePath: String($0.dropFirst("--screenshots=".count)), directoryHint: .isDirectory)
      }
  }

  /// A controller with private defaults, records and data directory, or `nil` outside
  /// `--screenshots`.
  static func isolatedDesktop() -> DesktopController? {
    guard let directory else { return nil }
    let root = directory.appending(path: "lsm-shot", directoryHint: .isDirectory)
    let suite = "ai.omnigent.desktop.example.screenshots"
    guard let defaults = UserDefaults(suiteName: suite) else {
      print("screenshots: no defaults suite \(suite)")
      return nil
    }
    defaults.removePersistentDomain(forName: suite)
    var dependencies = LocalServerManager.Dependencies.live(
      records: LocalServerRecordStore(directory: root.appending(path: "records")),
      developmentCheckout: LocalServerManager.sourceCheckout)
    dependencies.environment["OMNIGENT_CONFIG_HOME"] = root.appending(path: "config").path
    dependencies.environment["OMNIGENT_SKIP_WEB_UI"] = "true"
    let desktop = DesktopController(
      defaults: defaults, managedDomains: [], localServerCapability: .available,
      localServerDependencies: dependencies)
    desktop.localServerPreferences.dataDirectory = root.appending(path: "data").path
    desktop.confirmOpenLocalServer = { _ in false }
    return desktop
  }

  static func runIfRequested(desktop: DesktopController) async {
    guard !started, let directory else { return }
    started = true
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate()
    let manager = desktop.localServer
    await manager.startServer(trigger: .user)
    print("server: \(manager.server.summary)")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try await capture(
        LocalServerSettingsView(desktop: desktop).frame(width: 540, height: 860),
        title: "Local Server", to: directory.appending(path: "lsm-settings.png"))
      try await capture(
        LocalServerLogsView(manager: manager).frame(width: 900, height: 520),
        title: "Server Logs", to: directory.appending(path: "lsm-logs.png"))
      try await capture(
        OmnigentMenuBarContent(desktop: desktop, sessions: ExampleSessions.source)
          .fixedSize(),
        title: nil, to: directory.appending(path: "lsm-menubar.png"))
      try await captureAppStoreEdition(to: directory.appending(path: "lsm-settings-appstore.png"))
    } catch {
      print("screenshots failed: \(error)")
    }
    await manager.stopServer()
    print("after stop: \(manager.server.summary)")
    NSApplication.shared.terminate(nil)
  }

  private static func captureAppStoreEdition(to url: URL) async throws {
    guard let defaults = UserDefaults(suiteName: "ai.omnigent.desktop.example.appstore") else {
      return
    }
    let desktop = DesktopController(
      defaults: defaults, managedDomains: [], localServerCapability: .unavailable(.appSandbox))
    try await capture(
      LocalServerSettingsView(desktop: desktop).frame(width: 540, height: 260),
      title: "Local Server (Mac App Store edition)", to: url)
  }

  /// Shows `view` in a window, lets it lay out, and writes the window (with its title bar when
  /// `title` is set) as a PNG.
  @MainActor
  private static func capture(_ view: some View, title: String?, to url: URL) async throws {
    let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
    host.setFrameSize(host.fittingSize)
    let style: NSWindow.StyleMask = title == nil ? [.borderless] : [.titled, .closable]
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: style,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = title ?? ""
    window.contentView = host
    window.backgroundColor = .windowBackgroundColor
    window.center()
    window.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .seconds(2))
    // The frame view includes the title bar. `superview` is `unowned(unsafe)`; the window
    // holds it for the duration of this function.
    let frameView = unsafe host.superview
    let target: NSView = title == nil ? host : frameView ?? host
    guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
      throw CaptureError(description: "no bitmap for \(url.lastPathComponent)")
    }
    target.cacheDisplay(in: target.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw CaptureError(description: "no PNG for \(url.lastPathComponent)")
    }
    try png.write(to: url)
    print("wrote \(url.path)")
    window.close()
  }

  struct CaptureError: Error {
    let description: String
  }
}
