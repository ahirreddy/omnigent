public import Foundation
public import Observation
import OmnigentCoreFFI
public import OmnigentRemoteBrowser
import OmnigentServices
public import OmnigentStores
public import OmnigentTerminalStores
public import OmnigentUIComponents
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
  /// The right panel's server data (panel features, pull requests) of open sessions.
  public private(set) var panels: [String: SessionPanelStore] = [:]
  /// The window's tabs.
  public let tabs = TabStore()
  /// Messages that `?message=` links ask the transcript to scroll to.
  public let transcriptFocus = TranscriptFocus()
  /// Sessions whose conversation, terminals and workspace are open.
  public private(set) var openSessionIDs: Set<String> = []
  /// The terminal names each session's agent declares, once read.
  public private(set) var declaredTerminals: [String: [String]] = [:]
  /// Remote browser tabs; `nil` when this build has no remote browser connector.
  public let remoteBrowsers: RemoteBrowserTabs?
  /// Runs on the core's offline demo server (``demo()``).
  public private(set) var isDemo = false
  /// Files to show once their session's workspace opens: path and character offset.
  @ObservationIgnored private var pendingFiles: [String: (path: String, offset: UInt64?)] = [:]

  /// Wraps an existing store.
  /// - Parameters:
  ///   - connection: The store.
  ///   - opener: Opens pages in the system browser.
  ///   - remoteBrowser: The remote browser connector; by default the one
  ///     ``RemoteBrowserAvailability`` turns on for this connection, if any.
  public init(
    connection: ConnectionStore, opener: ExternalURLOpener = .system,
    remoteBrowser: (any RemoteBrowserConnecting)? = nil
  ) {
    self.connection = connection
    signIn = SignInController(store: connection, opener: opener)
    remoteBrowsers = (remoteBrowser ?? RemoteBrowserAvailability.connector(core: connection.core))
      .map { RemoteBrowserTabs(connector: $0) }
  }

  /// A session over the live host services, with this build's Keychain (see
  /// ``KeychainModeSelection``).
  /// - Parameter keychain: The Keychain choice, normally ``KeychainModeSelection/current()``.
  /// - Returns: The session.
  public static func live(keychain: KeychainModeSelection.Choice) -> ServerSession {
    let connection = ConnectionStore(
      services: .live(
        keychainMode: keychain.mode, credentialDirectory: keychain.credentialDirectory),
      config: .app(databricks: DatabricksOAuthSettings.bundled()))
    connection.draftArchive = ComposerDraftArchive.shared
    return ServerSession(connection: connection)
  }

  /// A session over the core's offline demo server: sample sessions, approvals and replies that
  /// stream on a timer. For previews, screenshots and trying the UI without a server.
  /// - Returns: The session.
  /// - Throws: `CoreError` when the bundled sample does not load.
  public static func demo() throws -> ServerSession {
    let session = ServerSession(connection: try PreviewData.demoStore())
    session.isDemo = true
    return session
  }

  /// The demo server's address, which a demo window connects to when nothing else is bound.
  public static let demoServerURL = PreviewData.demoServerURL

  /// Opens `sessionID`: its conversation (stream and history), terminal list and workspace.
  /// - Parameter sessionID: The session.
  public func open(_ sessionID: String) {
    // `conversation(_:)` returns nil only when the core failed to start; that failure is in
    // `connection.issues`, which the screen shows.
    guard connection.conversation(sessionID) != nil else { return }
    openSessionIDs.insert(sessionID)
    if terminalStores[sessionID] == nil, let terminals = connection.terminals(sessionID) {
      terminalStores[sessionID] = TerminalStore(terminals: terminals)
    }
    if workspaces[sessionID] == nil, let workspace = connection.workspace(sessionID) {
      workspaces[sessionID] = WorkspaceBrowserModel(source: workspace)
    }
    if let pending = pendingFiles.removeValue(forKey: sessionID) {
      openFile(pending.path, at: pending.offset, in: sessionID)
    }
    if panels[sessionID] == nil { panels[sessionID] = connection.makePanelStore(sessionID) }
    Task { await loadDeclaredTerminalNames([sessionID]) }
  }

  /// Shows a workspace file in `sessionID`'s right panel, now or once the session opens, and
  /// marks the line holding the character at `offset` (a file comment's start).
  /// - Parameters:
  ///   - path: The workspace-relative path.
  ///   - offset: A 0-based character offset in the file.
  ///   - sessionID: The session.
  public func openFile(_ path: String, at offset: UInt64?, in sessionID: String) {
    guard let workspace = workspaces[sessionID] else {
      pendingFiles[sessionID] = (path, offset)
      return
    }
    Task {
      await workspace.open(.file(path: path, line: nil))
      guard let offset, case .loaded(let file) = workspace.file, file.path == path,
        case .text(let preview) = file.preview,
        let line = lineAtCharacter(text: preview.text, offset: offset)
      else { return }
      workspace.reveal(line: line)
    }
  }

  /// Closes `sessionID`: its stream, terminal attaches and workspace browser. Unsaved file
  /// edits are saved first; a workspace whose edits cannot be saved stays, so reopening the
  /// session shows them and closing the window or quitting asks about them.
  /// - Parameter sessionID: The session.
  public func close(_ sessionID: String) {
    connection.closeConversation(sessionID)
    openSessionIDs.remove(sessionID)
    if let terminals = terminalStores.removeValue(forKey: sessionID) {
      for id in terminals.controllers.keys { terminals.close(id) }
    }
    if let workspace = workspaces[sessionID], !workspace.unsavedPaths.isEmpty {
      Task { [weak self] in
        let unsaved = await workspace.saveAll()
        guard let self, unsaved.isEmpty, !self.openSessionIDs.contains(sessionID),
          self.workspaces[sessionID] === workspace
        else { return }
        self.workspaces[sessionID] = nil
      }
    } else {
      workspaces[sessionID] = nil
    }
    panels[sessionID] = nil
  }

  /// Opens and closes sessions so exactly `wanted` are open: the sessions the window's built
  /// tabs show.
  /// - Parameter wanted: The sessions to keep open.
  public func keepOpen(_ wanted: Set<String>) {
    for id in openSessionIDs.subtracting(wanted) { close(id) }
    for id in wanted.subtracting(openSessionIDs) { open(id) }
  }

  /// The terminal New Terminal starts while the agent's declared names are unknown.
  public static let defaultTerminalName = "Shell"

  /// The terminal names `sessionID`'s agent declares, for New Terminal and the new-tab page:
  /// ``DeclaredTerminals/unknown`` until ``loadDeclaredTerminalNames(_:)`` reads them, and for a
  /// server too old to report them.
  /// - Parameter sessionID: The session.
  /// - Returns: The declared names.
  public func declaredTerminalNames(in sessionID: String) -> DeclaredTerminals {
    declaredTerminals[sessionID].map(DeclaredTerminals.names) ?? .unknown
  }

  /// Reads the declared terminal names of sessions not read yet. A failure stays on the
  /// session's terminal store (``SessionTerminalsStore/lastError``, shown in its Terminals
  /// panel) and leaves the names unknown.
  /// - Parameter sessionIDs: The sessions.
  public func loadDeclaredTerminalNames(_ sessionIDs: [String]) async {
    for id in sessionIDs where declaredTerminals[id] == nil {
      guard let terminals = connection.terminals(id) else { continue }
      if !terminals.knowsDeclaredTerminalNames { await terminals.loadDeclaredTerminalNames() }
      if terminals.knowsDeclaredTerminalNames {
        declaredTerminals[id] = terminals.declaredTerminalNames
      }
    }
  }

  /// Whether the connection is signed in, so the app shows sessions rather than sign-in.
  public var isSignedIn: Bool { connection.isSignedIn }

  /// The connected server's canonical URL.
  public var connectedURL: URL? {
    connection.connectedServer.flatMap { URL(string: $0.baseUrl) }
  }
}

/// The terminals a session's agent declares.
public enum DeclaredTerminals: Hashable, Sendable {
  /// Not read yet, or a server that does not report them: New Terminal offers
  /// ``ServerSession/defaultTerminalName``.
  case unknown
  /// The declared names; empty when the agent declares none, so no terminal can start.
  case names([String])

  /// What New Terminal offers.
  var choices: [String] {
    switch self {
    case .unknown: [ServerSession.defaultTerminalName]
    case .names(let names): names
    }
  }
}
