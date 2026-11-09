import AppKit
import Foundation
import Observation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import OmnigentViewTesting
import OmnigentViewTextReading
import OmnigentWorkspaceUI
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores
@testable import OmnigentUIComponents

/// Hands the view's `openSettings` to the test.
private struct OpenSettingsProbe: View {
  @Environment(\.openSettings) private var openSettings
  let found: (OpenSettingsAction) -> Void

  var body: some View {
    Color.clear.onAppear { found(openSettings) }
  }
}

/// Hands the attachment previews a page's messages read to the test.
private struct AttachmentPreviewsProbe: View {
  @Environment(\.attachmentPreviews) private var previews
  let found: (AttachmentPreviews?) -> Void

  var body: some View {
    Color.clear.onChange(of: previews != nil, initial: true) { found(previews) }
  }
}

/// A chat's panel choice a test changes while the modifier watches it.
@MainActor
@Observable
private final class PanelChoice {
  var value: WorkspacePanelDefault?
  var binding: Binding<WorkspacePanelDefault?> {
    Binding(get: { self.value }, set: { self.value = $0 })
  }
}

/// States of the small hosts that no page's main path reaches.
@MainActor
@Suite("App edge states", .serialized, .timeLimit(.minutes(1)))
struct AppEdgeStatesTests {
  @Test("Opening Settings at a destination moves the navigator, then opens the window")
  func openingSettings() throws {
    final class Found { var action: OpenSettingsAction? }
    let found = Found()
    let screen = OffscreenWindow(
      OpenSettingsProbe { found.action = $0 }, width: 100, height: 100)
    defer { screen.close() }
    let openSettings = try #require(found.action)
    let navigator = SettingsNavigator()
    let open = OpenSettingsDestinationAction.settingsWindow(navigator, openSettings: openSettings)
    open(.tab(SettingsNavigator.appearanceTab))
    #expect(navigator.tab == SettingsNavigator.appearanceTab)
    open(.server(url: "https://a.test", pane: nil))
    #expect(navigator.tab == SettingsNavigator.serversTab)
    #expect(navigator.takeServerRequest()?.url == "https://a.test")
    #expect(navigator.takeServerRequest() == nil)
  }

  @Test("Asking for the same server twice is two requests")
  func serverRequestsAreDistinct() {
    let first = ServerSettingsRequest(url: "https://a.test", pane: nil)
    let second = ServerSettingsRequest(url: "https://a.test", pane: nil)
    #expect(first != second)
  }

  @Test("Settings lists the windows' connections unless told otherwise")
  func settingsConnections() throws {
    let settings = OffscreenWindow(
      ServerSettingsContainer(navigator: SettingsNavigator()), width: 700, height: 500)
    defer { settings.close() }
    settings.settle()
    #expect(readableText(settings).isEmpty == false)
  }

