import Testing

@testable import OmnigentUIComponents

@Suite("Decision cards v2 and dock")
struct DecisionPresentationTests {
  @Test("Each kind offers its own actions")
  func availabilityPerKind() {
    let plain = DecisionAvailability(PreviewData.card("a", detail: "Delete report.md?"))
    #expect(plain.approveTitle == "Approve")
    #expect(plain.canReject)
    #expect(!plain.canTellAgent)
    #expect(plain.widening.isEmpty)
    #expect(!plain.canDismiss)

    let plan = DecisionAvailability(PreviewData.planReview)
    #expect(plan.approveTitle == "Approve plan")
    #expect(plan.canTellAgent)
    // Both flags switch a plan to auto mode, so only one choice is offered.
    #expect(plan.widening.map(\.response) == [.approveAllEdits])

    let codex = DecisionAvailability(PreviewData.codexCommand)
    #expect(!codex.canTellAgent)
    #expect(
      codex.widening.map(\.response) == [
        .approveCommandPolicy(policy: ["cargo", "test"]), .approvePersist(mode: .session),
        .approvePersist(mode: .always),
      ])

    // A directory scope replaces the mode and "don't ask again" choices, as on the web.
    let edits = DecisionAvailability(PreviewData.approval)
    #expect(edits.canTellAgent)
    #expect(edits.widening.map(\.response) == [.approveDirectories])

    let choice = DecisionAvailability(PreviewData.choice)
    #expect(choice.approveTitle == nil)
    #expect(!choice.canReject)
    #expect(choice.options == ["main", "auth-refresh", "Create a new branch"])
    #expect(choice.canDismiss)

    let form = DecisionAvailability(PreviewData.form)
    #expect(form.fields == PreviewData.formFields)
    #expect(form.canDismiss)
    #expect(form.approveTitle == nil)

