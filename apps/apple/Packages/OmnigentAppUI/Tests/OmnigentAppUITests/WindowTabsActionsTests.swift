import Foundation
import OmnigentCoreFFI
import OmnigentRemoteBrowser
import OmnigentTerminalStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// What the tab strip, the menu commands and the New Tab page do to a window's tabs.
@MainActor
@Suite("Window tab actions", .timeLimit(.minutes(1)))
struct WindowTabsActionsTests {
  private final class Failures {
    var messages: [String] = []
  }

  private struct Window {
    let session: ServerSession
    let tabs: WindowTabs
    let browser: FakeBrowserHost
    let failures: Failures
    let server: AppServer
  }

  private func window(
    _ server: AppServer = threeSessionServer(), remote: (any RemoteBrowserConnecting)? = nil
  ) async throws -> Window {
    SystemSideEffects.install()
    let connection = try await signedInStore(server)
    try await eventually("the session list") { connection.sessionList.isLoaded }
    let session = ServerSession(
      connection: connection, opener: ExternalURLOpener { _ in true }, remoteBrowser: remote)
    let browser = FakeBrowserHost()
    let failures = Failures()
    let tabs = WindowTabs(
      session: session, context: TabWindowContext(browser: browser), showAll: {},
      fail: { failures.messages.append($0) })
    return Window(
      session: session, tabs: tabs, browser: browser, failures: failures, server: server)
  }

  private func hasBrowser(_ group: TabStore) -> Bool {
    group.tabs.contains { if case .browser = $0.content { true } else { false } }
  }

  @Test("Open Browser opens the server's web app in the session's tabs and shows the session")
  func openBrowser() async throws {
    let window = try await window()
    window.session.tabs.open(.chat(sessionID: "conv_a"))
    let commands = window.tabs.commands
    let open = try #require(commands.openBrowser)
    open()
    #expect(window.browser.madeURLs == [window.session.connectedURL])
    #expect(hasBrowser(window.session.tabs.group("conv_a")))
    #expect(window.session.tabs.page == .session("conv_a"))
    #expect(window.tabs.routes(for: "conv_a").openBrowser != nil)
  }

  @Test("Duplicate on a browser tab makes another page at the same address")
  func duplicateBrowser() async throws {
    let window = try await window()
    window.session.tabs.open(.chat(sessionID: "conv_a"))
    let address = URL(string: "https://example.com/a")
    window.tabs.openBrowser(url: address, in: "conv_a")
    let group = window.session.tabs.group("conv_a")
    let selected = try #require(group.selected)
    let strip = try #require(window.tabs.strip)
    strip.actions.duplicate(selected.id)
    #expect(window.browser.madeURLs == [address, address])
    #expect(group.tabs.count == 3)
    let chat = try #require(group.tabs.first)
    strip.actions.duplicate(chat.id)
    #expect(group.tabs.count == 3, "a primary chat has no second copy")
  }

  @Test("Reopen Closed Tab comes back once a tab was closed")
  func reopenClosed() async throws {
    let window = try await window()
    window.session.tabs.open(.chat(sessionID: "conv_a"))
    let group = window.session.tabs.group("conv_a")
    window.tabs.openBrowser(url: URL(string: "https://example.com"), in: "conv_a")
    #expect(window.tabs.strip?.actions.reopenClosed == nil)
    #expect(window.tabs.commands.reopenClosedTab == nil)
    let page = try #require(group.selected)
    group.close(page.id)
    #expect(group.tabs.count == 1)
    window.tabs.commands.reopenClosedTab?()
    #expect(group.tabs.count == 2)
    group.close(page.id)
    window.tabs.strip?.actions.reopenClosed?()
    #expect(group.tabs.count == 2, "the strip's menu reopens it as well")
  }

  @Test("A browser tab's strip entry follows the page: title, link, audio, loading, failure")
  func browserStatus() async throws {
    let window = try await window()
    window.session.tabs.open(.chat(sessionID: "conv_a"))
    window.tabs.openBrowser(url: URL(string: "https://example.com/a"), in: "conv_a")
    let group = window.session.tabs.group("conv_a")
    guard case .browser(let id) = group.selected?.content else {
      Issue.record("the browser tab is selected")
      return
    }
    let address = URL(string: "https://example.com/page")
    window.browser.statuses[id] = BrowserTabStatus(
      title: "A page", url: address, isLoading: true, isAudible: true, favicon: Data([1]))
    var item = try #require(window.tabs.strip?.state.tabs.last)
    #expect(item.title == "A page")
    #expect(item.link == address)
    #expect(item.isPlayingAudio)
    #expect(item.favicon == Data([1]))
    #expect(item.status == .loading)
    window.browser.statuses[id]?.hasError = true
    item = try #require(window.tabs.strip?.state.tabs.last)
    #expect(item.status == .failed)
    window.browser.statuses[id]?.hasError = false
    window.browser.statuses[id]?.isLoading = false
    item = try #require(window.tabs.strip?.state.tabs.last)
    #expect(item.status == TabStatus.none)
  }

