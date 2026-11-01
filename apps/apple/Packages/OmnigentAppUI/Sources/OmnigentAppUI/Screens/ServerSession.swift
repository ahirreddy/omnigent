public import Foundation
public import Observation
import OmnigentCoreFFI
import OmnigentServices
public import OmnigentStores
public import OmnigentTerminalStores
public import OmnigentWorkspaceUI

/// One server connection on screen: the core-backed ``ConnectionStore`` and the
/// ``SignInController`` that signs it in. Each window (Mac) or scene (iOS) owns one.
@Observable
public final class ServerSession {
  /// The connection and its stores.
  public let connection: ConnectionStore
  /// Sign-in for `connection`.
  public let signIn: SignInController
  /// Terminal surfaces of open sessions, kept while the session is open so the screen and
  /// scrollback survive switching between Chat and Terminal.
  public private(set) var terminalStores: [String: TerminalStore] = [:]
  /// Workspace browsers (Files, Changes, documents) of open sessions.
  public private(set) var workspaces: [String: WorkspaceBrowserModel] = [:]

  /// Wraps an existing store.
  /// - Parameters:
  ///   - connection: The store.
  ///   - opener: Opens pages in the system browser.
  public init(connection: ConnectionStore, opener: ExternalURLOpener = .system) {
    self.connection = connection
    signIn = SignInController(store: connection, opener: opener)
  }

  /// A session over the live host services, with this build's Keychain (see
  /// ``KeychainModeSelection``).
  /// - Parameter keychain: The Keychain choice, normally ``KeychainModeSelection/current()``.
  /// - Returns: The session.
  public static func live(keychain: KeychainModeSelection.Choice) -> ServerSession {
    ServerSession(
      connection: ConnectionStore(
        services: .live(keychainMode: keychain.mode),
        config: .app(databricks: DatabricksOAuthSettings.bundled())))
  }

  /// A session over the core's offline demo server: sample sessions, approvals and replies that
  /// stream on a timer. For previews, screenshots and trying the UI without a server.
  /// - Returns: The session.
  /// - Throws: `CoreError` when the bundled sample does not load.
  public static func demo() throws -> ServerSession {
    ServerSession(connection: try PreviewData.demoStore())
  }

  /// Opens `sessionID`: its conversation (stream and history), terminal list and workspace.
  /// - Parameter sessionID: The session.
  public func open(_ sessionID: String) {
    // `conversation(_:)` returns nil only when the core failed to start; that failure is in
    // `connection.issues`, which the screen shows.
    _ = connection.conversation(sessionID)
    if terminalStores[sessionID] == nil, let terminals = connection.terminals(sessionID) {
      terminalStores[sessionID] = TerminalStore(terminals: terminals)
    }
    if workspaces[sessionID] == nil, let workspace = connection.workspace(sessionID) {
      workspaces[sessionID] = WorkspaceBrowserModel(source: workspace)
    }
  }

  /// Closes `sessionID`: its stream, terminal attaches and workspace browser.
  /// - Parameter sessionID: The session.
  public func close(_ sessionID: String) {
    connection.closeConversation(sessionID)
    if let terminals = terminalStores.removeValue(forKey: sessionID) {
      for id in terminals.controllers.keys { terminals.close(id) }
    }
    workspaces[sessionID] = nil
  }

  /// Whether the connection is signed in, so the app shows sessions rather than sign-in.
  public var isSignedIn: Bool { connection.isSignedIn }

  /// The connected server's canonical URL.
  public var connectedURL: URL? {
    connection.connectedServer.flatMap { URL(string: $0.baseUrl) }
  }
}
