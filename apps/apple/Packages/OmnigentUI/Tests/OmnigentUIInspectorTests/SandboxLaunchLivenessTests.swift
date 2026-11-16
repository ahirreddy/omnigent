#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A launching sandbox in the lines that would otherwise call its session disconnected.
  @Suite("Composer: a sandbox launch", .serialized)
  @MainActor
  struct SandboxLaunchLivenessTests {
    private let cloning = SandboxLaunchNote(label: "Cloning repository")
    private let waiting = SandboxLaunchNote(
      label: "Provisioning sandbox", standing: .waiting, note: "Sign in on your laptop.")
    private let failed = SandboxLaunchNote(
      label: "Sandbox launch failed", standing: .failed, note: "No capacity")

    /// A new sandbox session: no host yet and no runner, with `launch` reported.
    private func derive(_ launch: SandboxLaunchNote?, hostID: String? = nil) -> SessionLiveness {
      var signals = SessionLiveness.Signals(
        runnerOnline: false, hostOnline: hostID == nil ? nil : false, hostID: hostID)
      signals.launch = launch
      return SessionLiveness.derive(signals)
    }

    private func notice(
      _ liveness: SessionLiveness, failedLaunch: SandboxLaunchNote? = nil
    ) -> SessionLivenessNotice {
      var notice = SessionLivenessNotice(
        liveness: liveness, sessionID: "conv_1", serverURL: "http://127.0.0.1:6767",
        wrapper: nil, harness: "codex-native")
      notice.failedLaunch = failedLaunch
      return notice
    }

    @Test("A launch under way or waiting speaks before the host; a failed one leaves the rest")
    func derivation() {
      #expect(derive(nil) == .stranded)
      #expect(derive(cloning) == .launching(cloning))
      #expect(derive(waiting) == .launching(waiting))
      #expect(derive(failed) == .stranded)
      #expect(derive(failed, hostID: "sbx") == .hostOffline(isOwner: true))
      #expect(!SessionLiveness.launching(cloning).isUnreachable)
    }

    @Test("Each standing has its line, and a note only when there is one")
    func lines() {
      #expect(cloning.line == "Cloning repository\u{2026}")
      #expect(waiting.line == "Provisioning sandbox: Sign in on your laptop.")
      #expect(failed.line == "Sandbox launch failed: No capacity")
      #expect(
        SandboxLaunchNote(label: "Sandbox launch failed", standing: .failed).line
          == "Sandbox launch failed")
      #expect(
        SandboxLaunchNote(label: "Provisioning sandbox", standing: .waiting, note: "").line
          == "Provisioning sandbox")
      #expect(notice(.launching(cloning)).line == "Cloning repository\u{2026}")
      #expect(notice(.launching(cloning)).command == nil)
    }

    @Test("A failed launch names itself where a disconnect would be named")
    func failedNotice() {
      let stranded = notice(.stranded, failedLaunch: failed)
      #expect(stranded.title == "Sandbox launch failed")
      #expect(stranded.line == nil, "an unreachable session keeps its reconnect row")
      #expect(stranded.message.hasPrefix("Sandbox launch failed: No capacity. Run the command"))
      let asleep = notice(.asleep, failedLaunch: failed)
      #expect(asleep.line == "Sandbox launch failed: No capacity")
      #expect(notice(.asleep).line == "Agent is asleep \u{2014} send a message to reconnect")
      #expect(notice(.stranded).title == "Agent disconnected")
      #expect(notice(.stranded).message.hasPrefix("Run the command"))
    }

    @Test("While it launches the row names the stage with a spinner and offers no reconnect")
    func launchingRow() throws {
      let screen = OffscreenWindow(
        SessionLivenessRow(notice: notice(.launching(cloning)), actions: SessionLivenessActions()))
      defer { screen.close() }
      #expect(try screen.shows("Cloning repository\u{2026}"))
      #expect(screen.allViews.contains { $0 is NSProgressIndicator })
      #expect(try !screen.shows("Agent disconnected"))
      #expect(screen.buttons.isEmpty)
    }

    @Test("A launch that waits on the user says what to do, without a spinner")
    func waitingRow() throws {
      let screen = OffscreenWindow(
        SessionLivenessRow(notice: notice(.launching(waiting)), actions: SessionLivenessActions()))
      defer { screen.close() }
      #expect(try screen.shows("Provisioning sandbox: Sign in on your laptop."))
      #expect(!screen.allViews.contains { $0 is NSProgressIndicator })
      #expect(screen.buttons.isEmpty)
    }

    @Test("A failed launch says why: on the reconnect row, or on the line of a host that wakes")
    func failedRows() throws {
      let sheets = SessionLivenessSheets()
      var actions = SessionLivenessActions()
      actions.sheets = sheets
      let unreachable = OffscreenWindow(
        SessionLivenessRow(notice: notice(.stranded, failedLaunch: failed), actions: actions))
      defer { unreachable.close() }
      #expect(
        try unreachable.shows("Sandbox launch failed: No capacity \u{2014} reconnect\u{2026}"))
      #expect(try !unreachable.shows("Agent disconnected"))
      try unreachable.tapButton(0)
      unreachable.settle(0.5)
      #expect(sheets.shown == .reconnect)

      let wakes = OffscreenWindow(
        SessionLivenessRow(
          notice: notice(.asleep, failedLaunch: failed), actions: SessionLivenessActions()))
      defer { wakes.close() }
      #expect(try wakes.shows("Sandbox launch failed: No capacity"))
      #expect(try !wakes.shows("Agent is asleep"))
      #expect(wakes.buttons.isEmpty)
    }
  }
#endif
