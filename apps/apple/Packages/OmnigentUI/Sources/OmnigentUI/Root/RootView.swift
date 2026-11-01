import OmnigentCoreFFI
import OmnigentStores
public import SwiftUI

/// Adaptive root: a split view of servers, the selected server and its sessions.
public struct RootView: View {
  enum SidebarItem: Hashable {
    case server
  }

  @Environment(ConnectionStore.self) private var store
  @State private var selection: SidebarItem? = .server
  // The analyzer does not see uses through the `$` projection.
  // swiftlint:disable:next unused_declaration
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .content

  private let sessionID: String?

  /// Creates the root view; it reads the ``ConnectionStore`` from the environment.
  /// - Parameter sessionID: The conversation to show, for example from an `omnigent://` link.
  public init(sessionID: String? = nil) {
    self.sessionID = sessionID
  }

  /// The split view.
  public var body: some View {
    NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
      List(selection: $selection) {
        Section("Servers") {
          NavigationLink(value: SidebarItem.server) {
            Label(serverTitle, systemImage: "server.rack")
          }
          .accessibilityIdentifier("sidebar.server")
        }
      }
      .navigationTitle("Omnigent")
      .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    } content: {
      Group {
        switch selection {
        case .server:
          ConnectView()
        case nil:
          ContentUnavailableView("Select a Server", systemImage: "server.rack")
        }
      }
      .navigationSplitViewColumnWidth(min: 320, ideal: 400)
    } detail: {
      if let sessionID {
        // Transcripts arrive with the session port; until then the routed session is named.
        ContentUnavailableView(
          "Session \(sessionID)",
          systemImage: "bubble.left.and.text.bubble.right",
          description: Text("Opened from a link. Transcripts are not available in this build yet.")
        )
        .accessibilityIdentifier("detail.session")
      } else {
        ContentUnavailableView(
          "No Session Selected",
          systemImage: "bubble.left.and.text.bubble.right",
          description: Text("Sessions appear here after you connect to a server.")
        )
      }
    }
  }

  private var serverTitle: String {
    if let discovery = store.discovery {
      return discovery.serverName ?? discovery.baseUrl
    }
    return "Local Server"
  }
}
