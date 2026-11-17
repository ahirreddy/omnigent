#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What a text cell offers around a settled message, as the SwiftUI row does: its menu with
  /// Share, its actions on keyboard focus and to VoiceOver, the linked-message flash, and text
  /// drawn ahead that reads as what it shows.
  @Suite("Transcript table text cell chrome", .serialized)
  @MainActor
  struct TranscriptTableTextCellChromeTests {
    private typealias Fixture = TranscriptFixture

    init() {
      // Copies go to the test's own clipboard, which a window would set up.
      SystemSideEffects.install()
      SystemSideEffects.reset()
    }

    private var copied: String? { SystemSideEffects.pasteboard.string(forType: .string) }

    /// Actions that offer every message action: Fork from here and Copy link.
    private func everyAction(forked: @escaping @MainActor (String) -> Void = { _ in })
      -> ConversationActions
    {
      var actions = ConversationActions()
      actions.forkFrom = { forked($0.id) }
      actions.messageURL = { URL(string: "https://example.com/c?message=\($0.id)") }
      return actions
    }

    /// A text cell showing `message` with `actions`.
    private func cell(_ message: Row, actions: ConversationActions) -> TranscriptTableTextCell {
      let style = textCellStyle(textCellEnvironment { $0.conversationActions = actions })
      let cell = TranscriptTableTextCell(style: style)
      cell.show(textCellRow(message), version: 0, width: textCellWidth)
      return cell
    }

    private func rightClick() throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    // MARK: Menu

    @Test("The menu runs each action, in SwiftUI's order, with Share and Copy Message ID last")
    func menuMatchesSwiftUI() throws {
      var forked: [String] = []
      let cell = cell(
        Fixture.answer("a1", "Body"), actions: everyAction { forked.append($0) })
      let menu = try #require(cell.menu(for: try rightClick()))
      #expect(
        menu.items.map(\.title).filter { !$0.isEmpty } == [
          "Copy", "Fork from Here\u{2026}", "Copy Link", "Share", "Copy Message ID",
        ])
      // Each with its symbol, as SwiftUI's labels show them.
      #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil })
      let share = try #require(menu.items.first { $0.title == "Share" })
      #expect(share.isEnabled)
      for (title, expected) in [
        ("Copy", "Body"), ("Copy Link", "https://example.com/c?message=a1"),
        ("Copy Message ID", "a1"),
      ] {
        try choose(title, in: menu)
        #expect(copied == expected, "\(title)")
      }
      try choose("Fork from Here\u{2026}", in: menu)
      #expect(forked == ["a1"])
    }

    /// Sends a menu item's action to its target, as choosing it does.
    private func choose(_ title: String, in menu: NSMenu) throws {
      let item = try #require(menu.items.first { $0.title == title }, "\(title) is offered")
      let action = try #require(item.action)
      #expect(NSApplication.shared.sendAction(action, to: item.target, from: item), "\(title)")
    }

    @Test("A fork the session refuses stays in the menu, disabled with why; no text, no Share")
    func menuRefusals() throws {
      var actions = ConversationActions()
      actions.forkUnavailableReason = "Only the owner can fork"
      let answer = cell(Fixture.answer("a1", "Body"), actions: actions)
      let menu = try #require(answer.menu(for: try rightClick()))
      let fork = try #require(menu.items.first { $0.title.hasPrefix("Fork from Here") })
      #expect(!fork.isEnabled)
      #expect(fork.subtitle == "Only the owner can fork")
      // A prompt of attachments alone has no text to copy or share.
      let attachment = Attachment(id: "f1", kind: .file, title: "notes.txt", reference: "file-1")
      let prompt = cell(
        Row(id: "u-only", role: .user, attachments: [attachment]), actions: ConversationActions())
      let promptMenu = try #require(prompt.menu(for: try rightClick()))
      #expect(!promptMenu.items.contains { $0.title == "Copy" })
      #expect(promptMenu.items.first { $0.title == "Share" }?.isEnabled == false)
    }

    // MARK: Keyboard focus

    /// Two turns: `a1`'s actions wait for hover or focus, `a2`'s stay shown.
    private let turns = [
      Fixture.user("u1", "First"), Fixture.answer("a1", "An older answer", responseID: "r1"),
      Fixture.user("u2", "Second"), Fixture.answer("a2", "The latest answer", responseID: "r2"),
    ]

    @Test("Keyboard focus on a message rings it and reveals its actions, as SwiftUI's row does")
    func focusRevealsActions() async throws {
      let saved = TranscriptTableTextCell.assistive
      defer { TranscriptTableTextCell.assistive = saved }
      TranscriptTableTextCell.assistive.keyboardNavigates = { true }
      let screen = try await textTableScreen(turns, actions: everyAction())
      defer { screen.close() }
      restKeyboard(screen)
      let cell = try textCell("a1", in: screen)
      #expect(cell.actionsView?.isHidden != false, "an older answer's actions wait")
      #expect(cell.acceptsFirstResponder && cell.canBecomeKeyView)
      #expect(screen.window.makeFirstResponder(cell))
      #expect(cell.actionsView?.isHidden == false, "focus reveals them")
      #expect(cell.focusRingMaskBounds == cell.contentFrame && !cell.contentFrame.isEmpty)
      // Focus moving on to one of them keeps them; moving away hides them.
      let button = try #require(cell.actionsView?.buttons.first)
      if button.acceptsFirstResponder {
        #expect(screen.window.makeFirstResponder(button))
        try await letTasksRun(screen)
        #expect(cell.actionsView?.isHidden == false, "a button with the keyboard keeps them")
      }
      screen.window.makeFirstResponder(nil)
      try await letTasksRun(screen)
      #expect(cell.actionsView?.isHidden == true, "focus gone, they hide again")
      // Without keyboard navigation a message takes no focus, as SwiftUI's doesn't.
      TranscriptTableTextCell.assistive.keyboardNavigates = { false }
      #expect(!cell.acceptsFirstResponder)
    }
  }
#endif
