import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentWorkspaceUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// What the conversation's controls do to the session, with the header a test gives it.
@MainActor
@Suite("Conversation wiring", .serialized, .timeLimit(.minutes(1)))
struct ConversationWiringTests {
  private final class Opened {
    var urls: [URL] = []
    var sessions: [String] = []
    var succeeds = true
  }

  private struct Wired {
    let container: ConversationContainer
    let store: ConversationStore
    let opened: Opened
    let server: AppServer
    let sheets: SessionLivenessSheets
  }

  /// The owner's session `conv_a`, on a machine the server knows, with `settings`.
  private func wired(
    _ server: AppServer = threeSessionServer(), settings: OmnigentCoreFFI.SessionSettings? = nil,
    tabRoutes: ConversationTabRoutes? = nil
  ) async throws -> Wired {
    SystemSideEffects.install()
    let connection = try await signedInStore(server)
    try await eventually("the list") { connection.sessionList.isLoaded }
    let store = ConversationStore(sessionID: "conv_a", core: try #require(connection.core))
    let header = SessionHeader(
      id: "conv_a", title: "A", status: .idle, readOnly: false, archived: false,
      permissionLevel: 4, failureMessage: nil,
      settings: settings ?? ConversationFixtures.settings())
    store.apply(revision: 1, change: TranscriptChange(rows: [], header: header, sections: []))
    let opened = Opened()
    let sheets = SessionLivenessSheets()
    let container = ConversationContainer(
      conversation: store, summary: connection.sessionList.session("conv_a"), terminals: nil,
      workspace: nil, panel: nil, changedFilesRevision: 0, navigation: SessionCommandActions(),
      opener: ExternalURLOpener { url in
        opened.urls.append(url)
        return opened.succeeds
      },
      openSession: { opened.sessions.append($0) }, retry: {},
      server: connection.connectedServer, tabRoutes: tabRoutes,
      makeForkStore: { connection.makeForkStore() }, failureList: ConversationFailures(),
      forkFlow: ForkFlow(), livenessSheets: sheets)
    return Wired(
      container: container, store: store, opened: opened, server: server, sheets: sheets)
  }

  private func settings(hostID: String?, hostOnline: Bool, runnerBound: Bool)
    -> OmnigentCoreFFI.SessionSettings
  {
    OmnigentCoreFFI.SessionSettings(
      agentId: "ag_claude", harness: "claude-native", wrapper: nil, modelOverride: .notReported,
      baseModel: nil, reasoningEffort: .notReported, modelOptions: [], hostId: hostID,
      hostOnline: hostOnline, runnerOnline: false, runnerBound: runnerBound, hostResumable: nil,
      parentId: nil, sideChatSourceId: nil, routingMode: nil)
  }

  private func row(recovery: OmnigentCoreFFI.FailureRecovery?) -> OmnigentUIComponents.Row {
    let activity = OmnigentCoreFFI.Activity(
      kind: .error, title: "Response error", summary: "", status: "failed", details: [],
      isFailure: true, recovery: recovery)
    return OmnigentUIComponents.Row(
      OmnigentCoreFFI.Row(
        id: "e", role: .tool, text: "", isStreaming: false, activity: activity, attachments: [],
        callId: nil, responseId: nil, interrupted: false, author: nil, agent: nil, createdAt: 1,
        isEphemeral: false, isActivityOnly: false))
  }

  @Test("Switch Host lists the hosts, browses them and moves the session")
  func switchingHost() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/hosts/mac/runners", method: "POST", .json(#"{"runner_id":"r2"}"#, status: 201))
    let wired = try await wired(
      server, settings: settings(hostID: "box", hostOnline: false, runnerBound: true))
    var live = SessionLivenessActions()
    wired.container.addHostMoves(to: &live, sheets: SessionLivenessSheets())
    let route = try #require(live.switchHost)
    #expect(live.resume == nil)
    if case .switchHost(let current) = route.kind {
      #expect(current == "box")
    } else {
      Issue.record("the route must be Switch Host")
    }

    let hosts = try await route.actions.loadHosts().get()
    #expect(hosts.map(\.id) == ["mac", "box"])
    #expect(await route.actions.home("nowhere") == nil, "no home starts the directory empty")
    let listing = try await route.actions.browse("mac", nil).get()
    #expect(listing.folders.map(\.name) == ["src"])
    #expect((try? await route.actions.browse("nowhere", nil).get()) == nil)

    let outcome = await route.actions.submit(HostMoveChoice(hostID: "mac", workspace: "/work"))
    #expect(outcome == .moved)
    #expect(!server.requests("POST", "/v1/hosts/mac/runners").isEmpty)
  }

