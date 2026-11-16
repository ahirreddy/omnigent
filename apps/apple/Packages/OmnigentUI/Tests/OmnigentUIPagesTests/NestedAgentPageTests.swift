#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The new-session page as the Add nested agent composer: its subtitle, the notice it shows
  /// before the composer can, and the shortcut guide's line for it.
  @Suite("Add nested agent: page and shortcut guide", .serialized)
  @MainActor
  struct NestedAgentPageTests {
    @Test("the page shows the subtitle under its heading")
    func subtitle() throws {
      let page = NewSessionPage(
        draft: .constant(""), composer: ComposerViewState(purpose: .start),
        actions: ComposerActions(send: {}), heading: "Add nested agent",
        subtitle: "A new conversation alongside Coordinator")
      let screen = OffscreenWindow(page.frame(width: 800, height: 600), width: 800, height: 600)
      defer { screen.close() }
      #expect(try screen.shows("Add nested agent"))
      #expect(try screen.shows("A new conversation alongside Coordinator"))
    }

    @Test("the notice says why, waits while loading, and offers its way on")
    func notice() throws {
      let log = HostLog()
      let offering = OffscreenWindow(
        NewSessionNotice(
          title: "Add nested agent", message: "Source session is unavailable.",
          action: (title: "Continue in a new session", run: { log.add("continue") })
        ).frame(width: 600, height: 400), width: 600, height: 400)
      defer { offering.close() }
      #expect(try offering.shows("Source session is unavailable."))
      try offering.clickControl(at: 0)
      #expect(log.entries == ["continue"])

      let waiting = OffscreenWindow(
        NewSessionNotice(
          title: "Add nested agent", message: "Loading source session\u{2026}", isWaiting: true
        ).frame(width: 600, height: 400), width: 600, height: 400)
      defer { waiting.close() }
      // A busy machine can take more than one settle to draw the spinner's label.
      _ = try MainLoop.settle(until: { try waiting.shows("Loading source session\u{2026}") })
      #expect(try waiting.shows("Loading source session\u{2026}"))
      #expect(waiting.allViews.contains { $0 is NSProgressIndicator })
      #expect(waiting.controlFrames.isEmpty, "nothing to click while it waits")
    }

    @Test("the shortcut guide lists Option-Command-A only where nested agents are offered")
    func shortcutGuide() {
      func keys(nestedAgents: Bool) -> String? {
        ShortcutGuide.groups(
          submitWithCommandReturn: false, isMac: true, nestedAgents: nestedAgents
        )
        .flatMap(\.rows).first { $0.title == "Add a nested agent to the current session" }?.keys
      }
      #expect(keys(nestedAgents: true) == "⌥⌘A")
      #expect(keys(nestedAgents: false) == nil)
      #expect(AppShortcuts.text(AppShortcuts.addNestedAgent) == "⌥⌘A")
    }

    @Test("the shortcuts sheet takes the server's offer")
    func shortcutsSheet() throws {
      let screen = OffscreenWindow(
        KeyboardShortcutsSheet(nestedAgents: true).frame(width: 540, height: 620),
        width: 540, height: 620)
      defer { screen.close() }
      #expect(try screen.shows("Add a nested agent to the current session"))
    }
  }
#endif