    let unsupported = DecisionAvailability(PreviewData.unsupported)
    #expect(unsupported.approveTitle == nil)
    #expect(!unsupported.canDismiss)
    #expect(unsupported.externalURL?.hasPrefix("https://linear.app/") == true)
  }

  @Test("Widening labels name scope and duration exactly")
  func wideningWording() {
    let labels = PermissionChoice.choices(for: PreviewData.codexCommand).map(\.label)
    #expect(
      labels == [
        "Approve and don\u{2019}t ask again for commands starting with cargo test",
        "Approve this tool for this session", "Always allow this tool",
      ])
    let agy = PermissionChoice.choices(for: PreviewData.antigravity).map(\.label)
    #expect(
      agy == [
        "Allow commands starting with npm install for this session",
        "Always allow commands starting with npm install",
      ])
    let claude = PreviewData.card(
      "c", detail: "x",
      permissions: PermissionOptions(
        allowAllEdits: true, allowAutoMode: true, rememberLabel: "Bash"))
    #expect(
      PermissionChoice.choices(for: claude).map(\.label) == [
        "Approve and accept all edits for this session",
        "Approve and use auto mode for this session",
        "Approve and don\u{2019}t ask again for Bash this session",
      ])
    #expect(
      PermissionChoice.choices(for: PreviewData.approval).map(\.label) == [
        "Approve and allow /workspace/omnigent/client-core for this session"
      ])
  }

  @Test("Every widening choice is confirmed; plain answers are sent")
  func wideningNeedsConfirmation() {
    for card in PreviewData.decisions {
      for choice in PermissionChoice.choices(for: card) {
        #expect(DecisionRoute(choice.response) == .confirm(choice.response), "\(choice.label)")
      }
    }
    for response in [
      DecisionResponse.approve, .decline, .cancel, .answer(value: "main"),
      .declineWithFeedback(feedback: "Only the auth tests"),
    ] {
      #expect(DecisionRoute(response) == .send(response))
    }
  }

  @Test("Tell the agent instead sends a trimmed decline with feedback, only where it is carried")
  func feedbackRouting() {
    #expect(
      DecisionAvailability.feedbackResponse(for: PreviewData.claudeBash, text: "  Only auth  ")
        == .declineWithFeedback(feedback: "Only auth"))
    #expect(
      DecisionAvailability.feedbackResponse(for: PreviewData.planReview, text: "Smaller steps")
        == .declineWithFeedback(feedback: "Smaller steps"))
    #expect(DecisionAvailability.feedbackResponse(for: PreviewData.claudeBash, text: " \n ") == nil)
    #expect(DecisionAvailability.feedbackResponse(for: PreviewData.codexCommand, text: "No") == nil)
    var choice = PreviewData.choice
    choice.acceptsFeedback = true
    #expect(DecisionAvailability.feedbackResponse(for: choice, text: "No") == nil)
    #expect(!DecisionResponse.declineWithFeedback(feedback: "x").changesStandingPermissions)
  }

  @Test("One-line summaries and what the compact row can answer")
  func summaries() {
    let command = DecisionSummary(PreviewData.codexCommand)
    #expect(command.plain == "Run cargo test -p omnigent-core auth -- --nocapture")
    #expect(command.secondary == "in /workspace/omnigent")
    #expect(command.answersInline)

    let edits = DecisionSummary(PreviewData.approval)
    #expect(edits.plain == "Edit 3 files")
    #expect(!edits.answersInline)

    let single = DecisionSummary(PreviewData.singleEdit)
    #expect(single.plain == "Edit README.md")
    #expect(single.secondary == "+4 \u{2212}1")
    #expect(single.answersInline)

    let bash = DecisionSummary(PreviewData.claudeBash)
    #expect(bash.plain == "Claude wants to call Bash")
    #expect(!bash.answersInline, "the tool input is only visible on the full card")

    #expect(DecisionSummary(PreviewData.planReview).plain == "Review the plan")
    #expect(!DecisionSummary(PreviewData.planReview).answersInline)
    #expect(DecisionSummary(PreviewData.choice).plain == "Which branch should I push to?")
    #expect(DecisionSummary(PreviewData.choice).answersInline)
    #expect(!DecisionSummary(PreviewData.form).answersInline)

    let options = DecisionKind.choice(answerKey: "choice", options: ["Chat", "Approvals"])
    let withContext = DecisionSummary(
      PreviewData.card(
        "q", detail: "What should we build first?\n\nChoose one **focus**.", kind: options))
    #expect(withContext.plain == "What should we build first?")
    #expect(withContext.secondary == "Choose one focus.")
    #expect(withContext.answersInline)
    let long = String(repeating: "context ", count: 20)
    let longContext = DecisionSummary(
      PreviewData.card("q", detail: "Which?\n\n\(long)", kind: options))
    #expect(longContext.secondary == nil)
    #expect(!longContext.answersInline, "the context is only visible on the full card")
    let threeParagraphs = DecisionSummary(
      PreviewData.card("q", detail: "Which?\n\nOne.\n\nTwo.", kind: options))
    #expect(!threeParagraphs.answersInline)

    let named = PreviewData.card(
      "d", title: "Apply the sample design?",
      detail: "Use the simpler session list and keep pending requests easy to find.")
    #expect(DecisionSummary(named).plain == "Apply the sample design?")
    #expect(DecisionSummary(named).answersInline)
  }

  @Test("The dock orders, limits, selects and gives Command-Return to one card")
  func dockModel() {
    var state = PreviewData.conversation
    state.decisions = PreviewData.dockDecisions
    let compact = DecisionDockModel(
      state: state, selectedID: nil, isExpanded: false, layoutWidth: .regular)
    #expect(compact.headline == "6 requests need you")
    #expect(compact.compactCards.count == 3)
    #expect(compact.hiddenCount == 3)
    #expect(compact.shortcutCardID == PreviewData.codexCommand.id)
    #expect(compact.selected?.id == PreviewData.codexCommand.id)

    let expanded = DecisionDockModel(
      state: state, selectedID: PreviewData.claudeBash.id, isExpanded: true,
      layoutWidth: .regular)
    #expect(expanded.shortcutCardID == PreviewData.claudeBash.id)
    let plan = DecisionDockModel(
      state: state, selectedID: PreviewData.planReview.id, isExpanded: true,
      layoutWidth: .regular)
    #expect(plan.shortcutCardID == nil, "plan reviews never take the shortcut")
    let gone = DecisionDockModel(
      state: state, selectedID: "missing", isExpanded: true, layoutWidth: .regular)
    #expect(gone.selected?.id == PreviewData.codexCommand.id)

    // An answered card sinks below the pending ones and loses the shortcut.
    state.decisions[0].answered = true
    let answered = DecisionDockModel(
      state: state, selectedID: nil, isExpanded: false, layoutWidth: .regular)
    #expect(answered.cards.last?.id == PreviewData.codexCommand.id)
    #expect(answered.headline == "5 of 6 requests need you")
    #expect(answered.shortcutCardID == nil)

    state.header.readOnly = true
    let readOnly = DecisionDockModel(
      state: state, selectedID: nil, isExpanded: true, layoutWidth: .regular)
    #expect(readOnly.shortcutCardID == nil)
  }

  @Test("The dock names a mirrored card's source")
  func dockContext() {
    let model = DecisionDockModel(
      state: PreviewData.conversation, selectedID: nil, isExpanded: false, layoutWidth: .regular)
    #expect(model.context(for: PreviewData.antigravity) == "Subagent \u{00B7} Write auth tests")
    #expect(model.context(for: PreviewData.codexCommand) == "Codex")
  }
}
