#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The approval card, answered every way it can be.
  @Suite("Decision card: approvals", .serialized)
  @MainActor
  struct DecisionApprovalCardTests {
    private let log = DecisionResponseLog()

    private func open(
      _ card: DecisionCard, model: DecisionCardModel = DecisionCardModel(),
      responds: Bool = true
    ) -> OffscreenWindow<DecisionCardScreen> {
      let screen = OffscreenWindow(
        DecisionCardScreen(card: card, model: model, log: log, responds: responds))
      screen.settle()
      return screen
    }

    /// A card whose only controls are the ones it answers with.
    private func plain(acceptsFeedback: Bool = false) -> DecisionCard {
      .sample(detail: "Do the thing", acceptsFeedback: acceptsFeedback)
    }

    @Test("Approve sends an approval, and says what it asks")
    func approve() throws {
      let screen = open(plain())
      defer { screen.close() }
      #expect(try screen.shows("Approval required"))
      #expect(try screen.shows("Do the thing"))
      #expect(screen.buttons.count == 2)
      try screen.tapButton(0)
      #expect(log.responses == [.approve])
    }

    @Test("Reject sends a decline")
    func reject() throws {
      let screen = open(plain())
      defer { screen.close() }
      try screen.tapButton(1)
      #expect(log.responses == [.decline])
    }

    @Test("Tell the agent opens a reply; an empty one can't be sent, a written one is trimmed")
    func tellTheAgent() throws {
      let screen = open(plain(acceptsFeedback: true))
      defer { screen.close() }
      #expect(try !screen.shows("Reject and send"))
      try screen.tapButton(2)
      #expect(try screen.shows("What should the agent do instead?"))
      #expect(try screen.shows("Reject and send"))
      #expect(try !screen.shownText().contains("Tell the agent instead"))
      let disabled = screen.buttons.count
      try screen.type("  use rg  ", intoField: 0)
      screen.settle(0.05)
      #expect(screen.buttons.count == disabled + 1)
      #expect(log.responses.isEmpty)
      try screen.tapButton(fromEnd: 1)
      #expect(log.responses == [.declineWithFeedback(feedback: "use rg")])
      #expect(try !screen.shows("Reject and send"))
      #expect(try screen.shows("Tell the agent instead"))
    }

    @Test("Return in the reply sends it; with nothing written it sends nothing")
    func replyReturn() throws {
      let screen = open(plain(acceptsFeedback: true))
      defer { screen.close() }
      try screen.tapButton(2)
      try screen.type("", intoField: 0)
      try screen.pressReturn()
      #expect(log.responses.isEmpty)
      try screen.type("not that", intoField: 0)
      try screen.pressReturn()
      #expect(log.responses == [.declineWithFeedback(feedback: "not that")])
    }

    @Test("Cancel closes the reply and keeps what was written")
    func replyCancel() throws {
      let screen = open(plain(acceptsFeedback: true))
      defer { screen.close() }
      try screen.tapButton(2)
      try screen.type("half a thought", intoField: 0)
      screen.settle(0.05)
      try screen.tapButton(fromEnd: 0)
      #expect(try !screen.shows("Reject and send"))
      #expect(log.responses.isEmpty)
      try screen.tapButton(2)
      #expect(screen.fields.first?.stringValue == "half a thought")
    }

    @Test("A card that can't carry a reply doesn't offer one")
    func noReply() throws {
      let screen = open(plain())
      defer { screen.close() }
      #expect(try !screen.shows("Tell the agent instead"))
    }

    // MARK: Widening

    private func widening(_ permissions: PermissionOptions) -> DecisionCard {
      .sample(detail: "Do the thing", permissions: permissions)
    }

    @Test("More approval options lists each widening choice, confirmed before it is sent")
    func widen() throws {
      SystemSideEffects.reset()
      let options = PermissionOptions(allowAllEdits: true, allowAutoMode: true, rememberLabel: "ls")
      let screen = open(widening(options))
      defer { screen.close() }
      #expect(try screen.shows("More approval options\u{2026}"))
      let menu = try screen.menu(at: 0)
      #expect(
        menuTitles(menu) == [
          "Approve and accept all edits for this session",
          "Approve and use auto mode for this session",
          "Approve and don\u{2019}t ask again for ls this session",
        ])
      try screen.choose("Approve and use auto mode for this session", in: menu)
      screen.settle(0.3)
      #expect(SystemSideEffects.record.alertMessages.contains("Change approval behavior?"))
      #expect(log.responses == [.approveAutoMode])
    }

    @Test("Canceling the confirmation sends nothing, and the card can still be answered")
    func widenCanceled() throws {
      SystemSideEffects.reset()
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      defer { SystemSideEffects.reset() }
      let screen = open(widening(PermissionOptions(allowAutoMode: true)))
      defer { screen.close() }
      let menu = try screen.menu(at: 0)
      try screen.choose("Approve and use auto mode for this session", in: menu)
      screen.settle(0.3)
      #expect(SystemSideEffects.record.alertMessages.contains("Change approval behavior?"))
      #expect(log.responses.isEmpty)
      try screen.tapButton(0)
      #expect(log.responses == [.approve])
    }

    @Test("Every kind of widening sends its own response")
    func everyWidening() throws {
      SystemSideEffects.reset()
      let cases = [
        WideningCase(
          PermissionOptions(allowAllEdits: true),
          "Approve and accept all edits for this session", .approveAllEdits),
        WideningCase(
          PermissionOptions(permissionDirectories: ["/src"]),
          "Approve and allow /src for this session", .approveDirectories),
        WideningCase(
          PermissionOptions(rememberLabel: "ls"),
          "Approve and don\u{2019}t ask again for ls this session", .approveRemembering),
        WideningCase(
          PermissionOptions(execPolicyAmendment: ["git", "log"]),
          "Approve and don\u{2019}t ask again for commands starting with git log",
          .approveCommandPolicy(policy: ["git", "log"])),
        WideningCase(
          PermissionOptions(persistModes: [.session]), "Approve this tool for this session",
          .approvePersist(mode: .session)),
        WideningCase(
          PermissionOptions(persistModes: [.always]), "Always allow this tool",
          .approvePersist(mode: .always)),
      ]
      for item in cases {
        log.responses = []
        let screen = open(widening(item.options))
        defer { screen.close() }
        try screen.choose(item.title, in: try screen.menu(at: 0))
        screen.settle(0.3)
        #expect(log.responses == [item.response], "\(item.title)")
      }
    }

    private struct WideningCase {
      let options: PermissionOptions
      let title: String
      let response: DecisionResponse

      init(_ options: PermissionOptions, _ title: String, _ response: DecisionResponse) {
        self.options = options
        self.title = title
        self.response = response
      }
    }

    // MARK: Who can answer

    @Test("Read-only access can't answer, and the card says so")
    func readOnly() throws {
      let screen = open(
        plain(acceptsFeedback: true), model: DecisionCardModel(isReadOnly: true))
      defer { screen.close() }
      #expect(try screen.shows("Read-only access cannot respond to this request."))
      try screen.clickEveryButton()
      #expect(log.responses.isEmpty)
      #expect(try !screen.shows("Reject and send"))
    }

    @Test("A card with no responder reads the same as read-only")
    func noResponder() throws {
      let screen = open(plain(), responds: false)
      defer { screen.close() }
      #expect(try screen.shows("Read-only access cannot respond to this request."))
      #expect(screen.buttons.isEmpty)
    }

    // MARK: Phases

    @Test("While a response is sending nothing else can be sent")
    func resolving() throws {
      let screen = open(plain(), model: DecisionCardModel(phase: .resolving))
      defer { screen.close() }
      #expect(try screen.shows("Sending your response"))
      #expect(screen.buttons.isEmpty)
    }

    @Test("A sent answer collapses to one line waiting for the server")
    func answered() throws {
      let screen = open(.command(), model: DecisionCardModel(phase: .answered(summary: "Approved")))
      defer { screen.close() }
      #expect(try screen.shows("Approved \u{00B7} Run cargo test"))
      #expect(try screen.shows("Waiting for the server"))
      #expect(try !screen.shows("Command approval"))
      #expect(screen.buttons.isEmpty)
    }

    @Test("A failed send says why and can be answered again")
    func failed() throws {
      let screen = open(plain(), model: DecisionCardModel(phase: .failed(message: "No network")))
      defer { screen.close() }
      #expect(try screen.shows("No network"))
      try screen.tapButton(0)
      #expect(log.responses == [.approve])
    }

    @Test("The phase can change under an open card")
    func phaseChange() throws {
      let model = DecisionCardModel()
      let screen = open(plain(), model: model)
      defer { screen.close() }
      try screen.tapButton(0)
      model.phase = .resolving
      screen.settle()
      #expect(try screen.shows("Sending your response"))
      model.phase = .failed(message: "Refused")
      screen.settle()
      #expect(try !screen.shows("Sending your response"))
      #expect(try screen.shows("Refused"))
    }
  }
#endif
