import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// What the tools asked the screen around the composer to do.
@MainActor
private final class RouteLog {
  var openedChats: [(draft: String, sends: Bool)] = []
  var reports: [String] = []
  var goalsShown = 0
  var newSessions = 0

  func routes(sideChats: Bool = true) -> SessionToolsAdapter.Routes {
    var open: (@MainActor (String, Bool) -> Void)?
    if sideChats {
      open = { draft, sends in self.openedChats.append((draft: draft, sends: sends)) }
    }
    return SessionToolsAdapter.Routes(
      openSession: { _ in }, openNewSideChat: open, showPullRequests: {},
      showGoal: { self.goalsShown += 1 }, report: { self.reports.append($0) })
  }
}

@MainActor
@Suite("Session tools routing")
struct SessionToolsAdapterRoutingTests {
  private typealias Fixtures = ConversationFixtures

  private func store(
    harness: String? = "claude-sdk", wrapper: String? = nil, parentID: String? = nil,
    sideChatSourceID: String? = nil, readOnly: Bool = false
  ) async throws -> ConversationStore {
    try await Fixtures.store(
      header: Fixtures.header(
        settings: Fixtures.settings(
          harness: harness, wrapper: wrapper, parentID: parentID,
          sideChatSourceID: sideChatSourceID),
        readOnly: readOnly))
  }

  private func summary(agent: String) -> OmnigentCoreFFI.SessionSummary {
    OmnigentCoreFFI.SessionSummary(
      id: "conv", title: "", preview: "", status: .idle, isReadOnly: false, updatedAt: 0,
      workspace: "", agentName: agent, isPinned: false, isArchived: false, permissionLevel: nil,
      failureMessage: nil, canRename: false, canPin: false, canArchive: false)
  }

