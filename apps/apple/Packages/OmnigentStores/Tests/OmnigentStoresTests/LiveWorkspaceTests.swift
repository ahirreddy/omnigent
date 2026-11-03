import Foundation
import OmnigentCoreFFI
import OmnigentServices
import Testing

@testable import OmnigentStores

/// The app's networking stack, without the app: the Rust core, the URLSession transports and the
/// stores the UI reads, against a live Databricks-hosted server, reusing a sign-in a Debug Mac
/// app saved (its `DebugCredentials` folder). Connects, lists sessions, opens one, and checks that
/// its history loads, its live stream connects and its runner-routed reads (terminals, agent)
/// succeed, with no error recorded anywhere. It sends nothing.
///
/// Runs when `OMNIGENT_LIVE_WORKSPACE_URL` (with `?o=` for a multi-workspace host) and
/// `OMNIGENT_LIVE_CREDENTIALS` (the credentials folder) are set; `OMNIGENT_LIVE_SESSION_ID`
/// picks the session, else the most recently updated one. Quit the app first: both share the
/// grant, and a refresh by one rotates it under the other.
@MainActor
@Suite("Live workspace", .enabled(if: LiveWorkspace.current != nil), .serialized)
struct LiveWorkspaceTests {
  @Test func signInListOpenAndRoute() async throws {
    let live = try #require(LiveWorkspace.current)
    let connection = ConnectionStore(
      services: .live(credentialDirectory: live.credentials),
      config: .app(
        databricks: DatabricksOAuthSettings(clientId: "omnigent", redirectUrl: "http://localhost")))
    await connection.connect(serverURL: live.url)
    guard connection.isSignedIn else {
      throw LiveWorkspaceError(
        "not signed in (\(connection.phase)); sign in once in the Debug Mac app first")
    }

    #expect(
      try await eventually(seconds: 30) { !connection.sessionList.sessionsByID.isEmpty },
      "no sessions listed")
    let sessionID = try #require(
      live.sessionID
        ?? connection.sessionList.sessionsByID.values.max { $0.updatedAt < $1.updatedAt }?.id)
    let title = connection.sessionList.sessionsByID[sessionID]?.title ?? "?"

    let conversation = try #require(connection.conversation(sessionID))
    defer { connection.closeConversation(sessionID) }
    #expect(
      try await eventually(seconds: 60) { conversation.isHydrated },
      "history did not load; errors \(conversation.errors)")
    #expect(
      try await eventually(seconds: 60) { conversation.link == .live },
      "the stream is \(conversation.link)")

    let terminals = try #require(connection.terminals(sessionID))
    terminals.refresh()
    await terminals.loadDeclaredTerminalNames()
    // Let the terminal list and stream events land.
    try await Task.sleep(for: .seconds(5))
    #expect(terminals.lastError == nil, "terminals: \(String(describing: terminals.lastError))")
    #expect(conversation.errors.isEmpty, "conversation: \(conversation.errors)")
    #expect(
      connection.issues.isEmpty,
      "issues: \(connection.issues.map { "\($0.scope): \($0.error)" })")
    print(
      "live-workspace: \(sessionID) \"\(title)\": \(conversation.rows.count) rows, stream "
        + "\(conversation.link), \(terminals.rows.count) terminals, declared "
        + "\(terminals.declaredTerminalNames)")
  }
}

extension LiveWorkspaceTests {
  /// Prints the hosts and agents a new session could use (read-only), to choose where a scratch
  /// session runs.
  @Test func catalog() async throws {
    let live = try #require(LiveWorkspace.current)
    let connection = try await live.connected()
    let creation = try #require(connection.creation())
    await creation.loadCatalog()
    guard let catalog = creation.catalog.value else {
      throw LiveWorkspaceError("the catalog did not load: \(creation.catalog)")
    }
    for host in catalog.hosts {
      print(
        "live-catalog host \(host.hostId) \"\(host.name)\" \(host.status) "
          + "\(host.sandboxProvider ?? "-")")
    }
    for agent in catalog.agents {
      print("live-catalog agent \(agent.id) \"\(agent.name)\" \(agent.harness ?? "-")")
    }
  }
}

extension LiveWorkspaceTests {
  /// Writes, so it runs only with `OMNIGENT_LIVE_SCRATCH_AGENT` (an agent name, for example
  /// `codex-native-ui`): creates a session on a new sandbox, waits for its runner, sends a
  /// message and watches the reply stream to its end, then stops a long reply part way. The
  /// session is left in place, titled as a test, for inspection or deletion.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIGENT_LIVE_SCRATCH_AGENT"] != nil))
  func sandboxSessionSendsStreamsAndStops() async throws {
    let live = try #require(LiveWorkspace.current)
    let agentName = try #require(ProcessInfo.processInfo.environment["OMNIGENT_LIVE_SCRATCH_AGENT"])
    let connection = try await live.connected()
    let started = ContinuousClock.now
    // `OMNIGENT_LIVE_SCRATCH_SESSION_ID` reuses a scratch session instead of a new sandbox.
    let sessionID =
      if let existing = ProcessInfo.processInfo.environment["OMNIGENT_LIVE_SCRATCH_SESSION_ID"] {
        existing
      } else {
        try await createOnSandbox(agentName: agentName, connection: connection)
      }
    let conversation = try #require(connection.conversation(sessionID))
    defer { connection.closeConversation(sessionID) }
    #expect(try await eventually(seconds: 120) { conversation.isHydrated }, "history did not load")
    try await waitUntilSendable(conversation)
    print("live-scratch: runner online after \(ContinuousClock.now - started)")

    // A reply streams in and the turn ends.
    try await send("Reply with exactly the word pong and nothing else.", to: conversation)
    let replied = try await eventually(seconds: 300) {
      !conversation.isRunning
        && conversation.transcriptRows.contains {
          $0.role == .assistant && $0.text.lowercased().contains("pong")
        }
    }
    #expect(
      replied,
      "no pong; rows \(conversation.transcriptRows.map { "\($0.role): \($0.text.prefix(80))" })")
    print("live-scratch: replied after \(ContinuousClock.now - started)")