  @Test("Switch Host reports a refused move, and a session it left stranded")
  func switchingHostFails() async throws {
    let server = threeSessionServer()
    server.route("/v1/hosts/mac/runners", method: "POST", .json(#"{"detail":"no"}"#, status: 500))
    let wired = try await wired(
      server, settings: settings(hostID: "box", hostOnline: false, runnerBound: true))
    var live = SessionLivenessActions()
    wired.container.addHostMoves(to: &live, sheets: SessionLivenessSheets())
    let route = try #require(live.switchHost)
    let stranded = await route.actions.submit(HostMoveChoice(hostID: "mac", workspace: "/work"))
    if case .stranded = stranded {} else { Issue.record("got \(stranded)") }
    let failed = await route.actions.submit(HostMoveChoice(hostID: "gone", workspace: "/work"))
    if case .failed = failed {} else { Issue.record("got \(failed)") }
    server.route("/v1/hosts", .json(#"{"detail":"down"}"#, status: 500))
    #expect((try? await route.actions.loadHosts().get()) == nil)
  }

  @Test("A send into a session on no machine opens Resume, and the draft goes once it starts")
  func resumingSendsTheDraft() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/hosts/mac/runners", method: "POST", .json(#"{"runner_id":"r2"}"#, status: 201))
    let wired = try await wired(
      server, settings: settings(hostID: nil, hostOnline: false, runnerBound: false))
    let sheets = wired.sheets
    var live = SessionLivenessActions()
    wired.container.addHostMoves(to: &live, sheets: sheets)
    let route = try #require(live.resume)
    #expect(live.switchHost == nil)

    wired.container.composerActions.send()
    #expect(sheets.shown == .resume)
    #expect(sheets.sendsDraftOnResume)

    var choice = HostMoveChoice(hostID: "mac", workspace: "/work")
    choice.branch = "feature"
    choice.baseBranch = "main"
    #expect(await route.actions.submit(choice) == .moved)
    #expect(!sheets.sendsDraftOnResume, "the draft went")
    let launch = try #require(try server.posted("/v1/hosts/mac/runners").last)
    #expect("\(launch)".contains("feature"))
  }

  @Test("A resume the host refuses stays in the sheet with the reason")
  func aRefusedResume() async throws {
    let wired = try await wired(
      settings: settings(hostID: nil, hostOnline: false, runnerBound: false))
    let sheets = SessionLivenessSheets()
    sheets.sendsDraftOnResume = true
    var live = SessionLivenessActions()
    wired.container.addHostMoves(to: &live, sheets: sheets)
    let route = try #require(live.resume)
    let outcome = await route.actions.submit(HostMoveChoice(hostID: "gone", workspace: "/work"))
    if case .failed = outcome {} else { Issue.record("got \(outcome)") }
    #expect(sheets.sendsDraftOnResume, "the draft waits")
  }

  @Test("A header that hasn't arrived offers no moves and holds no send")
  func noHeaderYet() async throws {
    let wired = try await wired()
    let empty = ConversationStore(sessionID: "conv_b", core: wired.store.core)
    var live = SessionLivenessActions()
    let sheets = SessionLivenessSheets()
    let container = ConversationContainer(
      conversation: empty, summary: nil, terminals: nil, workspace: nil, panel: nil,
      changedFilesRevision: 0, navigation: SessionCommandActions(),
      opener: ExternalURLOpener { _ in true }, openSession: { _ in }, retry: {})
    container.addHostMoves(to: &live, sheets: sheets)
    #expect(live.sheets === sheets)
    #expect(live.switchHost == nil && live.resume == nil)
    #expect(!container.holdsSendForResume(sheets))
  }

  @Test("Open Sign-In Link opens the waiting page and shows its code; or says it's over")
  func signInLink() async throws {
    let server = threeSessionServer()
    let wired = try await wired(server)
    let open = wired.container.openSignIn

    server.route("/v1/sessions/conv_a/sign-in-link", .json(#"{"detail":"no"}"#, status: 500))
    if case .failed = await open() {} else { Issue.record("a failed read must say so") }

    server.route("/v1/sessions/conv_a/sign-in-link", .json(#"{"pending":false}"#))
    #expect(await open() == .notPending)

    SystemSideEffects.reset()
    server.route(
      "/v1/sessions/conv_a/sign-in-link",
      .json(#"{"pending":true,"url":"https://login.example/x","code":"ABCD"}"#))
    #expect(await open() == .opened(code: "ABCD"))
    #expect(
      SystemSideEffects.record.openedURLs.map(\.absoluteString) == ["https://login.example/x"])
  }

  @Test("A link that can't open says so in the alert")
  func openingLinks() async throws {
    let wired = try await wired()
    let actions = wired.container.actions
    let url = try #require(URL(string: "https://example.com/a"))
    actions.openURL?(url)
    try await eventually("the link") { wired.opened.urls == [url] }
    #expect(wired.container.failures.isEmpty)

    wired.opened.succeeds = false
    actions.openURL?(url)
    try await eventually("the alert") { !wired.container.failures.isEmpty }
    #expect(wired.container.failures == ["Could not open https://example.com/a."])
  }

}

extension ConversationWiringTests {
  @Test("Retry on a failed turn waits for a running one, or asks to carry on")
  func retryingATurn() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions/conv_a/events", method: "POST", .json(#"{"queued":false}"#, status: 202))
    let wired = try await wired(server)
    let actions = wired.container.actions
    actions.retryFailedTurn?(row(recovery: nil))
    #expect(server.requests("POST", "/v1/sessions/conv_a/events").isEmpty, "nothing to recover")

    actions.retryFailedTurn?(row(recovery: .continue))
    try await eventually("the retry") {
      !server.requests("POST", "/v1/sessions/conv_a/events").isEmpty
    }
    wired.store.apply(
      revision: 2,
      change: TranscriptChange(
        rows: [],
        header: SessionHeader(
          id: "conv_a", title: "A", status: .running, readOnly: false, archived: false,
          permissionLevel: 4, failureMessage: nil, settings: ConversationFixtures.settings()),
        sections: []))
    actions.retryFailedTurn?(row(recovery: .resume))
    #expect(wired.container.failures == ["Wait for the current turn to finish before retrying."])
  }

  @Test("Stop reaches the session; a file that can't be read is reported; a bad chip is ignored")
  func composerControls() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions/conv_a/events", method: "POST", .json(#"{"queued":false}"#, status: 202))
    let wired = try await wired(server)
    let actions = wired.container.composerActions
    actions.interrupt?()
    try await eventually("the stop") {
      !server.requests("POST", "/v1/sessions/conv_a/events").isEmpty
    }
    let missing = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).txt")
    actions.addAttachments?([.file(url: missing)])
    try await eventually("the report") { !wired.container.failures.isEmpty }
    #expect(wired.container.failures.first?.contains(missing.lastPathComponent) == true)
    actions.dismissDeliveryError?()
  }

  @Test("Export reads the transcript, and a failure is reported")
  func exporting() async throws {
    let wired = try await wired()
    wired.container.exportTranscript()
    try await eventually("the report") { !wired.container.failures.isEmpty }
    #expect(wired.container.failures.first?.hasPrefix("Could not export the transcript") == true)
  }

  @Test("Fork from a message opens the sheet at that message; forking opens the copy")
  func forkingFromAMessage() async throws {
    let server = threeSessionServer()
    let source = sessionRow("conv_a", host: "mac", workspace: "/w", updatedAt: 9)
    server.route(
      "/v1/sessions", method: "GET",
      .json(
        #"{"object":"list","data":[\#(source.replacingOccurrences(of: "\"host_id\"", with: "\"agent_id\":\"ag_claude\",\"host_id\""))],"has_more":false}"#
      ))
    server.route(
      "/v1/sessions/conv_a/fork", method: "POST",
      .json(#"{"id":"conv_f","status":"idle","created_at":5,"permission_level":4}"#, status: 201))
    let wired = try await wired(server)
    let forkable = wired.container.forkable(ConversationActions())
    #expect(forkable.forkFrom != nil)
    #expect(forkable.forkToRecover != nil)
    #expect(wired.container.forkSession != nil)

    wired.container.forkSession?()
    try await Task.sleep(for: .milliseconds(30))
    let actions = wired.container.forkActions
    actions.selectionChanged?("ag_claude", "mac")
    actions.forkWith(
      ForkChoices(agentID: "ag_claude", directory: "/w", start: false, hostID: "mac"))
    try await eventually("the copy") { wired.opened.sessions == ["conv_f"] }
    actions.cancel()
  }

  @Test("A row's side question and a sub-agent open as tabs where tabs route them")
  func routedRows() async throws {
    final class Routed {
      var sideChats: [String] = []
      var sessions: [String] = []
    }
    let routed = Routed()
    let routes = ConversationTabRoutes(
      openHarness: {}, openTerminal: { _ in },
      openSideChat: { id, _ in routed.sideChats.append(id) },
      openNewSideChat: nil, openSession: { routed.sessions.append($0) })
    let wired = try await wired(tabRoutes: routes)
    let actions = wired.container.routed(ConversationActions())
    actions.openSideChat?(row(recovery: nil))
    actions.openChild?("conv_child")
    actions.openSession?("conv_b")
    #expect(routed.sideChats == ["e"])
    #expect(routed.sessions == ["conv_child", "conv_b"])
    wired.container.toolRoutes.showPullRequests()
    wired.container.toolRoutes.showGoal()
    wired.container.toolRoutes.report("A problem")
    #expect(wired.container.failures == ["A problem"])
  }

  @Test("The @ menu lists the browsed folder, and deeper paths for a filter")
  func mentionSearch() async throws {
    let workspace = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
    let search = ConversationContainer.mentionSearch(workspace)
    #expect(try await !search("").isEmpty)
    await #expect(throws: CoreError.self) { try await search("nowhere/at/all") }
  }

  @Test("The session menu's context names its projects, parent and creator")
  func menuContext() async throws {
    let connection = try await signedInStore(threeSessionServer())
    let list = connection.sessionList
    try await eventually("the list") { list.isLoaded }
    let sideChat = ConversationContainer.menuContext(list, session: nil, sideChatOf: "conv_b")
    #expect(sideChat.parent?.id == "conv_b")
    #expect(ConversationContainer.menuContext(list, session: nil).projects.isEmpty)
    list.projects = [ProjectSummary(id: "p1", name: "Alpha", icon: nil)]
    let context = ConversationContainer.menuContext(list, session: list.session("conv_a"))
    #expect(context.projects.map(\.name) == ["Alpha"])
    #expect(context.projectID == nil)
  }
}
