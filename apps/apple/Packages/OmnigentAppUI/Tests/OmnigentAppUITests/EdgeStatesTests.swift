import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import OmnigentWorkspaceUI
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// States adapters reach rarely: the words and routes a person sees when they do.
@MainActor
@Suite("Edge states", .serialized, .timeLimit(.minutes(1)))
struct EdgeStatesTests {
  @Test("A server address the core can't read gives a session no web link")
  func noWebLink() async throws {
    let connection = try await signedInStore(threeSessionServer())
    var server = try #require(connection.connectedServer)
    #expect(SidebarAdapter.webURL(server: server, sessionID: "conv_a") != nil)
    server.baseUrl = "not a url"
    #expect(SidebarAdapter.webURL(server: server, sessionID: "conv_a") == nil)
  }

  @Test("Every settings page on a phone has its icon")
  func phoneSettingsIcons() {
    for page in PhoneSettingsPage.allCases {
      #expect(!page.systemImage.isEmpty)
      #expect(page.id == page)
    }
    #expect(Set(PhoneSettingsPage.allCases.map(\.systemImage)).count == 4)
  }

  @Test("A session on a machine that's offline gets the notice, with the server it's on")
  func offlineNotice() async throws {
    var settings = ConversationFixtures.settings(hostOnline: false)
    settings.runnerOnline = false
    let store = try await ConversationFixtures.store(
      header: ConversationFixtures.header(settings: settings))
    let notice = try #require(LivenessAdapter.notice(store, serverURL: "http://server"))
    #expect(notice.title == "Host is offline")
    #expect(notice.command?.contains("http://server") == true)
  }