    try await checkStop(conversation)
    #expect(conversation.errors.isEmpty, "conversation: \(conversation.errors)")
    print(
      "live-scratch: stopped after \(ContinuousClock.now - started); "
        + "\(conversation.transcriptRows.count) rows")
  }

  /// Creates the scratch session on a new sandbox and returns its id.
  private func createOnSandbox(agentName: String, connection: ConnectionStore) async throws
    -> String
  {
    let creation = try #require(connection.creation())
    await creation.loadCatalog()
    let agent = try #require(
      creation.catalog.value?.agents.first { $0.name == agentName }, "no agent \(agentName)")
    await creation.createInSandbox(
      agentID: agent.id, title: "Omnigent native client test (safe to delete)", workspaces: [])
    guard case .created(let sessionID, nil) = creation.phase else {
      throw LiveWorkspaceError("the sandbox session was not created: \(creation.phase)")
    }
    print("live-scratch: created \(sessionID) on a new sandbox")
    return sessionID
  }

  /// Waits up to 15 minutes for the sandbox to bind and its runner to come up: until the
  /// composer, like the app's, reads the session's configuration with no reason it cannot run.
  private func waitUntilSendable(_ conversation: ConversationStore) async throws {
    let deadline = ContinuousClock.now + .seconds(900)
    while ContinuousClock.now < deadline {
      await conversation.composer.loadConfiguration()
      if conversation.composer.configuration != nil,
        conversation.composer.executionUnavailableReason == nil
      {
        return
      }
      try await Task.sleep(for: .seconds(5))
    }
    throw LiveWorkspaceError(
      "the session never became sendable: "
        + "\(conversation.composer.executionUnavailableReason ?? "no configuration"), "
        + "\(String(describing: conversation.composer.configurationError))")
  }

  /// Stop ends a turn that would otherwise run for two minutes, and its final answer never
  /// comes (a fast model streams a long text reply faster than a Stop can land).
  private func checkStop(_ conversation: ConversationStore) async throws {
    let rowsBefore = conversation.transcriptRows.count
    try await send(
      "Run the shell command `sleep 120`, then reply with the single word finished.",
      to: conversation)
    #expect(
      try await eventually(seconds: 120) { conversation.isRunning }, "the turn did not start")
    try await Task.sleep(for: .seconds(8))
    let stoppedAt = ContinuousClock.now
    await conversation.interrupt()
    #expect(
      try await eventually(seconds: 60) { !conversation.isRunning }, "the turn did not stop")
    print("live-scratch: the turn ended \(ContinuousClock.now - stoppedAt) after Stop")
    try await Task.sleep(for: .seconds(5))
    let answered = conversation.transcriptRows.dropFirst(rowsBefore).contains {
      $0.role == .assistant && $0.text.lowercased().contains("finished")
    }
    #expect(!answered, "the turn ran to its end after Stop")
  }

  private func send(_ text: String, to conversation: ConversationStore) async throws {
    conversation.composer.text = text
    await conversation.composer.send()
    if let error = conversation.composer.lastError {
      throw LiveWorkspaceError("sending failed: \(error)")
    }
  }
}

extension LiveWorkspace {
  /// A store signed in with the saved grant.
  @MainActor
  func connected() async throws -> ConnectionStore {
    let connection = ConnectionStore(
      services: .live(credentialDirectory: credentials),
      config: .app(
        databricks: DatabricksOAuthSettings(clientId: "omnigent", redirectUrl: "http://localhost")))
    await connection.connect(serverURL: url)
    guard connection.isSignedIn else {
      throw LiveWorkspaceError(
        "not signed in (\(connection.phase)); sign in once in the Debug Mac app first")
    }
    return connection
  }
}

/// The live server, credentials and session from the environment.
nonisolated struct LiveWorkspace: Sendable {
  let url: String
  let credentials: URL
  let sessionID: String?

  static let current: Self? = {
    let environment = ProcessInfo.processInfo.environment
    guard let url = environment["OMNIGENT_LIVE_WORKSPACE_URL"],
      let credentials = environment["OMNIGENT_LIVE_CREDENTIALS"]
    else { return nil }
    return Self(
      url: url, credentials: URL(filePath: credentials, directoryHint: .isDirectory),
      sessionID: environment["OMNIGENT_LIVE_SESSION_ID"])
  }()
}

struct LiveWorkspaceError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// Polls `condition` every half second until it holds or `seconds` pass.
@MainActor
private func eventually(seconds: Int, _ condition: () -> Bool) async throws -> Bool {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try await Task.sleep(for: .milliseconds(500))
  }
  return condition()
}
