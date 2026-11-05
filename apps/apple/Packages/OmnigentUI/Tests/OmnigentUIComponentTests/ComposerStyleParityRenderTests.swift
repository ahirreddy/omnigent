#if os(macOS)
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Both composers render what the shared state carries: command output, `@` mentions, task
  /// indicators, context use and the connection row. Set `OMNIGENT_UI_RENDER_DIR` to keep PNGs.
  @Suite("Chat and CLI composers show the same state", .serialized)
  @MainActor
  struct ComposerStyleParityRenderTests {
    private static var busyState: ComposerViewState {
      var state = ComposerSamples.idle
      state.commandNotice = "Items in context: 12\nTokens: 48,200 of 200,000"
      state.mentions = ["Sources/App.swift", "Tests/"]
      state.connection = ComposerConnectionNotice(message: "Reconnecting\u{2026}")
      var tray = state.tray ?? ComposerTray()
      tray.pullRequest = "#42"
      tray.contextFraction = 0.42
      tray.indicators = ComposerTaskIndicators(
        backgroundTasks: 2, goal: ComposerGoal(objective: "Ship the fix", status: "active"))
      state.tray = tray
      return state
    }

    private func render(
      _ style: TranscriptStyle, state: ComposerViewState, width: CGFloat = 760,
      layout: LayoutWidth = .regular
    ) throws -> RenderSupport.Rendered {
      var extras = ComposerExtraActions(reconnect: {}, dismissCommandNotice: {})
      extras.removeMention = { _ in }
      let view = TranscriptComposer(
        draft: ComposerDraft(get: { "" }, set: { _ in }), state: state,
        actions: ComposerActions(send: {}, extras: extras), focusRequest: 0,
        hasTextChanged: { _ in }
      )
      .cliPalette()
      .transcriptAppearance(TranscriptAppearance(style: style, outputRendering: .styled))
      return try RenderSupport.render(view, width: width, scheme: .dark, layout: layout)
    }

    private func renderError(_ style: TranscriptStyle, canRetry: Bool) throws
      -> RenderSupport.Rendered
    {
      let row = Row(
        id: "err", role: .tool,
        activity: Activity(
          kind: .error, title: "Response error", summary: "Rate limit exceeded",
          isFailure: true, recovery: .continue))
      var actions = ConversationActions()
      if canRetry { actions.retryFailedTurn = { _ in } }
      let view = Group {
        if style == .cli { CLIActivityLine(row: row) } else { ActivityRowView(row: row) }
      }
      .environment(\.conversationActions, actions)
      .cliPalette()
      .transcriptAppearance(TranscriptAppearance(style: style, outputRendering: .styled))
      return try RenderSupport.render(view, width: 760, scheme: .dark, layout: .regular)
    }

    @Test("a recoverable error offers Retry in both styles")
    func errorRowsOfferRetry() throws {
      for style in TranscriptStyle.allCases {
        let withRetry = try renderError(style, canRetry: true)
        try RenderSupport.write(withRetry, name: "error-retry-\(style)")
        let without = try renderError(style, canRetry: false)
        #expect(
          RenderSupport.inkCoverage(withRetry) > RenderSupport.inkCoverage(without),
          "\(style) error row shows no Retry")
      }
    }

    @Test("the CLI composer grows with the same command output, mentions and indicators")
    func cliShowsSharedState() throws {
      for style in TranscriptStyle.allCases {
        let plain = try render(style, state: ComposerSamples.idle)
        let busy = try render(style, state: Self.busyState)
        try RenderSupport.write(busy, name: "composer-parity-\(style)")
        #expect(
          busy.size.height > plain.size.height + 60,
          "\(style) composer hides the shared state (\(plain.size.height) vs \(busy.size.height))")
        let phone = try render(style, state: Self.busyState, width: 393, layout: .compact)
        try RenderSupport.write(phone, name: "composer-parity-\(style)-compact")
      }
    }
  }
#endif