  @Test("Side chat needs a writer, a known harness and a session that isn't one already")
  func sideChatOffer() async throws {
    let routes = RouteLog().routes()
    #expect(SessionToolsAdapter.sideChat(try await store(), routes: routes) != nil)
    for hidden in [
      try await store(harness: nil), try await store(harness: ""),
      try await store(readOnly: true), try await store(sideChatSourceID: "parent"),
      try await Fixtures.store(),
    ] {
      #expect(SessionToolsAdapter.sideChat(hidden, routes: routes) == nil)
    }
    // An empty source id from a server still names a side chat here.
    #expect(
      SessionToolsAdapter.sideChat(try await store(sideChatSourceID: ""), routes: routes) == nil)
  }

  @Test("A window without tabs reports that it can't open a side chat")
  func sideChatWithoutTabs() async throws {
    let log = RouteLog()
    let conversation = try await store()
    SessionToolsAdapter.startSideChat(conversation, routes: log.routes(sideChats: false))
    #expect(log.reports.count == 1)
    #expect(log.openedChats.isEmpty)
  }

  @Test("A typed /side clears once its chat opens; a question sends at once")
  func draftSideChats() async throws {
    let log = RouteLog()
    let conversation = try await store()
    conversation.composer.text = "/side what now"
    SessionToolsAdapter.startSideChat(conversation, routes: log.routes(), question: "what now")
    #expect(conversation.composer.text.isEmpty)
    #expect(log.openedChats.map(\.draft) == ["what now"])
    #expect(log.openedChats.map(\.sends) == [true])

    conversation.composer.text = "/sidebar is unrelated"
    SessionToolsAdapter.startSideChat(conversation, routes: log.routes(), quote: "picked")
    #expect(conversation.composer.text == "/sidebar is unrelated")
    #expect(log.openedChats.last?.draft.contains("> picked") == true)
    #expect(log.openedChats.last?.sends == false)
  }

  @Test("A native side chat is typed in the composer, appending any question")
  func nativeSideChat() async throws {
    let log = RouteLog()
    let conversation = try await store(harness: "codex-native", wrapper: "codex-native-ui")
    SessionToolsAdapter.startSideChat(conversation, routes: log.routes(), question: "why?")
    #expect(conversation.composer.text == "/side why?")
    #expect(log.openedChats.isEmpty)
  }

  @Test("The Add menu offers a command goal to a writer only")
  func commandGoalInTheMenu() async throws {
    let polly = summary(agent: "POLLY")
    let log = RouteLog()
    var writer = ComposerExtraActions()
    SessionToolsAdapter.add(
      to: &writer, store: try await store(), summary: polly, routes: log.routes())
    #expect(writer.setGoal != nil)
    #expect(writer.togglePlan == nil)
    #expect(!writer.isPlanOn)
    writer.setGoal?()
    #expect(log.goalsShown == 1)

    var reader = ComposerExtraActions()
    SessionToolsAdapter.add(
      to: &reader, store: try await store(readOnly: true), summary: polly, routes: log.routes())
    #expect(reader.setGoal == nil)
    #expect(reader.newSideChat == nil)

    var noGoal = ComposerExtraActions()
    SessionToolsAdapter.add(
      to: &noGoal, store: try await Fixtures.store(), summary: nil, routes: log.routes())
    #expect(noGoal.setGoal == nil)
    #expect(noGoal.indicators.openGoal == nil)
  }

  @Test("A child session or an unknown harness has no goal control")
  func goalControlRules() async throws {
    let polly = summary(agent: "polly")
    #expect(SessionToolsAdapter.goalControl(try await Fixtures.store(), summary: nil) == nil)
    #expect(
      SessionToolsAdapter.goalControl(try await store(parentID: "parent"), summary: polly) == nil)
    #expect(SessionToolsAdapter.goalControl(try await store(parentID: ""), summary: polly) != nil)
    #expect(
      SessionToolsAdapter.goalControl(try await store(harness: "exploded"), summary: polly) == nil)
    #expect(SessionToolsAdapter.goalSheet(try await Fixtures.store(), summary: nil) == nil)
    let sheet = SessionToolsAdapter.goalSheet(try await store(), summary: polly)
    #expect(sheet?.mode == .command(backend: "Claude"))
  }

  @Test("A command goal goes out as a message, never along with a draft")
  func commandGoalSubmit() async throws {
    let polly = summary(agent: "polly")
    let conversation = try await store()
    var dismissals = 0
    var reports: [String] = []
    let actions = SessionToolsAdapter.goalActions(
      conversation, summary: polly, dismiss: { dismissals += 1 }, report: { reports.append($0) })
    #expect(actions.setActive == nil)
    #expect(actions.clear == nil)

    actions.submit("   \n", nil)
    #expect(conversation.composer.text.isEmpty)
    #expect(dismissals == 0)

    conversation.composer.text = "half written"
    actions.submit("ship it", nil)
    #expect(conversation.composer.text == "half written")
    #expect(reports.count == 1)
    #expect(dismissals == 0)

    conversation.composer.text = ""
    actions.submit("ship it", .max)
    #expect(dismissals == 1)
    actions.dismiss()
    #expect(dismissals == 2)
  }

  @Test("Dismissing a managed goal clears its error first")
  func managedGoalDismiss() async throws {
    let conversation = try await store(harness: "codex-native", wrapper: "codex-native-ui")
    var dismissals = 0
    let actions = SessionToolsAdapter.goalActions(
      conversation, summary: nil, dismiss: { dismissals += 1 }, report: { _ in })
    #expect(actions.setActive != nil)
    #expect(actions.clear != nil)
    actions.dismiss()
    #expect(dismissals == 1)
    #expect(conversation.tools.lastError == nil)
  }

  @Test("/new and /side tell the screen; a plain failure stays on the composer")
  func sending() async throws {
    let log = RouteLog()
    let conversation = try await store()
    conversation.composer.configuration = Fixtures.configuration()
    conversation.composer.slashOptions = SlashOptions(serverClears: true)
    conversation.composer.text = "/new"
    await SessionToolsAdapter.send(
      conversation, newSession: { log.newSessions += 1 }, routes: log.routes())
    #expect(log.newSessions == 1)

    conversation.composer.text = "/side look here"
    await SessionToolsAdapter.send(conversation, newSession: nil, routes: log.routes())
    #expect(log.openedChats.map(\.draft) == ["look here"])
  }

  @Test("Quoting in a side chat stays in its own composer; a blank selection changes nothing")
  func selectionInASideChat() async throws {
    let conversation = try await store(sideChatSourceID: "parent")
    var actions = ConversationActions()
    SessionToolsAdapter.addSelectionActions(
      to: &actions, store: conversation, routes: RouteLog().routes())
    conversation.composer.text = "draft"
    actions.askInSideChat?("   ")
    #expect(conversation.composer.text == "draft")
    actions.askInSideChat?("one\r\ntwo")
    #expect(conversation.composer.text == "draft\n\n> one\n> two\n\n")
  }

  @Test("Neither a writer nor a side chat offers asking without a harness")
  func selectionWithoutHarness() async throws {
    var actions = ConversationActions()
    SessionToolsAdapter.addSelectionActions(
      to: &actions, store: try await store(harness: nil), routes: RouteLog().routes())
    #expect(actions.replyWithSelection != nil)
    #expect(actions.askInSideChat == nil)
  }
}
