#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The conversation a dock shows, which a test changes as the app's store would.
  @MainActor @Observable
  final class DecisionDockModelHost {
    var state: ConversationViewState

    init(_ state: ConversationViewState) { self.state = state }
  }

  /// Every response and link the dock passes on.
  @MainActor
  final class DecisionDockLog {
    var responses: [String] = []
    var openedURLs: [URL] = []

    var actions: ConversationActions {
      ConversationActions(
        openURL: { [self] in openedURLs.append($0) },
        respond: { [self] card, response in responses.append("\(card.id):\(response.summary)") })
    }
  }

  /// A dock as the conversation screen hosts it.
  struct DecisionDockScreen: View {
    @Bindable var host: DecisionDockModelHost
    let actions: ConversationActions
    var layoutWidth = LayoutWidth.regular
    var startsExpanded = false
    var surfaces: DecisionSurfaces?
    var drafts: DecisionDrafts?
    var owner: CommandReturnOwner?

    var body: some View {
      DecisionDock(state: host.state, actions: actions)
        .environment(\.layoutWidth, layoutWidth)
        .environment(\.decisionDockStartsExpanded, startsExpanded)
        .environment(\.commandReturnOwner, owner)
        .environment(surfaces)
        .environment(drafts)
        .frame(width: 800, height: 600, alignment: .top)
    }
  }

  extension ConversationViewState {
    /// A conversation holding only these requests.
    static func requests(
      _ cards: [DecisionCard], phases: [String: DecisionPhase] = [:], readOnly: Bool = false
    ) -> ConversationViewState {
      ConversationViewState(
        header: SessionHeader(id: "session", title: "Session", readOnly: readOnly),
        decisions: cards, decisionPhases: phases)
    }
  }

  /// Opens a dock offscreen over a conversation a test can change.
  @MainActor
  func openDock(
    _ state: ConversationViewState, log: DecisionDockLog, startsExpanded: Bool = false,
    surfaces: DecisionSurfaces? = nil, drafts: DecisionDrafts? = nil,
    owner: CommandReturnOwner? = nil
  ) -> (OffscreenWindow<DecisionDockScreen>, DecisionDockModelHost) {
    let host = DecisionDockModelHost(state)
    let screen = OffscreenWindow(
      DecisionDockScreen(
        host: host, actions: log.actions, startsExpanded: startsExpanded, surfaces: surfaces,
        drafts: drafts, owner: owner))
    screen.settle()
    return (screen, host)
  }

  /// The dock above the composer: its compact rows, the expanded list, and what they send.
  @Suite("Decision dock", .serialized)
  @MainActor
  struct DecisionDockTests {
    private let log = DecisionDockLog()

    private func open(
      _ state: ConversationViewState, startsExpanded: Bool = false
    ) -> (OffscreenWindow<DecisionDockScreen>, DecisionDockModelHost) {
      openDock(state, log: log, startsExpanded: startsExpanded)
    }

    private func open(
      _ state: ConversationViewState, drafts: DecisionDrafts
    ) -> (OffscreenWindow<DecisionDockScreen>, DecisionDockModelHost) {
      openDock(state, log: log, drafts: drafts)
    }

    private func request(_ id: String, answered: Bool = false) -> DecisionCard {
      .sample(id: id, detail: "Do \(id)", answered: answered)
    }

    @Test("With no requests the dock shows nothing")
    func empty() throws {
      let (screen, _) = open(.requests([]))
      defer { screen.close() }
      #expect(screen.buttons.isEmpty)
      #expect(try !screen.shows("request"))
    }

    @Test("One request answers from its row, with no header over it")
    func oneRow() throws {
      let (screen, _) = open(.requests([request("one")]))
      defer { screen.close() }
      #expect(try screen.shows("Do one"))
      #expect(try !screen.shows("Show all"))
      #expect(try !screen.shows("request needs you"))
      // The row's own button, Reject, Approve.
      #expect(screen.buttons.count == 3)
      try screen.tapButton(1)
      try screen.tapButton(2)
      #expect(log.responses == ["one:Rejected", "one:Approved"])
    }

    @Test("Several requests get a headline, and each row answers its own")
    func severalRows() throws {
      let (screen, _) = open(.requests([request("one"), request("two")]))
      defer { screen.close() }
      #expect(try screen.shows("2 requests need you"))
      #expect(try screen.shows("Show all"))
      // Show all, then the open, Reject, Approve of each row.
      #expect(screen.buttons.count == 7)
      try screen.tapButton(6)
      #expect(log.responses == ["two:Approved"])
    }

    @Test("An answered request sinks below a pending one and the headline counts them apart")
    func answeredSinks() throws {
      let (screen, _) = open(
        .requests(
          [request("done", answered: true), request("open")],
          phases: ["done": .answered(summary: "Approved")]))
      defer { screen.close() }
      #expect(try screen.shows("1 of 2 requests needs you"))
      #expect(try screen.shows("Approved"))
      // Show all, the pending row's three, then only the answered row's own button.
      #expect(screen.buttons.count == 5)
      try screen.tapButton(3)
      #expect(log.responses == ["open:Approved"])
    }

    @Test("Past three rows the rest are behind Show more, which opens the list")
    func showMore() throws {
      let cards = ["a", "b", "c", "d", "e"].map { request($0) }
      let (screen, _) = open(.requests(cards))
      defer { screen.close() }
      #expect(try screen.shows("5 requests need you"))
      #expect(try screen.shows("Show 2 more"))
      #expect(try !screen.shows("Do d"))
      try screen.tapButton(fromEnd: 0)
      #expect(try screen.shows("Collapse"))
      #expect(try screen.shows("Do e"))
    }

    @Test("Show all lists every request with the first in full; a row selects another")
    func expandAndSelect() throws {
      let cards = [
        request("one"), .command("swift test", id: "two"),
      ]
      let (screen, _) = open(.requests(cards))
      defer { screen.close() }
      try screen.tapButton(0)
      #expect(try screen.shows("Collapse"))
      #expect(try screen.shows("Approval required"))
      #expect(try !screen.shows("Command approval"))
      // Collapse, then the two rows.
      try screen.tapButton(2)
      #expect(try screen.shows("Command approval"))
      #expect(try screen.shows("$ swift test"))
      #expect(try !screen.shows("Approval required"))
      #expect(log.responses.isEmpty)
    }

    @Test("Answering from the expanded card names the selected request")
    func expandedAnswer() throws {
      let (screen, _) = open(.requests([request("one"), request("two")]))
      defer { screen.close() }
      try screen.tapButton(0)
      try screen.tapButton(2)
      // Collapse, the two rows, then Approve.
      try screen.tapButton(3)
      #expect(log.responses == ["two:Approved"])
    }

    @Test("Collapse returns to the rows, and stays there")
    func collapse() throws {
      let (screen, _) = open(.requests([request("one"), request("two")]), startsExpanded: true)
      defer { screen.close() }
      #expect(try screen.shows("Collapse"))
      try screen.tapButton(0)
      #expect(try screen.shows("Show all"))
      #expect(try !screen.shows("Collapse"))
    }

    @Test("One request opened from its row is shown without a list")
    func openOne() throws {
      let (screen, _) = open(.requests([.command("a\nb", id: "long")]))
      defer { screen.close() }
      #expect(try screen.shows("Review"))
      try screen.tapButton(1)
      #expect(try screen.shows("Command approval"))
      #expect(try screen.shows("Collapse"))
    }

    @Test("A read-only conversation can open a request but not answer it")
    func readOnly() throws {
      let (screen, _) = open(.requests([request("one")], readOnly: true))
      defer { screen.close() }
      try screen.clickEveryButton()
      #expect(log.responses.isEmpty)
    }

    @Test("A link in a request goes to the host")
    func openLink() throws {
      let card = DecisionCard.sample(
        id: "web", title: "Sign in",
        kind: .unsupported(reason: "In the browser", externalUrl: "https://a.test/ok"))
      let (screen, _) = open(.requests([card]), startsExpanded: true)
      defer { screen.close() }
      #expect(try screen.shows("Open approval page"))
      // Collapse, then Open approval page.
      try screen.tapButton(1)
      #expect(log.openedURLs == [URL(string: "https://a.test/ok")])
    }

    @Test("A link with no host handler falls to the system")
    func openLinkSystem() throws {
      SystemSideEffects.reset()
      let card = DecisionCard.sample(
        id: "web", title: "Sign in",
        kind: .unsupported(reason: "In the browser", externalUrl: "https://a.test/ok"))
      let screen = OffscreenWindow(
        DecisionDockScreen(
          host: DecisionDockModelHost(.requests([card])), actions: ConversationActions(),
          startsExpanded: true))
      defer { screen.close() }
      screen.settle()
      try screen.tapButton(1)
      screen.settle(0.1)
      #expect(SystemSideEffects.record.openedURLs == [URL(string: "https://a.test/ok")])
    }

    @Test("A request's draft goes with it; another's stays")
    func draftsFollowCards() throws {
      let drafts = DecisionDrafts()
      var kept = FormDraft()
      kept.feedback = "kept"
      var dropped = FormDraft()
      dropped.feedback = "dropped"
      drafts.drafts = ["one": kept, "two": dropped]
      let (screen, host) = open(.requests([request("one"), request("two")]), drafts: drafts)
      defer { screen.close() }
      host.state = .requests([request("one")])
      screen.settle()
      #expect(drafts.drafts == ["one": kept])
    }

    @Test("A half-written reply survives moving between requests")
    func draftSurvivesSelection() throws {
      let cards: [DecisionCard] = [
        .sample(id: "one", detail: "Do one", acceptsFeedback: true), request("two"),
      ]
      let (screen, _) = open(.requests(cards), startsExpanded: true)
      defer { screen.close() }
      // Collapse, two rows, Approve, Reject, Tell the agent.
      try screen.tapButton(5)
      try screen.type("half", intoField: 0)
      try screen.tapButton(2)
      #expect(screen.fields.isEmpty)
      try screen.tapButton(1)
      #expect(screen.fields.first?.stringValue == "half")
    }
  }
#endif