  @Test("The New Tab page's Browser takes over its tab")
  func newTabPageBrowser() async throws {
    let window = try await window()
    window.session.tabs.open(.chat(sessionID: "conv_a"))
    let group = window.session.tabs.group("conv_a")
    let page = group.open(.newTab)
    let open = try #require(window.tabs.newTabActions(replacing: page.id).openBrowser)
    open()
    #expect(group.tabs.count == 2, "replaced, not added")
    #expect(hasBrowser(group))
  }

}

extension WindowTabsActionsTests {
  private func terminalServer() -> AppServer {
    let server = threeSessionServer()
    server.route("/v1/sessions/conv_a/agent", .json(#"{"terminals":["zsh","bash"]}"#))
    server.route(
      "/v1/sessions/conv_a/resources/terminals",
      .json(#"{"object":"list","data":[],"has_more":false}"#))
    server.route(
      "/v1/sessions/conv_a/resources/terminals", method: "POST",
      .json(#"{"id":"terminal_zsh_1","type":"terminal","metadata":{"running":true}}"#, status: 201))
    return server
  }

  private func created(_ group: TabStore) -> Bool {
    group.tabs.contains {
      $0.content == .terminal(sessionID: "conv_a", terminalID: "terminal_zsh_1")
    }
  }

  @Test("New Shell starts the agent's first terminal, or the one named, and shows it")
  func newShell() async throws {
    let window = try await window(terminalServer())
    window.session.tabs.open(.chat(sessionID: "conv_a"))
    let group = window.session.tabs.group("conv_a")
    await window.tabs.newTerminal(in: "conv_a", named: nil, replacing: nil)
    #expect(window.failures.messages.isEmpty)
    #expect(created(group))
    let body = try #require(
      try window.server.posted("/v1/sessions/conv_a/resources/terminals").first)
    #expect(String(describing: body).contains("zsh"))
    await window.tabs.newTerminal(in: "conv_a", named: "bash", replacing: nil)
    let second = try window.server.posted("/v1/sessions/conv_a/resources/terminals").last
    #expect(String(describing: second).contains("bash"))
    window.tabs.commands.newShell?()
    try await eventually("another request") {
      window.server.requests("POST", "/v1/sessions/conv_a/resources/terminals").count == 3
    }
  }

  @Test("New Shell says why when the agent has no terminals or one refuses to start")
  func newShellFailures() async throws {
    let server = terminalServer()
    server.route("/v1/sessions/conv_a/agent", .json(#"{"terminals":[]}"#))
    let window = try await window(server)
    window.session.tabs.open(.chat(sessionID: "conv_a"))
    await window.tabs.newTerminal(in: "conv_a", named: nil, replacing: nil)
    #expect(
      window.failures.messages
        == ["This session's agent declares no terminals, so none can start here."])

    server.route(
      "/v1/sessions/conv_a/resources/terminals", method: "POST",
      .json(#"{"detail":"no"}"#, status: 500))
    await window.tabs.newTerminal(in: "conv_a", named: "zsh", replacing: nil)
    #expect(window.failures.messages.count == 2)
    #expect(window.failures.messages.last?.isEmpty == false)
    #expect(!created(window.session.tabs.group("conv_a")))
  }

  @Test("Show Terminal shows a ready agent terminal in the chat, else a shell, else starts one")
  func toggleTerminal() async throws {
    let window = try await window(terminalServer())
    window.session.tabs.open(.chat(sessionID: "conv_a"))
    let group = window.session.tabs.group("conv_a")
    window.tabs.toggleTerminal("conv_a")
    try await eventually("a started shell") { created(group) }

    window.session.open("conv_a")
    let terminals = try #require(window.session.terminalStores["conv_a"]?.terminals)
    let shell = TerminalRow(
      terminal: TerminalResource(
        id: "terminal_shell_2", sessionId: "conv_a", terminalName: "zsh", sessionKey: "1",
        running: true, environment: nil, directAttachUrl: nil, isAgentTerminal: false,
        displayLabel: "zsh"),
      status: .idle)
    terminals.apply(terminals: [shell], harness: .notTerminalFirst)
    window.session.tabs.showChat("conv_a")
    window.tabs.toggleTerminal("conv_a")
    #expect(
      group.selected?.content == .terminal(sessionID: "conv_a", terminalID: "terminal_shell_2"))

    window.tabs.toggleTerminal("conv_a")
    #expect(group.selected?.content == .chat(sessionID: "conv_a"), "and back to the chat")
    terminals.apply(terminals: [shell], harness: .ready(terminal: shell.terminal))
    window.tabs.toggleTerminal("conv_a")
    #expect(window.session.tabs.viewMode("conv_a") == .terminal)
    #expect(group.selected?.content == .chat(sessionID: "conv_a"), "in the chat's own tab")
    window.tabs.toggleTerminal("conv_a")
    #expect(window.session.tabs.viewMode("conv_a") == .chat, "and back to the transcript")
  }

  @Test("From the New Tab page, a shell in the session replaces the page")
  func newTabPageTerminal() async throws {
    let window = try await window(terminalServer())
    window.session.tabs.open(.chat(sessionID: "conv_a"))
    let group = window.session.tabs.group("conv_a")
    let page = group.open(.newTab)
    let actions = window.tabs.newTabActions(replacing: page.id)
    actions.newTerminal?("zsh")
    try await eventually("the shell") { created(group) }
    #expect(group.tabs.first { $0.id == page.id }?.content.kind == .terminal, "the same tab")
  }

  @Test("A remote browser opens from the strip and the New Tab page")
  func remoteBrowser() async throws {
    let window = try await window(remote: FixtureRemoteBrowser(latency: .milliseconds(1)))
    window.session.tabs.open(.chat(sessionID: "conv_a"))
    let group = window.session.tabs.group("conv_a")
    let isRemote: (AppTab) -> Bool = {
      if case .remoteBrowser = $0.content { true } else { false }
    }
    let strip = try #require(window.tabs.strip)
    let open = try #require(strip.actions.newRemoteBrowser)
    open("default")
    try await eventually("the remote tab") { group.tabs.contains(where: isRemote) }
    let page = group.open(.newTab)
    let actions = window.tabs.newTabActions(replacing: page.id)
    actions.openRemoteBrowser?("work")
    try await eventually("the second tab") { group.tabs.filter(isRemote).count == 2 }
    #expect(group.tabs.first { $0.id == page.id }?.content.kind == .remoteBrowser, "the same tab")
  }

  @Test("Links open in the app's browser when asked, unless they aren't web pages")
  func linkOpener() async throws {
    let window = try await window()
    final class Opened { var urls: [URL] = [] }
    let opened = Opened()
    let fallback = ExternalURLOpener { url in
      opened.urls.append(url)
      return true
    }
    let web = try #require(URL(string: "https://example.com"))
    let mail = try #require(URL(string: "mailto:a@example.com"))
    let inApp = window.tabs.linkOpener(fallback, inApp: true, in: "conv_a")
    #expect(await inApp.open(web))
    #expect(await inApp.open(mail))
    #expect(window.browser.madeURLs == [web])
    #expect(opened.urls == [mail])
    let outside = window.tabs.linkOpener(fallback, inApp: false, in: "conv_a")
    #expect(await outside.open(web))
    #expect(opened.urls == [mail, web])
  }

  @Test("Sub-agents open in their own window when asked; a Terminal default shows the TUI once")
  func routesFollowPreferences() async throws {
    let window = try await window()
    final class Children { var ids: [String] = [] }
    let children = Children()
    var tabs = window.tabs
    tabs.openInNewWindow = { children.ids.append($0) }
    let apart = tabs.routes(for: "conv_a", subagentsApart: true)
    apart.openChild?("conv_child")
    #expect(children.ids == ["conv_child"])
    #expect(tabs.routes(for: "conv_a", subagentsApart: false).openChild == nil)

    let key = TranscriptViewDefault.key
    let saved = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(saved, forKey: key) }
    UserDefaults.standard.set(TranscriptViewDefault.terminal.rawValue, forKey: key)
    let groups = window.session.tabs
    let routes = tabs.routes(for: "conv_a", subagentsApart: false)
    routes.applyDefaultView?()
    #expect(groups.viewMode("conv_a") == .terminal)
    #expect(groups.group("conv_a").selected?.content == .chat(sessionID: "conv_a"))
    groups.setViewMode(.chat, for: "conv_a")
    routes.applyDefaultView?()
    #expect(groups.viewMode("conv_a") == .chat, "only the first time")

    UserDefaults.standard.set(TranscriptViewDefault.chat.rawValue, forKey: key)
    tabs.routes(for: "conv_b", subagentsApart: false).applyDefaultView?()
    #expect(groups.viewChoice("conv_b").mode == .chat, "a Chat default is a choice too")
  }
}
