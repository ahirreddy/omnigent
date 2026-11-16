#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Commands: the menu bar's groups")
  @MainActor
  struct CommandsBodyTests {
    @Test("Each set of commands builds its groups with nothing focused")
    func buildsWithNothingFocused() {
      // Each group's items are covered with state by the menu item tests; this is the wiring.
      _ = OmnigentTabCommands().body
      _ = OmnigentTabCommands(closeWindow: {}).body
      _ = OmnigentServerCommands().body
      _ = OmnigentSessionCommands().body
    }
  }
#endif