  @Test("A chat's choice of panel becomes the default for the next chat")
  func panelDefault() async throws {
    let key = InterfacePreferences.workspacePanelKey
    let saved = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(saved, forKey: key) }
    UserDefaults.standard.removeObject(forKey: key)
    let choice = PanelChoice()
    let screen = OffscreenWindow(
      Color.clear.modifier(WorkspacePanelDefaults(workspace: nil, choice: choice.binding)),
      width: 100, height: 100)
    defer { screen.close() }
    choice.value = .open
    try await settle(screen, until: "the default") {
      UserDefaults.standard.string(forKey: key) == WorkspacePanelDefault.open.rawValue
    }
    choice.value = nil
    try await pause(screen)
    #expect(UserDefaults.standard.string(forKey: key) == WorkspacePanelDefault.open.rawValue)
  }

  @Test("The keychain is used unless the probe found this build isn't entitled to it")
  func keychainChoice() {
    let entitled = KeychainModeSelection.choice(
      probed: errSecItemNotFound, kind: "Debug build", folder: "DebugCredentials")
    #expect(entitled.credentialDirectory == nil)
    #expect(entitled.fallbackReason == nil)
    let unentitled = KeychainModeSelection.choice(
      probed: errSecMissingEntitlement, kind: "Debug build", folder: "DebugCredentials")
    #expect(unentitled.credentialDirectory?.lastPathComponent == "DebugCredentials")
    #expect(unentitled.fallbackReason?.hasPrefix("This Debug build") == true)
  }

  @Test("A file that can't be opened says which, and one that can says nothing")
  func openingFiles() {
    var reports: [String] = []
    var opened: [URL] = []
    WorkspaceActionsAdapter.openExternally(
      "/work/a.txt",
      open: {
        opened.append($0)
        return true
      },
      report: { reports.append($0) })
    #expect(opened.map(\.path) == ["/work/a.txt"])
    #expect(reports.isEmpty)
    WorkspaceActionsAdapter.openExternally(
      "/work/a.txt", open: { _ in false }, report: { reports.append($0) })
    #expect(reports == ["Could not open /work/a.txt."])
  }

  @Test("Sidebar options that won't encode leave what was saved")
  func sidebarOptionsSaving() throws {
    struct Unencodable: Error {}
    let defaults = try scratchDefaults()
    let options = SessionDisplayOptions().with(show: .archived)
    SidebarDisplayDefaults.save(options, defaults)
    SidebarDisplayDefaults.save(SessionDisplayOptions(), defaults) { _ in throw Unencodable() }
    #expect(SidebarDisplayDefaults.load(defaults) == options)
  }

  @Test("An unset server has no address to import from; a real one links to its page")
  func importSessionsLink() async throws {
    let store = try await signedInStore(AppServer())
    try await eventually("the list") { store.sessionList.isLoaded }
    let container = NewSessionContainer(connection: store, form: try isolatedForm()) { _ in }
    var opened: [URL] = []
    let openURL = OpenURLAction { url in
      opened.append(url)
      return .handled
    }
    let open = try #require(container.importSessions(openURL, nil))
    open()
    #expect(opened.first?.path() == "/settings/import")
    // Without a server to name, there's no page to link to.
    store.disconnect()
    try await eventually("the server to go") { store.connectedServer == nil }
    store.sessionList.loaded()
    #expect(container.importSessions(openURL, nil) == nil)
  }

  @Test("The system's opener opens the page")
  func systemOpener() async throws {
    SystemSideEffects.install()
    SystemSideEffects.reset()
    defer { SystemSideEffects.reset() }
    let page = try #require(URL(string: "https://example.com/page"))
    #expect(await ExternalURLOpener.system.open(page))
    #expect(SystemSideEffects.record.openedURLs == [page])
  }

  @Test("Navigating from a tab that can't be replaced opens another")
  func navigatingOpensANewTab() {
    let store = TabStore()
    let first = store.open(.inbox)
    let second = store.navigate(to: .canvas)
    #expect(first.id != second.id)
    #expect(store.selectedID == second.id)
  }

  @Test("A bundle the agent sheet installed becomes the form's agent")
  func agentInstalledFromTheSheet() async throws {
    let store = try await signedInStore(newSessionServer())
    let creation = try #require(store.creation())
    let form = try isolatedForm()
    await form.load(creation)
    let container = NewSessionContainer(connection: store, form: form) { _ in }
    let agent = ManagedAgent(
      id: "ag_codex", name: "Codex", description: nil, harness: "codex-native",
      harnessLabel: "Codex", createdAt: nil, updatedAt: nil, builtin: false)
    container.agentCreated(creation)(agent)
    try await eventually("the agent") { form.selection.agentId == "ag_codex" }
  }

  @Test("A file importer that fails reports it on the store")
  func importerAnswer() async throws {
    struct Refused: Error {}
    let store = try await signedInStore(AppServer())
    let agents = try #require(store.customAgents())
    final class Imported { var happened = false }
    let imported = Imported()
    let finished = bundleImportFinished(store: agents) { _ in imported.happened = true }
    finished(.failure(Refused()))
    try await eventually("the failure") { agents.error != nil }
    #expect(!imported.happened)
  }

  @Test("Attachments in a session's messages are read through its conversation")
  func attachmentPreviews() async throws {
    let store = try await ConversationFixtures.store()
    final class Found { var previews: AttachmentPreviews? }
    let found = Found()
    let screen = OffscreenWindow(
      AttachmentPreviewsProbe { found.previews = $0 }
        .modifier(MessageMediaEnvironment(fileLinks: nil, conversation: store)),
      width: 100, height: 100)
    defer { screen.close() }
    try await settle(screen, until: "the previews") { found.previews != nil }
    let previews = try #require(found.previews)
    await #expect(throws: (any Error).self) { try await previews.data(for: "file_missing") }
  }

  @Test("Where a client core didn't start, the pages say they're unavailable")
  func noPages() throws {
    let connection = ConnectionStore(startupError: .InvalidState(message: "No keychain"))
    let usage = OffscreenWindow(
      UsageAdapter(connection: connection) { _ in }, width: 500, height: 300)
    defer { usage.close() }
    #expect(try usage.shows("Usage is unavailable"))
    let automations = OffscreenWindow(
      AutomationsAdapter(connection: connection) { _ in }, width: 500, height: 300)
    defer { automations.close() }
    #expect(try automations.shows("Automations are unavailable"))
  }

  @Test("A reply to a session that's gone sends nothing")
  func replyToAGoneSession() async throws {
    let server = threeSessionServer()
    let store = try await signedInStore(server)
    try await eventually("the list") { store.sessionList.isLoaded }
    let adapter = InboxTriageAdapter(connection: store, open: { _ in }, openFile: { _, _, _ in })
    let item = InboxItem(
      id: "i", kind: .unread, sessionId: "conv_gone", sessionTitle: "Gone", preview: "",
      date: .now)
    adapter.actions.reply?(item, "Hello")
    let core = ConnectionStore(startupError: .InvalidState(message: "No keychain"))
    let none = InboxTriageAdapter(connection: core, open: { _ in }, openFile: { _, _, _ in })
    none.actions.reply?(item, "Hello")
    try await Task.sleep(for: .milliseconds(30))
    #expect(server.http.requests.allSatisfy { $0.method != "POST" })
  }

  @Test("A session signing in or discovering still names its server")
  func targetURLs() async throws {
    let server = AppServer()
    server.route("/.well-known/omnigent.json", .json(ManifestFixtures.oidc))
    server.route("/v1/info", .json(#"{"single_user":false,"accounts_enabled":false}"#))
    server.route("/v1/me", .json(#"{"detail":"sign in"}"#, status: 401))
    let core = try ClientCore(
      http: server.http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
      clock: SystemClock(), scheduler: TestScheduler(sleepScale: 0.01),
      secureStore: InMemorySecureStore(), entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    let store = ConnectionStore(core: core)
    let session = ServerSession(connection: store, opener: ExternalURLOpener { _ in true })
    #expect(session.targetURL == nil)
    await store.connect(serverURL: "http://127.0.0.1:6767")
    try await eventually("the sign-in") {
      if case .signInRequired = store.phase { true } else { false }
    }
    #expect(session.targetURL?.host() == "127.0.0.1")
  }

  @Test("A window saved without its groups offers others none of its tabs")
  func persistenceWithoutGroups() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer {
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        #expect((error as NSError).code == NSFileNoSuchFileError)
      }
    }
    let persistence = TabPersistence(directory: directory, debounce: .milliseconds(1))
    persistence.register(
      window: UUID(), server: "http://a.test", snapshot: { TabWindowState(page: nil, groups: [:]) })
    #expect(persistence.savedTabs(session: "s", server: "http://a.test", for: UUID()) == nil)
  }

  @Test("A workspace file that can't be written says which")
  func exportWriteFails() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "file-\(UUID().uuidString)")
    try Data("x".utf8).write(to: file)
    defer {
      do {
        try FileManager.default.removeItem(at: file)
      } catch {
        Issue.record("the test's file stayed: \(error)")
      }
    }
    let export = WorkspaceFileExport(directory: file.appending(path: "below-a-file"))
    #expect {
      try export.write(WorkspaceFileContents(path: "a.txt", data: Data("a".utf8), truncated: false))
    } throws: { error in
      guard case WorkspaceFileExport.Failure.write(let name, _) = error else { return false }
      return name == "a.txt"
    }
  }
}
