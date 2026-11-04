public import Foundation
public import Observation
public import OmnigentCoreFFI
public import OmnigentServices

/// Connection to one Omnigent server: discovery, sign-in, and the root of the stores fed by the
/// core's events (session list, open conversations, notifications). Errors are kept as state.
@Observable
public final class ConnectionStore {
  /// Where discovery stands.
  public enum State: Equatable {
    /// No discovery has run yet, or the store was reset.
    case idle
    /// Discovery of `serverURL` is in flight.
    case loading(serverURL: String)
    /// The server answered with its manifest.
    case connected(ServerDiscovery)
    /// Discovery of `serverURL` failed; `message` is suitable for display.
    case failed(serverURL: String, message: String)

    /// The server URL being or last discovered, `nil` while idle.
    public var serverURL: String? {
      switch self {
      case .idle: nil
      case .loading(let serverURL), .failed(let serverURL, _): serverURL
      case .connected(let discovery): discovery.baseUrl
      }
    }
  }

  /// The current discovery state.
  public internal(set) var state: State = .idle
  /// The connection and sign-in phase, as the core reports it.
  public internal(set) var phase: ConnectionPhase = .disconnected
  /// The session-updates socket's state.
  public internal(set) var updatesLink: LinkState = .idle
  /// Failures outside an open conversation, newest last.
  public internal(set) var issues: [CoreIssue] = []
  /// A browser-ticket sign-in waiting for approval.
  public internal(set) var browserLogin: BrowserLoginInfo?
  /// Bumped when the server's host inventory changes.
  public internal(set) var hostsRevision = 0
  /// Bumped when the server's project list changes.
  public internal(set) var projectsRevision = 0
  /// Bumped when an open session's changed files were re-read.
  public internal(set) var changedFilesRevision = 0
  /// Bumped when the bearer was renewed in place (no reconnect).
  public internal(set) var credentialRotations = 0
  /// When the current credential expires, in ms since the Unix epoch, after a renewal.
  public internal(set) var credentialExpiresAtMs: UInt64?
  /// A Databricks sign-in waiting for the sign-in sheet's callback.
  public internal(set) var databricksChallenge: DatabricksChallenge?
  /// Update frame types this client did not know, newest last.
  public internal(set) var unknownUpdates: [String] = []
  /// Events applied so far.
  public internal(set) var eventsApplied = 0
  /// The session list.
  public let sessionList = SessionListStore()
  /// Notifications and the badge.
  public let notifications: NotificationsStore?
  /// Agent browser actions; install its `performer` to run them.
  public let browserActions: BrowserActionStore?
  /// Open conversations, by session id.
  public private(set) var conversations: [String: ConversationStore] = [:]
  /// Workspace stores of open sessions, by session id.
  public internal(set) var workspaceStores: [String: WorkspaceStore] = [:]
  /// Terminal lists of open sessions, by session id.
  public internal(set) var terminalStores: [String: SessionTerminalsStore] = [:]
  /// The new-session form, once created.
  public internal(set) var creationStore: CreationStore?

  /// The core, or `nil` when it could not start (see ``issues``).
  public let core: ClientCore?
  private let relay = CoreEventRelay()
  private var pump: Task<Void, Never>?
  private var attempt = 0
  private var nextIssueID = 0

  /// Creates a store over an existing core and starts applying its events.
  /// - Parameter core: The Rust client core.
  public init(core: ClientCore) {
    self.core = core
    notifications = NotificationsStore(core: core, list: sessionList)
    browserActions = BrowserActionStore(core: core)
    sessionList.core = core
    _ = core.subscribe(listener: relay)
    startPump()
  }

  private init(startupError: CoreError) {
    core = nil
    notifications = nil
    browserActions = nil
    record(scope: .connection, startupError)
    phase = .failed(serverUrl: "", error: startupError)
  }

  /// A store over the host's services.
  /// - Parameters:
  ///   - services: The host implementations.
  ///   - config: The build's URL and sign-in policy.
  public convenience init(services: HostServices = .live(), config: HostConfig = .app) {
    self.init(http: services.http, services: services, config: config)
  }

  /// A store whose REST requests go through `transport`; everything else is live.
  /// - Parameter transport: The host HTTP transport.
  public convenience init(transport: any HttpTransport) {
    self.init(http: transport, services: .live(), config: .app)
  }

