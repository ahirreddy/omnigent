import AppKit
import Foundation
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

/// A session's revision of changed files, told to the container from outside.
@MainActor
@Observable
private final class RevisionSource {
  var revision = 0
}

/// A conversation in a window whose changed-files revision moves.
private struct RevisingConversation: View {
  let source: RevisionSource
  let make: @MainActor (Int) -> ConversationContainer

  var body: some View {
    make(source.revision)
  }
}

extension ConversationWiringTests {
  private func attachment(reference: String?) -> OmnigentUIComponents.Attachment {
    OmnigentUIComponents.Attachment(
      id: "a", kind: .file, title: "notes.txt", reference: reference, mimeType: nil,
      isEmbedded: false)
  }

  @Test("An attachment with an address opens it; one without does nothing")
  func openingAttachments() async throws {
    let wired = try await wired()
    let actions = wired.container.actions
    actions.openAttachment?(attachment(reference: "https://example.com/notes.txt"))
    actions.openAttachment?(attachment(reference: nil))
    try await eventually("the page") { !wired.opened.urls.isEmpty }
    #expect(wired.opened.urls.map(\.absoluteString) == ["https://example.com/notes.txt"])
  }

  @Test("Removing an attachment takes that chip off the draft; a chip without a number stays")
  func removingAttachments() async throws {
    let wired = try await wired()
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).txt")
    try Data("hi".utf8).write(to: file)
    defer {
      do {
        try FileManager.default.removeItem(at: file)
      } catch {
        Issue.record(error, "could not remove \(file.path)")
      }
    }
    let actions = wired.container.composerActions
    actions.addAttachments?([.file(url: file)])
    try await eventually("the chip") { !wired.store.composer.attachments.items.isEmpty }
    let chip = try #require(wired.store.composer.attachments.items.first)
    var attached = DraftAttachment(
      id: "not a number", title: "notes.txt", kind: .file, byteCount: 2, state: .ready)
    actions.removeAttachment?(attached)
    #expect(wired.store.composer.attachments.items.count == 1)
    attached.id = String(chip.id)
    actions.removeAttachment?(attached)
    #expect(wired.store.composer.attachments.items.isEmpty)
  }

  @Test("A session's own agent isn't offered; choosing one it can't switch to says why")
  func switchingAgents() async throws {
    let wired = try await wired()
    let composer = wired.store.composer
    composer.rules.harnessOptions = [
      HarnessOption(
        choice: OmnigentCoreFFI.HarnessChoice(
          id: "ag_other", name: "Other", harness: "other", builtin: true, title: "Other",
          preservesHistory: true),
        unavailableReason: "Other can't run on this machine.", isCurrent: false)
    ]
    wired.container.switchHarness(to: "ag_other")
    #expect(wired.container.failures == ["Other can't run on this machine."])
    wired.server.route(
      "/v1/sessions/conv_a/events", method: "POST", .json(#"{"queued":false}"#, status: 202))
    wired.container.switchHarness(to: "ag_claude")
    #expect(wired.container.failures.count == 1, "an agent it can move to reports nothing")
  }

  @Test("Fork From Here does nothing for a message still being written")
  func forkingAStreamingMessage() async throws {
    let server = threeSessionServer()
    let source = sessionRow("conv_a", host: "mac", workspace: "/w", updatedAt: 9)
      .replacingOccurrences(of: "\"host_id\"", with: "\"agent_id\":\"ag_claude\",\"host_id\"")
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(source)],"has_more":false}"#))
    let wired = try await wired(server)
    let forkable = wired.container.forkable(ConversationActions())
    let row = OmnigentUIComponents.Row(id: "r", role: .user, text: "hello")
    forkable.forkFrom?(row)
    #expect(wired.container.forkFlow.viewState == nil)

    var settled = OmnigentUIComponents.Row(id: "a", role: .assistant, text: "done")
    settled.responseId = "resp_1"
    forkable.forkFrom?(settled)
    try await eventually("the sheet") { wired.container.forkFlow.viewState != nil }
    wired.container.forkFlow.cancel()
    forkable.forkToRecover?(true)
    try await eventually("the recovery sheet") { wired.container.forkFlow.viewState != nil }
  }

  @Test("A file change the agent made refreshes the changed files the panel shows")
  func changedFilesRefresh() async throws {
    let wired = try await wired()
    let data = SampleWorkspaceDataSource()
    let workspace = WorkspaceBrowserModel(source: data)
    let source = RevisionSource()
    let store = wired.store
    let screen = OffscreenWindow(
      RevisingConversation(source: source) { revision in
        ConversationContainer(
          conversation: store, summary: nil, terminals: nil, workspace: workspace, panel: nil,
          changedFilesRevision: revision, navigation: SessionCommandActions(),
          opener: ExternalURLOpener { _ in true }, openSession: { _ in }, retry: {}, server: nil,
          tabRoutes: nil, makeForkStore: { nil }, failureList: ConversationFailures(),
          forkFlow: ForkFlow(), livenessSheets: SessionLivenessSheets())
      },
      width: 1000, height: 600)
    defer { screen.close() }
    try await pause(screen)
    let before = data.requests.count(where: { $0.hasPrefix("changes") })
    source.revision += 1
    try await settle(screen, until: "the changes") {
      data.requests.count(where: { $0.hasPrefix("changes") }) > before
    }
  }

  @Test("A session's agent details show, and background work shows in the composer's tray")
  func agentInfoAndTray() async throws {
    let wired = try await wired()
    wired.store.apply(
      revision: 2,
      change: TranscriptChange(
        rows: [], header: nil,
        sections: [ConversationFixtures.section("status", details: [("background", "2")])]))
    let screen = OffscreenWindow(wired.container, width: 1000, height: 600)
    defer { screen.close() }
    try await settle(screen, until: "the tray") { (try? screen.shownText())?.isEmpty == false }
    #expect(
      SessionToolsAdapter.indicators(
        wired.store, screen: ConversationAdapter.screenState(wired.store, summary: nil)
      ).backgroundTasks == 2)
  }

  @Test("Resume reports a refusal, and dismissing clears it")
  func resumeAndDismiss() async throws {
    let wired = try await wired()
    let actions = wired.container.actions
    actions.resume?()
    try await eventually("the failure") { !wired.store.errors.isEmpty }
    actions.dismissError?()
    #expect(wired.store.errors.isEmpty)
    actions.loadOlder?()
    #expect(!wired.store.isLoadingOlderHistory, "nothing older to read")
  }

  @Test("Choosing a model or effort before the session's settings arrive says so")
  func modelAndEffort() async throws {
    let wired = try await wired()
    let actions = wired.container.composerActions
    let composer = wired.store.composer
    actions.selectModel?("opus")
    try await eventually("the refusal") { composer.configurationError != nil }
    actions.dismissDeliveryError?()
    #expect(composer.configurationError == nil)
    actions.selectEffort?("high")
    try await eventually("the refusal") { composer.configurationError != nil }
    actions.selectAgent?("agent")
    actions.acknowledgeUncertainDelivery?()
    #expect(composer.lastError == nil, "there's no unclear send to acknowledge")
  }

  @Test("Recalling a prompt reads what was sent, and the queue follows the turn")
  func recallPrompts() async throws {
    let wired = try await wired()
    wired.store.apply(
      revision: 2,
      change: TranscriptChange(
        rows: [.insert(index: 0, row: ConversationFixtures.userRow("a", text: "sent"))],
        header: nil, sections: []))
    let extras = wired.container.extras
    #expect(extras.history.prompts?() == ["sent"])
    wired.store.composer.text = "next"
    extras.queueDraft?()
    try await eventually("the queue to try it") {
      wired.store.composer.queue.items.allSatisfy { $0.state != .queued }
    }
  }

  /// A session a person can fork: its row names an agent the server knows.
  private func forkableSession() async throws -> Wired {
    let server = threeSessionServer()
    let source = sessionRow("conv_a", host: "mac", workspace: "/w", updatedAt: 9)
      .replacingOccurrences(of: "\"host_id\"", with: "\"agent_id\":\"ag_claude\",\"host_id\"")
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(source)],"has_more":false}"#))
    return try await wired(server)
  }

  @Test("The session menu's Fork opens the sheet for the whole session")
  func forkFromTheMenu() async throws {
    let wired = try await forkableSession()
    let source = try #require(wired.container.summary)
    wired.container.forkable(wired.container.sessionActions).fork?(
      OmnigentUIComponents.SessionSummary(source))
    try await eventually("the sheet") { wired.container.forkFlow.viewState != nil }
  }

  @Test("A fork that was made but couldn't start says so in the chat's alert")
  func forkThatCouldNotStart() async throws {
    let wired = try await forkableSession()
    wired.server.route(
      "/v1/sessions/conv_a/fork", method: "POST",
      .json(#"{"id":"conv_f","status":"idle","created_at":5,"permission_level":4}"#, status: 201))
    wired.server.route(
      "/v1/hosts/mac/runners", method: "POST", .json(#"{"detail":"busy"}"#, status: 500))
    wired.container.forkSession?()
    try await eventually("the sheet") { wired.container.forkFlow.viewState != nil }
    wired.container.forkActions.forkWith(
      ForkChoices(agentID: "ag_claude", directory: "/w", start: true, hostID: "mac"))
    try await eventually("the alert") { !wired.container.failures.isEmpty }
    #expect(wired.container.failures.first?.hasPrefix("The fork was created") == true)
    #expect(wired.opened.sessions == ["conv_f"])
  }

  @Test("A side chat says whose it is")
  func sideChatComposer() async throws {
    var settings = ConversationFixtures.settings()
    settings.sideChatSourceId = "conv_b"
    let wired = try await wired(settings: settings)
    let screen = OffscreenWindow(wired.container, width: 1000, height: 600)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Side chat of")
  }

  @Test("The session menu names who created this session and which it belongs to")
  func menuContextNamesThem() async throws {
    let server = threeSessionServer()
    let child = sessionRow("conv_child", host: "mac", workspace: "/w", updatedAt: 40)
      .replacingOccurrences(
        of: "\"host_id\"",
        with:
          "\"labels\":{\"omnigent.created_by_session_id\":\"conv_a\"},\"parent_session_id\":\"conv_b\",\"host_id\""
      )
    let parentA = sessionRow("conv_a", host: "mac", workspace: "/w", updatedAt: 30)
    let parentB = sessionRow("conv_b", host: "mac", workspace: "/w", updatedAt: 20)
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(child),\#(parentA),\#(parentB)],"has_more":false}"#))
    let connection = try await signedInStore(server)
    let list = connection.sessionList
    try await eventually("the list") { list.isLoaded }
    let context = ConversationContainer.menuContext(list, session: list.session("conv_child"))
    #expect(context.createdBy?.id == "conv_a")
    #expect(context.parent?.id == "conv_b")
  }
}

@Test("The saved transcript carries the session's text")
func transcriptDocument() throws {
  let document = TranscriptExport(text: "{\"line\":1}\n")
  #expect(document.text == "{\"line\":1}\n")
  #expect(TranscriptExport.readableContentTypes == [TranscriptExport.contentType])
}
