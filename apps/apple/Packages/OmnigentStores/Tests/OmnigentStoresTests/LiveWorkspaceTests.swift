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

/// Polls `condition` until it holds or `seconds` pass.
@MainActor
private func eventually(seconds: Int, _ condition: () -> Bool) async throws -> Bool {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try await Task.sleep(for: .milliseconds(100))
  }
  return condition()
}