  private convenience init(http: any HttpTransport, services: HostServices, config: HostConfig) {
    do {
      let core = try ClientCore(
        http: http, streams: services.eventStreams, sockets: services.webSockets,
        clock: services.clock, scheduler: services.scheduler, secureStore: services.secureStore,
        entropy: services.entropy, config: config)
      self.init(core: core)
    } catch {
      self.init(startupError: coreError(error))
    }
  }

  isolated deinit {
    pump?.cancel()
    relay.finish()
    core?.shutdown()
  }

  /// Whether discovery is in flight.
  public var isLoading: Bool {
    if case .loading = state { return true }
    return false
  }

  /// Whether discovery succeeded and the server is usable.
  public var isConnected: Bool { discovery != nil }

  /// Whether the core is connected and signed in.
  public var isSignedIn: Bool {
    if case .connected = phase { return true }
    return false
  }

  /// The server the core is connected to.
  public var connectedServer: ConnectedServer? {
    if case .connected(let server) = phase { return server }
    return nil
  }

  /// The discovered server, when connected.
  public var discovery: ServerDiscovery? {
    if case .connected(let discovery) = state { return discovery }
    return nil
  }

  /// The failure message, when discovery failed.
  public var errorMessage: String? {
    if case .failed(_, let message) = state { return message }
    return nil
  }

  /// Runs discovery against `serverURL` and publishes the outcome in ``state``.
  ///
  /// A newer call supersedes an in-flight one: the older outcome is dropped because the user has
  /// already asked for a different server.
  /// - Parameter serverURL: The server URL as typed by the user.
  public func discover(serverURL: String) async {
    let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    attempt += 1
    let current = attempt
    state = .loading(serverURL: trimmed)
    guard let core else {
      state = .failed(serverURL: trimmed, message: issues.last?.error.message ?? "No core")
      return
    }
    let next: State
    do {
      next = .connected(try await core.discoverServer(serverUrl: trimmed))
    } catch {
      next = .failed(serverURL: trimmed, message: Self.describe(error))
    }
    guard current == attempt else { return }
    state = next
  }

  /// Discovers `serverURL`, then connects: a saved credential is used when there is one,
  /// otherwise ``phase`` becomes `signInRequired` with the methods to offer.
  /// - Parameters:
  ///   - serverURL: The server URL as typed.
  ///   - expectedUserID: The account to restore on an accounts server.
  public func connect(serverURL: String, expectedUserID: String? = nil) async {
    await discover(serverURL: serverURL)
    guard let core, discovery != nil else { return }
    do {
      phase = try await core.connect(serverUrl: serverURL, expectedUserId: expectedUserID)
    } catch {
      record(scope: .connection, coreError(error))
    }
  }

  /// Signs in with a username and password (accounts mode).
  ///
  /// The returned server is the outcome: ``phase`` follows through the core's events, which can
  /// arrive after this returns, so it may still read `signingIn` here.
  /// - Parameters:
  ///   - username: The account name.
  ///   - password: The password; it is not kept.
  /// - Returns: The server signed in to, or `nil` after recording the failure.
  public func signIn(username: String, password: String) async -> ConnectedServer? {
    guard let core else { return nil }
    do {
      return try await core.signInWithPassword(username: username, password: password)
    } catch {
      record(scope: .connection, coreError(error))
      return nil
    }
  }

  /// Starts a native OIDC sign-in redirecting to `redirectURI`.
  /// - Parameter redirectURI: The registered scheme URI, or the loopback listener's URI.
  /// - Returns: What to present, or `nil` after recording the failure.
  public func beginBrowserSignIn(redirectURI: String) -> OidcChallenge? {
    guard let core else { return nil }
    do {
      return try core.beginOidcSignIn(redirectUri: redirectURI)
    } catch {
      record(scope: .connection, coreError(error))
      return nil
    }
  }

  /// Finishes a native OIDC sign-in with the callback the sheet or listener received.
  /// - Parameters:
  ///   - challenge: The challenge from ``beginBrowserSignIn(redirectURI:)``.
  ///   - callbackURL: The full callback URL.
  /// - Returns: The server signed in to, or `nil` after recording the failure. Like
  ///   ``signIn(username:password:)``, it can return before ``phase`` reads `connected`.
  public func completeBrowserSignIn(_ challenge: OidcChallenge, callbackURL: URL) async
    -> ConnectedServer?
  {
    guard let core else { return nil }
    do {
      return try await core.completeOidcSignIn(
        attemptId: challenge.attemptId, callbackUrl: callbackURL.absoluteString)
    } catch {
      record(scope: .connection, coreError(error))
      return nil
    }
  }

