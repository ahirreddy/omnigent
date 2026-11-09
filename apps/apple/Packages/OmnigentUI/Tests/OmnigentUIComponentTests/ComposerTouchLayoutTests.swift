#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The touch bar's layout, run on the Mac: it collapses at rest and opens into an action row.
  @Suite("Composer: touch layout", .serialized)
  @MainActor
  struct ComposerTouchLayoutTests {
    private let log = ComposerActionLog()

    private func open(
      draft: String = "", width: LayoutWidth = .regular, _ state: ComposerViewState
    ) -> OffscreenWindow<ComposerScreen> {
      OffscreenWindow(
        ComposerScreen(
          model: ComposerScreenModel(draft: draft, state: state), actions: log.actions,
          layout: .touch, layoutWidth: width))
    }

    @Test("a new session's bar is open with its chips, and each one still acts")
    func openRow() throws {
      var state = ComposerSamples.start
      state.approvalModes = ComposerSamples.codexModes()
      let screen = open(state)
      defer { screen.close() }
      #expect(try screen.shows("Auto-approve"))
      #expect(try screen.shows("Claude Code"))
      // The tray's folder and worktree, then Add and the host.
      let host = try screen.menu(at: 3)
      #expect(menuTitles(host).contains("Connect new host\u{2026}"))
    }

    @Test("a narrow bar keeps one word of the mode")
    func compactRow() throws {
      var state = ComposerSamples.start
      state.approvalModes = ComposerSamples.codexModes(selected: "full-access")
      let screen = open(width: .compact, state)
      defer { screen.close() }
      #expect(try screen.shows("Full"))
      #expect(try !screen.shows("Full access"))
    }

    @Test("a session's bar at rest is one row, and Full access stays visible as a warning")
    func collapsed() throws {
      var state = ComposerSamples.fullAccess
      state.tray = nil
      state.context = nil
      let screen = open(state)
      defer { screen.close() }
      #expect(try screen.shows("Full"))
      #expect(try !screen.shows("Codex"))
      #expect(screen.allViews.contains { $0 is NSTextView })
    }

    @Test("a draft opens the bar; Send sends from it")
    func draftOpens() throws {
      let screen = open(draft: "hello", ComposerSamples.idle)
      defer { screen.close() }
      #expect(try screen.shows("Auto-approve"))
      let send = try #require(screen.controlFrames.last)
      try screen.click(screen.clickPoint(send))
      #expect(log.events == ["send"])
    }

    @Test("the placeholder leaves out keys touch doesn't have")
    func placeholder() {
      let rules = ComposerSendRules(
        state: ComposerViewState(), draft: "", canQueue: false, layout: .touch)
      #expect(rules.placeholder == "Send a message\u{2026}")
    }

    @Test("a read-only session gets the reason in place of the field")
    func readOnly() throws {
      var state = ComposerViewState()
      state.isReadOnly = true
      state.availability = .unavailable(reason: "Archived")
      let screen = open(state)
      defer { screen.close() }
      #expect(try screen.shows("Archived"))
      #expect(!screen.allViews.contains { $0 is NSTextView })
    }

    @Test("a warning about where it runs keeps the tray up at rest")
    func offlineTray() throws {
      let screen = open(ComposerSamples.offline)
      defer { screen.close() }
      #expect(try screen.shows("Codex"))
    }

    @Test("the mode's short name is its first word")
    func shortName() {
      #expect(ApprovalModeChip.shortName("Full access") == "Full")
      #expect(ApprovalModeChip.shortName("Auto-edit") == "Auto-edit")
      #expect(ApprovalModeChip.shortName("").isEmpty)
    }
  }
#endif
