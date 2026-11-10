import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores
@testable import OmnigentWorkspaceUI

/// Smaller behaviors of the window's session object, palette and pages.
@MainActor
@Suite("Screen details", .serialized, .timeLimit(.minutes(1)))
struct ScreenDetailsTests {
  private enum PickerError: Error {
    case cancelledByTheSystem
  }

  private func session(_ server: AppServer = threeSessionServer()) async throws -> ServerSession {
    try await signedInSession(server)
  }

  @Test("The palette lists the organization's servers first, then recent ones once each")
  func paletteServers() async throws {
    let session = try await session()
    session.signIn.directory = ServerDirectory(
      managed: [
        ManagedServerEntry(
          url: "https://org.example", name: "Org", origin: "https://org.example",
          authority: "profile", displayName: "Org")
      ],
      serversAreForced: false, recentServers: ["https://org.example", "https://recent.example"])
    let adapter = PaletteAdapter(session: session, selection: .constant(nil))
    let servers = adapter.state.servers
    #expect(servers.map(\.id) == ["https://org.example", "https://recent.example"])
    #expect(servers.map(\.detail) == ["Organization server", "Recent server"])
    #expect(servers.last?.title == "recent.example")

    session.signIn.directory.serversAreForced = true
    #expect(adapter.state.servers.map(\.id) == ["https://org.example"], "recents are hidden")
  }

  @Test("A window knows which server it is on from the moment it starts connecting")
  func targetURL() async throws {
    let connected = try await session()
    #expect(
      connected.targetURL
        == connected.connection.connectedServer.flatMap {
          URL(string: $0.baseUrl)
        })
    let idle = ServerSession(
      connection: ConnectionStore(startupError: .InvalidState(message: "no core")),
      opener: ExternalURLOpener { _ in true })
    #expect(idle.targetURL == nil)

    let server = AppServer()
    server.route("/.well-known/omnigent.json", .json(ManifestFixtures.oidc))
    server.route("/v1/info", .json(#"{"single_user":false,"accounts_enabled":false}"#))
    server.route("/v1/me", .json(#"{"detail":"sign in"}"#, status: 401))
    let core = try ClientCore(
      http: server.http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
      clock: SystemClock(), scheduler: TestScheduler(sleepScale: 0.01),
      secureStore: InMemorySecureStore(), entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    let signingIn = ServerSession(
      connection: ConnectionStore(core: core), opener: ExternalURLOpener { _ in true })
    await signingIn.signIn.connectNow("http://127.0.0.1:6767")
    #expect(signingIn.targetURL?.host() == "127.0.0.1")
  }

  @Test("A bundle picked in the importer installs, and an importer failure is reported")
  func pickingABundle() async throws {
    let server = newSessionServer()
    server.route("/v1/agents", method: "POST", .json(#"{"id":"ag_new","name":"New"}"#))
    let connection = try await signedInStore(server)
    let store = try #require(connection.customAgents())
    final class Installed { var agents: [String] = [] }
    let installed = Installed()

    await bundlePicked(.failure(PickerError.cancelledByTheSystem), store: store) {
      installed.agents.append($0.id)
    }
    #expect(store.error != nil)
    await bundlePicked(.failure(PickerError.cancelledByTheSystem), store: nil) {
      installed.agents.append($0.id)
    }

    let bundle = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).tar.gz")
    try Data([1, 2, 3]).write(to: bundle)
    defer {
      do {
        try FileManager.default.removeItem(at: bundle)
      } catch {
        Issue.record(error, "could not remove \(bundle.path)")
      }
    }
    await bundlePicked(.success(bundle), store: store) { installed.agents.append($0.id) }
    #expect(installed.agents == ["ag_new"])
  }

  @Test("The app's session reads its keychain choice without touching the network")
  func liveSession() {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let session = ServerSession.live(
      keychain: KeychainModeSelection.Choice(
        mode: .fileBased(build: nil), credentialDirectory: folder, fallbackReason: nil))
    #expect(session.connection.core != nil)
    #expect(session.connection.draftArchive != nil)
    #expect(session.connectedURL == nil)
  }

  private func workspaceServer() -> AppServer {
    let server = threeSessionServer()
    let base = "/v1/sessions/conv_a/resources/environments/default"
    server.route(
      "\(base)/filesystem/notes.txt",
      .json(
        #"{"object":"session.environment.filesystem.file_content","path":"notes.txt","content_type":"text/plain","bytes":12,"truncated":false,"encoding":"utf-8","content":"one\ntwo\nthree\n"}"#
      ))
    return server
  }

  @Test("Opening a file at a comment's place marks the line that holds it")
  func revealingAComment() async throws {
    let session = try await session(workspaceServer())
    session.open("conv_a")
    let workspace = try #require(session.workspaces["conv_a"])
    session.openFile("notes.txt", at: 5, in: "conv_a")
    try await eventually("the line") { workspace.document == .file(path: "notes.txt", line: 2) }
  }

  @Test("Closing a session saves its edits first; edits that won't save keep the workspace")
  func closingWithEdits() async throws {
    let server = workspaceServer()
    let base = "/v1/sessions/conv_a/resources/environments/default"
    server.route(
      "\(base)/filesystem/notes.txt", method: "PUT",
      .json(#"{"path":"notes.txt","bytes":3}"#))
    let session = try await session(server)
    session.open("conv_a")
    let workspace = try #require(session.workspaces["conv_a"])
    await workspace.open(.file(path: "notes.txt", line: nil))
    let editor = try #require(workspace.editors["notes.txt"])
    editor.autosaveDelay = nil
    editor.textEdited { "changed" }
    #expect(!workspace.unsavedPaths.isEmpty)
    session.close("conv_a")
    #expect(session.workspace(of: "conv_a") === workspace, "kept while its edits save")
    try await eventually("the save") { session.workspace(of: "conv_a") == nil }
    #expect(!server.requests("PUT", "\(base)/filesystem/notes.txt").isEmpty)
  }
}