  /// Abandons a native OIDC sign-in (the user closed the sheet).
  /// - Parameter challenge: The challenge.
  public func cancelBrowserSignIn(_ challenge: OidcChallenge) {
    core?.cancelOidcSignIn(attemptId: challenge.attemptId)
  }

  /// Starts the browser-ticket sign-in; ``browserLogin`` holds the page to open.
  public func beginBrowserTicketSignIn() async {
    guard let core else { return }
    do {
      browserLogin = try await core.beginBrowserLogin()
    } catch {
      record(scope: .connection, coreError(error))
    }
  }

  /// Signs out and forgets the saved credential.
  public func signOut() async {
    guard let core else { return }
    do {
      try await core.signOut()
    } catch {
      record(scope: .connection, coreError(error))
    }
  }

  /// Ends the connection and every stream.
  public func disconnect() {
    core?.disconnect()
  }

  /// Returns to ``State/idle`` and drops any in-flight outcome.
  public func reset() {
    attempt += 1
    state = .idle
    core?.disconnect()
  }

  /// Reloads the session list.
  public func refreshSessions() {
    core?.refreshSessions()
  }

  /// The app returned to the foreground: streams reopen and reconcile.
  public func foreground() {
    core?.foreground()
  }

  /// The session the user is looking at, for notifications and the badge.
  /// - Parameters:
  ///   - sessionID: The visible session.
  ///   - focused: Whether its window is focused.
  public func setView(sessionID: String?, focused: Bool) {
    core?.setView(activeSessionId: sessionID, windowFocused: focused)
  }

  /// Marks `sessionID` seen, as opening it does, for a session read somewhere other than its
  /// open view (for example from a notification). ``setView(sessionID:focused:)`` already marks
  /// the viewed session. A failure is recorded in ``issues``; the mark stays on this device.
  /// - Parameter sessionID: The session.
  /// - Returns: Whether the server accepted the mark (or nothing needed writing).
  @discardableResult
  public func markSeen(_ sessionID: String) async -> Bool {
    guard let core else { return false }
    do {
      try await core.markSessionSeen(sessionId: sessionID)
      return true
    } catch {
      record(scope: .session(sessionId: sessionID), coreError(error))
      return false
    }
  }

  /// The store of `sessionID`, opening the conversation (stream and history) on first use.
  /// - Parameter sessionID: The session.
  /// - Returns: Its store, or `nil` when the core did not start.
  public func conversation(_ sessionID: String) -> ConversationStore? {
    if let existing = conversations[sessionID] { return existing }
    guard let core else { return nil }
    let store = ConversationStore(
      sessionID: sessionID, core: core,
      listStatus: ListStatusExpectation(list: sessionList, sessionID: sessionID))
    let list = sessionList
    store.composer.draftChanged = { [weak list] hasDraft in list?.setDraft(sessionID, hasDraft) }
    conversations[sessionID] = store
    core.openSession(sessionId: sessionID)
    return store
  }

  /// Closes `sessionID`'s stream and drops its store.
  /// - Parameter sessionID: The session.
  public func closeConversation(_ sessionID: String) {
    conversations[sessionID] = nil
    workspaceStores[sessionID] = nil
    terminalStores[sessionID] = nil
    core?.closeSession(sessionId: sessionID)
  }

  /// Clears ``issues`` after the user has seen them.
  public func dismissIssues() {
    issues = []
  }

  /// A user-facing description of a failure.
  /// - Parameter error: The error thrown by the core.
  /// - Returns: Text suitable for display.
  public static func describe(_ error: any Error) -> String {
    coreError(error).message
  }

  private func startPump() {
    let events = relay.events
    pump = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        self.apply(event)
      }
    }
  }

  func record(scope: ErrorScope, _ error: CoreError) {
    nextIssueID += 1
    issues.append(CoreIssue(id: nextIssueID, scope: scope, error: error))
    if issues.count > 50 { issues.removeFirst(issues.count - 50) }
  }
}
