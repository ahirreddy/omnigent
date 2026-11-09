#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The agent's liveness under the composer and the reconnect sheet it opens.
  @Suite("Composer: liveness and reconnect", .serialized)
  @MainActor
  struct ComposerLivenessRowTests {
    private final class Log {
      var events: [String] = []
    }
    private let log = Log()

    private func notice(_ liveness: SessionLiveness) -> SessionLivenessNotice {
      SessionLivenessNotice(
        liveness: liveness, sessionID: "conv_1", serverURL: "http://127.0.0.1:6767",
        wrapper: nil, harness: "codex-native")
    }

    private func moveActions() -> HostMoveActions {
      HostMoveActions(
        loadHosts: { .success([]) }, home: { _ in nil },
        browse: { _, _ in .failure(FolderBrowseError(message: "No")) }, submit: { _ in .moved })
    }

    private func actions(
      switchHost: Bool = false, resume: Bool = false, sheets: SessionLivenessSheets? = nil
    ) -> SessionLivenessActions {
      let log = log
      var actions = SessionLivenessActions(
        checkAgain: { log.events.append("check") }, fork: { log.events.append("fork") })
      if switchHost {
        actions.switchHost = HostMoveRoute(
          kind: .switchHost(currentHostID: nil), actions: moveActions())
      }
      if resume {
        actions.resume = HostMoveRoute(
          kind: .resume(preferredHostID: nil, workspace: nil), actions: moveActions())
      }
      actions.sheets = sheets
      return actions
    }

    @Test("a waking agent and a sleeping one each get a quiet line")
    func lines() throws {
      let waking = OffscreenWindow(
        SessionLivenessRow(notice: notice(.starting), actions: actions()))
      defer { waking.close() }
      #expect(try waking.shows("Connecting\u{2026}"))
      #expect(waking.allViews.contains { $0 is NSProgressIndicator })
      let asleep = OffscreenWindow(SessionLivenessRow(notice: notice(.asleep), actions: actions()))
      defer { asleep.close() }
      #expect(try asleep.shows("Agent is asleep"))
    }

    @Test("a live agent shows nothing to press")
    func online() throws {
      let screen = OffscreenWindow(SessionLivenessRow(notice: notice(.online), actions: actions()))
      defer { screen.close() }
      #expect(screen.buttons.isEmpty)
    }

    @Test("an offline host's row opens the reconnect sheet; the sheet can bring in another")
    func opensSheet() throws {
      let sheets = SessionLivenessSheets()
      let screen = OffscreenWindow(
        SessionLivenessRow(
          notice: notice(.hostOffline(isOwner: true)),
          actions: actions(switchHost: true, sheets: sheets)))
      defer { screen.close() }
      #expect(try screen.shows("Host is offline \u{2014} reconnect\u{2026}"))
      try screen.tapButton(0)
      screen.settle(0.5)
      #expect(sheets.shown == .reconnect)
      #expect(screen.window.attachedSheet != nil)
      sheets.shown = .switchHost
      screen.settle(0.5)
      #expect(screen.window.attachedSheet != nil)
      sheets.shown = nil
      screen.settle(0.5)
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("with no store of its own the row keeps its sheet itself")
    func localSheet() throws {
      let screen = OffscreenWindow(
        SessionLivenessRow(notice: notice(.stranded), actions: actions(resume: true)))
      defer { screen.close() }
      #expect(try screen.shows("Agent disconnected"))
      try screen.tapButton(0)
      screen.settle(0.5)
      #expect(screen.window.attachedSheet != nil)
    }

    @Test("the sheet gives the command for an owner, none otherwise, and each way out")
    func sheetContent() throws {
      var shown: [SessionLivenessSheet?] = []
      let owner = OffscreenWindow(
        ReconnectSessionSheet(
          notice: notice(.hostOffline(isOwner: true)), actions: actions(switchHost: true)
        ) { shown.append($0) })
      defer { owner.close() }
      #expect(try owner.shows("Copy Command"))
      #expect(try owner.shows("Switch Host\u{2026}"))
      #expect(try owner.shows("Or fork the session to continue in a copy."))
      #expect(try owner.shows(try #require(notice(.hostOffline(isOwner: true)).command)))

      let viewer = OffscreenWindow(
        ReconnectSessionSheet(
          notice: notice(.hostOffline(isOwner: false)), actions: actions(), show: { _ in }))
      defer { viewer.close() }
      #expect(try viewer.shows("Fork Session\u{2026}"))
      #expect(try !viewer.shows("Copy Command"))
      #expect(try viewer.shows("Can\u{2019}t bring that machine back?"))

      let stranded = OffscreenWindow(
        ReconnectSessionSheet(
          notice: notice(.stranded), actions: actions(resume: true), show: { _ in }))
      defer { stranded.close() }
      #expect(try stranded.shows("Resume on a Machine\u{2026}"))
    }

    @Test("Check Again, Fork and the move buttons close or replace the sheet")
    func sheetButtons() throws {
      var shown: [SessionLivenessSheet?] = []
      let screen = OffscreenWindow(
        ComposerSheetHost(
          sheet: ReconnectSessionSheet(
            notice: notice(.hostOffline(isOwner: true)), actions: actions(switchHost: true)
          ) { shown.append($0) }))
      defer { screen.close() }
      screen.settle(0.5)
      // The title bar's control, Copy Command, Switch Host, Check Again, Fork, then Done.
      SystemSideEffects.reset()
      try screen.tapButton(1)
      #expect(
        SystemSideEffects.pasteboard.string(forType: .string)
          == notice(.hostOffline(isOwner: true)).command)
      try screen.tapButton(fromEnd: 3)
      #expect(shown == [.switchHost])
      try screen.tapButton(fromEnd: 2)
      #expect(log.events == ["check"])
      try screen.tapButton(fromEnd: 1)
      #expect(log.events == ["check", "fork"])
      try screen.tapButton(fromEnd: 0)
      #expect(shown == [.switchHost, nil, nil, nil])
    }
  }
#endif
