import OSLog
import OmnigentBrowser
import OmnigentDesktop
import SwiftUI

/// The Browser window: one per server, showing the server's page with the preferred engine in
/// that server's persistent profile. Agent browser actions are not wired yet.
enum BrowserWindow {
  /// The scene identifier for `openWindow(id:value:)`.
  static let id = "browser"
}

/// Window group keyed by server URL, so opening the browser for a server that already has one
/// brings it to the front.
struct BrowserWindowScene: Scene {
  let services: AppServices

  var body: some Scene {
    WindowGroup("Browser", id: BrowserWindow.id, for: URL.self) { $serverURL in
      BrowserWindowRoot(serverURL: serverURL, services: services)
    }
    .defaultSize(width: 1100, height: 760)
    // `omnigent://` URLs go to `DesktopRouter`, never to a new browser window.
    .handlesExternalEvents(matching: [])
  }
}

/// View > Show Browser (Option-Command-B) for the key server window's server.
struct BrowserCommands: Commands {
  @FocusedValue(\.serverWindow) private var focused
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Button("Show Browser") {
        guard let serverURL = focused?.id.serverURL else { return }
        openWindow(id: BrowserWindow.id, value: serverURL)
      }
      .keyboardShortcut("b", modifiers: [.command, .option])
      .disabled(focused?.id.serverURL == nil)
    }
  }
}

struct BrowserWindowRoot: View {
  let serverURL: URL?
  let services: AppServices

  @State private var controller: BrowserController?
  @State private var failure: String?

  var body: some View {
    content
      .frame(minWidth: 640, minHeight: 420)
      .navigationTitle(title)
      .task(id: serverURL) { open() }
      .onDisappear(perform: close)
  }

  @ViewBuilder private var content: some View {
    if let controller {
      BrowserView(controller: controller)
    } else if let failure {
      ContentUnavailableView(
        "Cannot Open the Browser", systemImage: "exclamationmark.triangle",
        description: Text(failure))
    } else if serverURL == nil {
      ContentUnavailableView(
        "No Server", systemImage: "globe",
        description: Text("Open the browser from a window that is connected to a server."))
    } else {
      ProgressView()
    }
  }

  private var title: String {
    guard let host = serverURL?.host(percentEncoded: false) else { return "Browser" }
    return "Browser \u{2014} \(host)"
  }

  private func open() {
    close()
    guard let serverURL else { return }
    do {
      controller = try services.makeBrowserController(serverURL: serverURL)
      failure = nil
    } catch {
      failure = "\(serverURL.absoluteString) is not a server URL (\(error))."
      services.logger.error(
        "Browser window rejected \(serverURL.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }

  private func close() {
    controller?.close()
    controller = nil
  }
}
