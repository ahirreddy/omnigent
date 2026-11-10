public import Foundation
public import OmnigentCoreFFI
public import OmnigentRemoteBrowser
import OmnigentStores
import OmnigentUIComponents
import SwiftUI
import os

/// Which remote browser connector this build uses. Remote browser tabs are off until the server
/// advertises remote browsers; until then they are turned on with a user default (also a launch
/// argument such as `-OmnigentRemoteBrowser YES`):
/// - `OmnigentRemoteBrowser`: the core's driver and REST calls against the connected server.
/// - `OmnigentRemoteBrowserFixture`: the in-process fixture host that plays recorded video, for
///   development, screenshots and UI tests.
public enum RemoteBrowserAvailability {
  /// The user default that turns on remote browser tabs against the server.
  public static let enabledDefault = "OmnigentRemoteBrowser"
  /// The user default that turns on the fixture host.
  public static let fixtureDefault = "OmnigentRemoteBrowserFixture"

  /// The connector for a connection, or `nil` when remote browser tabs are off.
  /// - Parameters:
  ///   - core: The connection's core.
  ///   - defaults: Where the switches are read.
  /// - Returns: The connector.
  public static func connector(core: ClientCore?, defaults: UserDefaults = .standard)
    -> (any RemoteBrowserConnecting)?
  {
    if defaults.bool(forKey: fixtureDefault) { return FixtureRemoteBrowser.shared }
    guard defaults.bool(forKey: enabledDefault), let core else { return nil }
    return CoreRemoteBrowserConnector(core: core)
  }
}

extension ServerSession {
  /// Reads the remote browser profiles of a session's machine for the new-tab menus.
  /// - Parameter sessionID: The session, or `nil` for none.
  func loadRemoteBrowserProfiles(_ sessionID: String?) async {
    guard let sessionID, let remoteBrowsers else { return }
    await remoteBrowsers.loadProfiles(sessionID: sessionID)
  }
}

/// A remote browser tab: its live store once the session's header gives the attach mode and
/// host, or why there is none.
struct RemoteBrowserTabContainer: View {
  let session: ServerSession
  let tab: AppTab
  let sessionID: String
  let tabID: String
  /// Opens a new remote tab at a URL in place of this one.
  let reopen: @MainActor (String, RemoteBrowserTabRecord) -> Void
  /// Shows the session list, from the tab's page menu where it hides the navigation bar.
  let showSessions: @MainActor () -> Void
  /// The tab overview button for the tab's own toolbar (iPhone).
  let tabsButton: @MainActor () -> TabSwitcherButton

  @State private var store: RemoteBrowserStore?

  private var header: OmnigentCoreFFI.SessionHeader? {
    session.connection.openConversation(sessionID)?.header
  }

  var body: some View {
    Group {
      if session.remoteBrowsers == nil {
        ContentUnavailableView(
          "Remote Browser Unavailable", systemImage: TabKind.remoteBrowser.systemImage,
          description: Text("Remote browser tabs are turned off in this build."))
      } else if let store {
        RemoteBrowserTabView(
          store: store,
          reopen: { url in reopen(url, RemoteBrowserTabRecord(url: url, profile: store.profile)) },
          showSessions: showSessions, tabsButton: tabsButton)
      } else {
        ProgressView("Opening the remote browser\u{2026}")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    // The header's arrival, not its level: a header may report no level at all.
    .onChange(of: header != nil, initial: true) { attach() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("remote-browser-tab")
  }

  /// Attaches once the session's header is known: owners attach for control, others to view.
  private func attach() {
    guard store == nil, let remote = session.remoteBrowsers, let header else { return }
    let store = remote.store(sessionID: sessionID, tabID: tabID, record: Self.record(tab))
    remote.attach(
      store, mode: remoteBrowserMode(permissionLevel: header.permissionLevel),
      hostID: header.settings?.hostId)
    self.store = store
  }

  /// The tab's saved record, when it has a readable one.
  static func record(_ tab: AppTab) -> RemoteBrowserTabRecord? {
    guard let data = tab.browserState else { return nil }
    do {
      return try RemoteBrowserTabRecord(decoding: data)
    } catch {
      // A record from a newer build: show the tab without its last page.
      Logger(subsystem: "ai.omnigent.remote-browser", category: "tabs")
        .error("Unreadable remote tab record: \(String(describing: error), privacy: .public)")
      return nil
    }
  }
}
