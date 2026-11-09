import Foundation
import OmnigentCoreFFI
import OmnigentTerminalStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import OmnigentWorkspaceUI
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

private let pullRequestURL = "https://github.com/o/r/pull/7"
private let githubPath = "/v1/sessions/conv_a/resources/github"
private let githubInfo = #"""
  {"object":"session.github.info","available":true,"branch":"fix","repo":{"name_with_owner":"o/r"},
   "auth":{"authenticated":true},"capabilities":{"label_editing":true,"merging":true},
   "selected_pr_url":"https://github.com/o/r/pull/7","tracking_available":true,
   "prs":[{"url":"https://github.com/o/r/pull/7","host":"github.com","repository":"o/r",
           "number":7,"relationship":"created","state":"OPEN"}],
   "pr":{"number":7,"title":"Fix","state":"OPEN","url":"https://github.com/o/r/pull/7",
         "head_sha":"abc","checks":{"failing":1,"total":1},"labels":[],"merge_state_status":"CLEAN"}}
  """#
private let githubDiff = #"""
  {"object":"session.github.pr_diff","patch":"diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n"}
  """#

/// The Pull Requests tab: choices read from the host and each edit going out.
@MainActor
@Suite("Pull request panel", .serialized, .timeLimit(.minutes(1)))
struct PullRequestPanelTests {
  private func server() -> AppServer {
    let server = AppServer()
    server.route(
      "/v1/info",
      .json(#"{"single_user":true,"accounts_enabled":false,"session_pull_requests":true}"#))
    server.route(
      "/v1/sessions/conv_a/pull-requests",
      .json(#"{"object":"list","data":[],"has_more":false,"synced":true}"#))
    server.route(githubPath, .json(githubInfo))
    server.route("\(githubPath)/prs", method: "POST", .json(githubInfo))
    server.route("\(githubPath)/diff", .json(githubDiff))
    server.route(
      "\(githubPath)/labels", method: "GET",
      .json(#"{"data":[{"name":"bug","color":"d73a4a"}],"has_more":false}"#))
    server.route(
      "\(githubPath)/labels", method: "POST",
      .json(#"{"labels":[{"name":"bug","color":"d73a4a"}]}"#))
    server.route(
      "\(githubPath)/reviewers", method: "GET",
      .json(
        #"{"data":[{"login":"ann","kind":"user","name":"Ann"},{"login":"core","kind":"team"}]}"#))
    server.route(
      "\(githubPath)/reviewers", method: "POST",
      .json(#"{"reviewers":[{"login":"ann","kind":"user","state":"PENDING"}]}"#))
    server.route(
      "\(githubPath)/merge-options",
      .json(#"{"methods":["squash","merge"],"default":"merge"}"#))
    server.route("\(githubPath)/merge", method: "POST", .json("{}"))
    server.route(
      "\(githubPath)/comments", method: "POST",
      .json(#"{"comment":{"author":"me","body":"hi","url":"c"}}"#))
    return server
  }

  private func panel(_ server: AppServer) async throws -> SessionPanelStore {
    let connection = try await signedInStore(server)
    return try #require(connection.makePanelStore("conv_a"))
  }

  @Test("Opening a pull request shows its files, and the list and Refresh read again")
  func openAndRefresh() async throws {
    let server = server()
    let panel = try await panel(server)
    let actions = PullRequestPanelSlots.extras(panel, canEdit: true).actions
    actions.select?(pullRequestURL)
    try await eventually("the detail") { panel.files.value != nil }
    let changes = try #require(PullRequestPanelSlots.extras(panel, canEdit: true).changes)
    let shown = OffscreenWindow(changes, width: 600, height: 400)
    defer { shown.close() }
    #expect(try shown.shownText().contains { $0.contains("a.txt") })

    let before = server.requests("GET", githubPath).count
    actions.refresh?()
    try await eventually("the reload") { server.requests("GET", githubPath).count > before }
    actions.showList?()
    #expect(panel.openPullRequest == nil)
    #expect(PullRequestPanelSlots.extras(panel, canEdit: true).changes == nil)
  }

  @Test("Changes say when they can't load, are unavailable, or there are none")
  func changesStates() async throws {
    let server = server()
    server.route("\(githubPath)/diff", .json(#"{"detail":"no"}"#, status: 500))
    let panel = try await panel(server)
    await panel.showPullRequest(pullRequestURL)
    var view = try #require(PullRequestPanelSlots.extras(panel, canEdit: true).changes)
    var shown = OffscreenWindow(view, width: 600, height: 400)
    #expect(try shown.shows("Couldn't Load the Changes"))
    shown.close()

    server.route(
      "\(githubPath)/diff",
      .json(
        #"{"object":"session.github.pr_diff","patch":"","unavailable_reason":"pr_outside_workspace"}"#
      ))
    await panel.reloadDetail()
    view = try #require(PullRequestPanelSlots.extras(panel, canEdit: true).changes)
    shown = OffscreenWindow(view, width: 600, height: 400)
    #expect(try shown.shows("Diff Unavailable"))
    shown.close()

    server.route("\(githubPath)/diff", .json(#"{"object":"session.github.pr_diff","patch":""}"#))
    await panel.reloadDetail()
    view = try #require(PullRequestPanelSlots.extras(panel, canEdit: true).changes)
    shown = OffscreenWindow(view, width: 600, height: 400)
    defer { shown.close() }
    #expect(try shown.shows("No Changes"))
  }

  @Test("Labels, reviewers and merge methods read as chips, the repository's default first")
  func choices() async throws {
    let panel = try await panel(server())
    await panel.showPullRequest(pullRequestURL)
    let actions = PullRequestPanelSlots.extras(panel, canEdit: true).actions
    actions.loadLabels?()
    actions.loadReviewers?()
    actions.loadMergeMethods?()
    try await eventually("the choices") {
      panel.repositoryLabels.value != nil && panel.reviewCandidates.value != nil
        && panel.mergeOptions.value != nil
    }
    let extras = PullRequestPanelSlots.extras(panel, canEdit: true)
    guard case .loaded(let labels) = extras.labelChoices,
      case .loaded(let reviewers) = extras.reviewerChoices,
      case .loaded(let methods) = extras.mergeMethods
    else {
      Issue.record("all three choices are read")
      return
    }
    #expect(labels.map(\.title) == ["bug"])
    #expect(reviewers.map(\.title) == ["ann", "core"])
    #expect(reviewers.map(\.detail) == ["Ann", nil])
    #expect(reviewers.map(\.systemImage) == ["person", "person.2"])
    #expect(methods.map(\.id) == ["merge", "squash"])
  }

  @Test("Each edit goes to the host, and a read-only viewer has none of them")
  func edits() async throws {
    let server = server()
    let panel = try await panel(server)
    await panel.showPullRequest(pullRequestURL)
    let actions = PullRequestPanelSlots.extras(panel, canEdit: true).actions
    actions.setLabel?("bug", true)
    try await eventually("the label") {
      !server.requests("POST", "\(githubPath)/labels").isEmpty
    }
    actions.setReviewer?("no such reviewer", true)
    actions.setReviewer?(PullRequestDetailAdapter.reviewerID(login: "ann", kind: .user), true)
    try await eventually("the reviewer") {
      !server.requests("POST", "\(githubPath)/reviewers").isEmpty
    }
    #expect(server.requests("POST", "\(githubPath)/reviewers").count == 1)

    final class Finished { var results: [Bool] = [] }
    let finished = Finished()
    actions.comment?("hi") { finished.results.append($0) }
    try await eventually("the comment") { finished.results == [true] }
    actions.merge?("no such method")
    actions.merge?("squash")
    try await eventually("the merge") {
      !server.requests("POST", "\(githubPath)/merge").isEmpty
    }
    #expect(server.requests("POST", "\(githubPath)/merge").count == 1)
    actions.link?(pullRequestURL) { finished.results.append($0) }
    try await eventually("the link") { finished.results.count == 2 }

    let readOnly = PullRequestPanelSlots.extras(panel, canEdit: false).actions
    #expect(readOnly.merge == nil)
    #expect(readOnly.comment == nil)
    #expect(readOnly.select != nil)
  }
}

/// The right panel's menus and tabs, and turning decisions from the core into cards.
@MainActor
@Suite("Workspace panel slots", .serialized, .timeLimit(.minutes(1)))
struct WorkspacePanelSlotsWiringTests {
  private func routes(_ opened: OpenedItems) -> ConversationTabRoutes {
    var routes = ConversationTabRoutes(
      openHarness: { opened.items.append("harness") },
      openTerminal: { opened.items.append("terminal \($0)") },
      openSideChat: { _, _ in },
      openSession: { _ in })
    routes.newTerminal = { opened.items.append("new \($0 ?? "")") }
    routes.openBrowser = { opened.items.append("browser") }
    return routes
  }

  private func shell(_ id: String) -> TerminalRow {
    TerminalRow(
      terminal: TerminalResource(
        id: id, sessionId: "conv_a", terminalName: "zsh", sessionKey: "1", running: true,
        environment: nil, directAttachUrl: nil, isAgentTerminal: false, displayLabel: "zsh 1"),
      status: .idle)
  }

  @Test("Open New lists the agent's terminal, its shells, running shells and the browser")
  func openNewMenu() async throws {
    let session = try await signedInSession(threeSessionServer())
    session.open("conv_a")
    let terminals = try #require(session.terminalStores["conv_a"])
    let row = shell("terminal_a")
    terminals.terminals.apply(terminals: [row], harness: .ready(terminal: row.terminal))
    let opened = OpenedItems()
    var slots = WorkspacePanelSlots(
      workspace: nil, panel: nil, terminals: terminals, tabRoutes: routes(opened),
      terminalNames: .names(["zsh"]), permissionLevel: 4, composer: nil)
    slots.newSideChat = { opened.items.append("side chat") }
    let openNew = try #require(slots.slots.openNew)
    let menu = openNew()
    #expect(menu.map(\.id) == ["chat", "new", "running", "browser"])
    for item in menu.flatMap(\.items) { item.action() }
    #expect(
      opened.items == [
        "side chat", "harness", "new zsh", "terminal terminal_a", "browser",
      ])
  }

  @Test("Selecting and closing a panel tab act on the document it names")
  func documentTabs() async throws {
    let workspace = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
    await workspace.open(.file(path: "README.md", line: nil))
    await workspace.open(.diff(path: "src/lib.rs"))
    let documents = WorkspacePanelSlots.documents(workspace, actions: .none)
    documents.select("nothing")
    documents.select("file:README.md")
    try await eventually("the selection") { workspace.document?.tabID == "file:README.md" }
    documents.close("nothing")
    #expect(workspace.openDocuments.count == 2)
    documents.close("diff:src/lib.rs")
    try await eventually("the close") { workspace.openDocuments.count == 1 }
  }

  @Test("A README preview renders through the transcript's Markdown")
  func markdownPreview() async throws {
    let workspace = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
    await workspace.open(.file(path: "README.md", line: nil))
    let documents = WorkspacePanelSlots.documents(workspace, actions: .none)
    let screen = OffscreenWindow(documents.content, width: 700, height: 500)
    defer { screen.close() }
    try await pause(screen, .milliseconds(100))
    #expect(try !screen.shownText().isEmpty)
  }

  @Test("A form field and its kinds reach the card")
  func formFields() {
    let kinds: [(OmnigentCoreFFI.FieldKind, OmnigentUIComponents.FieldKind)] = [
      (.text, .text), (.number, .number), (.integer, .integer), (.boolean, .boolean),
      (.singleChoice, .singleChoice), (.multipleChoice, .multipleChoice),
    ]
    for (kind, expected) in kinds {
      #expect(OmnigentUIComponents.FieldKind(kind) == expected)
    }
    let field = OmnigentCoreFFI.FormField(
      key: "k", title: "T", detail: "D", kind: .singleChoice, required: true,
      options: [OmnigentCoreFFI.FormOption(value: "v", label: "L", detail: "O")],
      allowsCustom: true, isSecret: true, minimum: 1, maximum: 2, minLength: 3, maxLength: 4,
      minItems: 5, maxItems: 6)
    let shown = OmnigentUIComponents.FormField(field)
    #expect(shown.key == "k")
    #expect(shown.options.map(\.label) == ["L"])
    #expect(shown.isSecret)
    #expect(shown.maxItems == 6)
    #expect(OmnigentUIComponents.PersistMode(.session) == .session)
    #expect(OmnigentUIComponents.PersistMode(.always) == .always)
  }

  @Test("A shell approval and an Antigravity permission reach the card")
  func permissionDetails() {
    let shown = OmnigentUIComponents.PermissionOptions(
      OmnigentCoreFFI.PermissionOptions(
        allowAllEdits: false, allowAutoMode: false, permissionDirectories: [],
        rememberLabel: nil, plan: nil,
        command: CommandApproval(command: "ls", cwd: "/w", reason: "look"),
        execPolicyAmendment: nil, persistModes: [.session],
        antigravity: AntigravityPermission(actionDescription: "Run", alwaysAllowPattern: "ls *"),
        fileChanges: []))
    #expect(shown.command?.command == "ls")
    #expect(shown.command?.cwd == "/w")
    #expect(shown.antigravity?.alwaysAllowPattern == "ls *")
    #expect(shown.persistModes == [.session])
  }
}

/// What a panel's menu opened, in order.
@MainActor
private final class OpenedItems {
  var items: [String] = []
}
