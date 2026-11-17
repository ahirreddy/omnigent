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

    // MARK: Hover

    /// The pointer entering or leaving, as a tracking area reports it.
    private func pointerEvent(_ type: NSEvent.EventType) -> NSEvent? {
      // Nothing reads the event's user data.
      unsafe NSEvent.enterExitEvent(
        with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
    }

    @Test(
      "An action button under the pointer takes SwiftUI's hover highlight; a disabled one doesn't")
    func actionHoverHighlight() throws {
      var actions = ConversationActions()
      actions.forkUnavailableReason = "Only the owner can fork"
      let style = textCellStyle(textCellEnvironment { $0.conversationActions = actions })
      var decoration = MessageDecoration()
      decoration.showsActions = true
      let cell = TranscriptTableTextCell(style: style)
      cell.show(
        textCellRow(Fixture.answer("a1", "Body"), decoration: decoration), version: 0,
        width: textCellWidth)
      let buttons = try #require(cell.actionsView?.buttons)
      #expect(buttons.count == 2, "Copy, and Fork from here disabled")
      let hover = try #require(style.palette?.hover.cgColor)
      let enter = try #require(pointerEvent(.mouseEntered))
      let exit = try #require(pointerEvent(.mouseExited))
      buttons[0].mouseEntered(with: enter)
      #expect(buttons[0].layer?.backgroundColor == hover)
      #expect(buttons[0].layer?.cornerRadius == Theme.Radius.small)
      buttons[0].mouseExited(with: exit)
      #expect(buttons[0].layer?.backgroundColor?.alpha == 0)
      buttons[1].mouseEntered(with: enter)
      #expect(buttons[1].layer?.backgroundColor?.alpha ?? 0 == 0, "a disabled action takes none")
    }

    @Test("Hover fades a message's actions in and out, as SwiftUI's row animates them")
    func actionsFade() async throws {
      let wasEnabled = Theme.Motion.isEnabled
      defer { Theme.Motion.isEnabled = wasEnabled }
      let screen = try await textTableScreen(turns, actions: everyAction())
      defer { screen.close() }
      restKeyboard(screen)
      let cell = try textCell("a1", in: screen)
      Theme.Motion.isEnabled = true
      cell.mouseEntered(with: try #require(pointerEvent(.mouseEntered)))
      let actions = try #require(cell.actionsView)
      #expect(actions.isShown && !actions.isHidden)
      cell.mouseExited(with: try #require(pointerEvent(.mouseExited)))
      #expect(!actions.isShown)
      #expect(try await waitUntil(screen) { actions.isHidden }, "hidden once faded out")
      #expect(actions.alphaValue == 1, "ready to show again")
      // Showing a row again, as scrolling does, doesn't fade.
      cell.mouseEntered(with: try #require(pointerEvent(.mouseEntered)))
      cell.refreshActions()
      #expect(actions.alphaValue == 1 && !actions.isHidden)
    }

    // MARK: VoiceOver

    @Test("VoiceOver gets the message's actions that apply, by title, and each one runs")
    func voiceOverActions() throws {
      var forked: [String] = []
      let answer = cell(Fixture.answer("a1", "Body"), actions: everyAction { forked.append($0) })
      let actions = try #require(answer.accessibilityCustomActions())
      #expect(actions.map(\.name) == ["Copy", "Fork from here", "Copy link"])
      for action in actions { #expect(action.handler?() == true, "\(action.name)") }
      #expect(forked == ["a1"])
      #expect(copied == "https://example.com/c?message=a1", "Copy link ran last")
      // A fork the session refuses isn't offered.
      var refused = ConversationActions()
      refused.forkUnavailableReason = "Only the owner can fork"
      let refusedCell = cell(Fixture.answer("a2", "Body"), actions: refused)
      #expect(refusedCell.accessibilityCustomActions()?.map(\.name) == ["Copy"])
    }

    @Test("With VoiceOver on, every message shows its actions, as a SwiftUI row's do")
    func voiceOverRevealsActions() async throws {
      let saved = TranscriptTableTextCell.assistive
      defer { TranscriptTableTextCell.assistive = saved }
      let screen = try await textTableScreen(turns, actions: everyAction())
      defer { screen.close() }
      restKeyboard(screen)
      let cell = try textCell("a1", in: screen)
      #expect(cell.actionsView?.isHidden != false)
      TranscriptTableTextCell.assistive.voiceOverIsOn = { true }
      try tableController(of: screen).refreshTextCellActions()
      #expect(cell.actionsView?.isHidden == false)
      TranscriptTableTextCell.assistive.voiceOverIsOn = { false }
      try tableController(of: screen).refreshTextCellActions()
      #expect(cell.actionsView?.isHidden == true)
    }

    // MARK: Linked-message flash

    @Test("A linked message's text cell tints around it for a moment, as SwiftUI's row does")
    func linkedMessageFlashes() async throws {
      let focus = TranscriptFocus()
      focus.flashDuration = .seconds(1)
      let screen = try await textTableScreen(turns) { $0.transcriptFocus = focus }
      defer { screen.close() }
      let flashed = try textCell("a1", in: screen)
      let prompt = try textCell("u2", in: screen)
      focus.flash("a1")
      #expect(try await waitUntil(screen) { flashed.flashView?.isHidden == false })
      let tint = try #require(flashed.flashView)
      // A little larger than the message, rounded, behind it; no other row tints.
      #expect(
        tint.frame
          == flashed.contentFrame.insetBy(dx: -Theme.Spacing.small, dy: -Theme.Spacing.small))
      #expect(tint.layer?.cornerRadius == Theme.Radius.medium)
      #expect(flashed.subviews.first === tint)
      #expect(prompt.flashView?.isHidden != false)
      // It fades after a moment, and goes once the flash ends.
      #expect(try await waitUntil(screen) { tint.alphaValue == 0 })
      #expect(try await waitUntil(screen) { tint.isHidden })
      // A prompt tints its whole row in the column, as its SwiftUI row's frame is.
      focus.flash("u2")
      #expect(try await waitUntil(screen) { prompt.flashView?.isHidden == false })
      let bubble = try #require(prompt.subviews.first { $0 is TranscriptTableBubbleView })
      #expect(prompt.contentFrame.width > bubble.frame.width)
      #expect(prompt.contentFrame.contains(bubble.frame))
    }
  }
#endif