  @Test("A harness whose environment can't be read says why")
  func harnessEnvironmentNotes() {
    func startup(hostOutdated: Bool) -> HarnessStartup {
      HarnessStartup(
        command: "/bin/codex", found: true, source: "Default command on Mac.", args: [],
        argCount: 0, environment: nil, inheritsEnvironment: false, unset: [],
        hostOutdated: hostOutdated)
    }
    #expect(
      HarnessFixAdapter.startupState(startup(hostOutdated: true), hostName: "Mac").environmentNote
        == "Update Mac to see environment settings.")
    #expect(
      HarnessFixAdapter.startupState(startup(hostOutdated: false), hostName: "Mac").environmentNote
        .hasPrefix("Cannot separate environment values") == true)
  }

  @Test("A starting form with no agent chosen can't ask for skills")
  func skillsWithoutAHarness() async throws {
    let connection = try await signedInStore(newSessionServer())
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    form.selectFolder(creation, "/work")
    form.selection.agentId = "gone"
    #expect(
      form.skillsRequest(creation).unavailable == "Choose a harness to discover host skills.")
  }

  @Test("Turning on a worktree for every session starts this folder on a fresh branch")
  func seededWorktree() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/hosts/mac/worktrees",
      .json(#"{"data":[{"path":"/work","branch":"main","is_main":true}]}"#))
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    form.selectFolder(creation, "/work")
    try await eventually("the worktrees") { creation.worktrees.value != nil }
    form.preferences.set(true, forKey: GitPreferences.alwaysUseWorktreeKey)
    form.seedWorktree(creation)
    #expect(form.selection.git?.branchName.hasPrefix("worktree-") == true)
    form.preferences.set(false, forKey: GitPreferences.alwaysUseWorktreeKey)
    form.seedWorktree(creation)
    #expect(form.selection.git == nil, "turning it off takes the branch back")
  }

  @Test("Starting an unsaved agent sends that agent with the session")
  func startingAPendingAgent() async throws {
    let server = newSessionServer()
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    form.selectFolder(creation, "/work")
    form.adoptPendingAgent(
      AgentDraft(
        name: "Mine", description: "Helps", instructions: "Be kind", harness: "claude-native",
        model: "sonnet", mcpServers: []))
    form.start(creation, text: "hello")
    try await eventually("the create") { !server.requests("POST", "/v1/sessions").isEmpty }
    let create = try #require(server.requests("POST", "/v1/sessions").first)
    let body = try #require(create.body)
    #expect(body.contains(Data("Mine.tar.gz".utf8)))
    #expect(body.contains(Data("/work".utf8)))
  }

  @Test("Ask About This attaches the lines and quotes them")
  func askAboutThis() async throws {
    let store = try await ConversationFixtures.store()
    let span = FileTextSpan(
      path: "src/a.swift", start: 0, end: 4, firstLine: 2, lastLine: 3, text: "let x")
    WorkspaceReviewAdapter.ask(span, store.composer)
    #expect(store.composer.quotes.map(\.text) == ["let x"])
    #expect(store.composer.mentions.contains(span.reference))
  }

  @Test("New Terminal from a session's chat starts it through the window")
  func newTerminalRoute() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions/conv_a/resources/terminals", method: "POST",
      .json(
        #"{"id":"terminal_zsh_1","type":"terminal","metadata":{"running":true}}"#, status: 201))
    let session = try await signedInSession(server)
    let tabs = WindowTabs(
      session: session, context: TabWindowContext(), showAll: {}, fail: { _ in })
    let routes = tabs.routes(for: "conv_a")
    routes.newTerminal?("zsh")
    try await eventually("the terminal") {
      !server.requests("POST", "/v1/sessions/conv_a/resources/terminals").isEmpty
    }
  }

  @Test("A window without a core says its terminals aren't available")
  func noTerminals() async throws {
    let session = ServerSession(
      connection: ConnectionStore(startupError: .InvalidState(message: "no core")),
      opener: ExternalURLOpener { _ in true })
    final class Failures { var messages: [String] = [] }
    let failures = Failures()
    let tabs = WindowTabs(
      session: session, context: TabWindowContext(), showAll: {},
      fail: { failures.messages.append($0) })
    await tabs.newTerminal(in: "conv_a", named: nil, replacing: nil)
    #expect(failures.messages == ["The session's terminals are not available."])
  }

  @Test("Choosing the file panel's change or search result opens it")
  func workspacePanelSearch() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"accounts_enabled":false,"session_pull_requests":true,"features":{"workspace_content_search":true}}"#
      ))
    let session = try await signedInSession(server)
    session.open("conv_a")
    let panel = try #require(session.panels["conv_a"])
    await panel.loadFeatures()
    #expect(panel.offersContentSearch)
    let workspace = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
    let slots = WorkspacePanelSlots(
      workspace: workspace, panel: panel, terminals: nil, tabRoutes: nil,
      terminalNames: .names([]), permissionLevel: 4, composer: nil
    ).slots
    #expect(slots.search != nil)
    slots.refreshPullRequests?()
    try await eventually("the pull requests") {
      !server.requests("GET", "/v1/sessions/conv_a/pull-requests").isEmpty
    }
    let changes = try #require(slots.changes)
    let screen = OffscreenWindow(changes, width: 400, height: 500)
    defer { screen.close() }
    await workspace.changes.reload()
    try await pause(screen)
    workspace.changes.selection = workspace.changes.state.value?.files.first?.path
    try await settle(screen, until: "the diff") {
      if case .diff = workspace.document { true } else { false }
    }

    workspace.search.restore(WorkspaceSamples.searchResult)
    let search = OffscreenWindow(try #require(slots.search), width: 360, height: 480)
    defer { search.close() }
    try await pause(search)
    let results = try #require(search.controlFrames.last { $0.height > 100 })
    for offset in stride(from: 6.0, to: results.height, by: 8.0) {
      if case .file = workspace.document { break }
      try search.click(CGPoint(x: results.midX, y: results.minY + offset))
      try await pause(search)
    }
    try await settle(search, until: "the match's file") {
      if case .file = workspace.document { true } else { false }
    }
  }
}
