#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Transcript failure cards", .serialized)
  @MainActor
  struct TranscriptErrorCardTests {
    private struct ForkCase {
      let code: String
      let title: String
      let elsewhere: Bool
    }

    private func errorRow(
      code: String? = nil, remediation: String? = nil, extra: [DetailSection] = [],
      recovery: FailureRecovery? = nil, status: String? = nil
    ) -> (Row, Activity) {
      var details = extra
      if let code { details.append(DetailSection(id: "code", title: "Code", text: code)) }
      if let remediation {
        details.append(DetailSection(id: "remediation", title: "Fix", text: remediation))
      }
      details.append(DetailSection(id: "cause", title: "Cause", text: "The cause"))
      let activity = Activity(
        kind: .error, title: "Turn failed", summary: "The message", status: status,
        details: details, isFailure: true, recovery: recovery)
      return (Row(id: "row", role: .tool, activity: activity), activity)
    }

    private func card(_ pair: (Row, Activity), actions: ConversationActions = ConversationActions())
      -> OffscreenWindow<AnyView>
    {
      transcriptScreen(ErrorRowView(row: pair.0, activity: pair.1), actions: actions)
    }

    @Test("The card says what failed, why and what to do")
    func content() throws {
      let screen = card(errorRow(remediation: "omnigent login"))
      defer { screen.close() }
      for text in ["Turn failed", "The message", "The cause", "omnigent login"] {
        #expect(try screen.shows(text), "\(text)")
      }
    }

    @Test("A headline repeating the message isn't said twice")
    func repeatedHeadline() throws {
      let activity = Activity(kind: .error, title: "Same", summary: "Same", isFailure: true)
      let screen = transcriptScreen(
        ErrorRowView(row: Row(id: "row", role: .tool, activity: activity), activity: activity))
      defer { screen.close() }
      #expect(try screen.shownText().count { $0.contains("Same") } == 1)
    }

    @Test("Retry and Resume are titled by what they do, and retry that row")
    func recovery() throws {
      #expect(FailureRecovery.continue.title == "Retry")
      #expect(FailureRecovery.resume.title == "Resume")
      #expect(FailureRecovery.continue.help != FailureRecovery.resume.help)

      for (recovery, title) in [(FailureRecovery.continue, "Retry"), (.resume, "Resume")] {
        let log = HostLog()
        var actions = ConversationActions()
        actions.retryFailedTurn = { log.add($0.id) }
        let screen = card(errorRow(recovery: recovery), actions: actions)
        defer { screen.close() }
        #expect(try screen.shows(title))
        try screen.clickControl(at: screen.controlFrames.count - 1)
        #expect(log.entries == ["row"])
      }
    }

    @Test("No Retry without a recovery rule or without a host for it")
    func noRecovery() throws {
      var actions = ConversationActions()
      actions.retryFailedTurn = { _ in }
      let noRule = card(errorRow(), actions: actions)
      defer { noRule.close() }
      #expect(try !noRule.shows("Retry"))
      let noHost = card(errorRow(recovery: .continue))
      defer { noHost.close() }
      #expect(try !noHost.shows("Retry"))
    }

    @Test("A failure only a new session gets past offers the fork it needs")
    func fork() throws {
      let cases = [
        ForkCase(
          code: "workspace_missing", title: "Continue in Another Directory\u{2026}", elsewhere: true
        ),
        ForkCase(code: "session_agent_missing", title: "Fork Session\u{2026}", elsewhere: false),
      ]
      for forkCase in cases {
        let (code, title, elsewhere) = (forkCase.code, forkCase.title, forkCase.elsewhere)
        var chosen: [Bool] = []
        var actions = ConversationActions()
        actions.forkToRecover = { chosen.append($0) }
        let screen = card(errorRow(code: code), actions: actions)
        defer { screen.close() }
        #expect(try screen.shows(title))
        #expect(ErrorRowView.isWorkspaceMissing(errorRow(code: code).1) == elsewhere)
        let frames = screen.controlFrames
        let fork = try #require(frames.dropFirst().first)
        try screen.click(CGPoint(x: fork.midX, y: fork.midY))
        #expect(chosen == [elsewhere], "\(code)")
      }
    }

    @Test("Diagnostics stay folded, and the inline details aren't repeated in them")
    func diagnostics() throws {
      let extra = [DetailSection(id: "trace", title: "Trace", text: "Frame one")]
      let screen = card(errorRow(remediation: "fix it", extra: extra))
      defer { screen.close() }
      #expect(try screen.shows("View Diagnostics"))
      #expect(try !screen.shows("Frame one"))

      let plain = card(errorRow())
      defer { plain.close() }
      #expect(try !plain.shows("View Diagnostics"))
    }

    @Test("A notice reads as a notice")
    func neutral() throws {
      let screen = card(errorRow(status: "info"))
      defer { screen.close() }
      #expect(try screen.shows("Turn failed"))
    }

    @Test("A pending sign-in fetches its link on click and says what it found")
    func signInFlow() async throws {
      var outcomes: [SignInOutcome] = [
        .failed("timed out"), .notPending,
      ]
      var calls = 0
      var actions = ConversationActions()
      actions.openSignIn = {
        calls += 1
        return outcomes.removeFirst()
      }
      let screen = card(errorRow(code: "databricks_sign_in_pending"), actions: actions)
      defer { screen.close() }
      #expect(try screen.shows("Open Sign-In Link"))
      let link = try #require(screen.controlFrames.dropFirst().first)
      try screen.click(CGPoint(x: link.midX, y: link.midY))
      try await letTasksRun(screen)
      #expect(calls == 1)
      #expect(try screen.shows("Could not reach the host for a fresh link: timed out"))
      try screen.click(CGPoint(x: link.midX, y: link.midY))
      try await letTasksRun(screen)
      #expect(calls == 2)
      #expect(try screen.shows("No sign-in is pending in the terminal any more."))
    }

    @Test("A fetched one-time code is offered to copy until the prompt is gone")
    func signInCodes() {
      let display = ErrorSignInActions.display
      #expect(display(.opened(code: "ABCD"), nil) == ("ABCD", nil))
      #expect(display(.opened(code: nil), "OLD") == (nil, nil))
      #expect(display(.notPending, "OLD").0 == nil)
      #expect(display(.failed("x"), "OLD").0 == "OLD")
    }

    @Test("Only a pending sign-in code shows the link, and only with a host")
    func signInGate() throws {
      var actions = ConversationActions()
      actions.openSignIn = { .notPending }
      let other = card(errorRow(code: "rate_limited"), actions: actions)
      defer { other.close() }
      #expect(try !other.shows("Open Sign-In Link"))
      let noHost = card(errorRow(code: "databricks_sign_in_pending"))
      defer { noHost.close() }
      #expect(try !noHost.shows("Open Sign-In Link"))
    }

    @Test("The CLI's recovery links offer the same sign-in and fork")
    func recoveryLinks() throws {
      var chosen: [Bool] = []
      var actions = ConversationActions()
      actions.forkToRecover = { chosen.append($0) }
      actions.openSignIn = { .notPending }
      let pair = errorRow(code: "session_agent_missing")
      let screen = transcriptScreen(
        ErrorRecoveryLinks(row: pair.0, activity: pair.1), actions: actions)
      defer { screen.close() }
      #expect(try screen.shows("Fork Session\u{2026}"))
      #expect(try !screen.shows("Open Sign-In Link"))
      try screen.clickControl(at: 0)
      #expect(chosen == [false])

      let pending = errorRow(code: "databricks_sign_in_pending")
      let signIn = transcriptScreen(
        ErrorRecoveryLinks(row: pending.0, activity: pending.1), actions: actions)
      defer { signIn.close() }
      #expect(try signIn.shows("Open Sign-In Link"))
    }
  }
#endif
