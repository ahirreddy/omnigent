import AppKit
import OmnigentCoreFFI
import OmnigentViewTesting
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

#if DEBUG
  /// Typing into the mounted window's composer, bound to the conversation's own store, through
  /// the binding chain a draft write once trapped in (the text view's storage commit).
  @MainActor
  @Suite("Typing in the window's composer", .serialized, .timeLimit(.minutes(1)))
  struct ComposerTypingWindowTests {
    @Test("Typing after a tinted command and mention keeps the draft and the editor in step")
    func typingAfterTints() async throws {
      let window = try await BudgetWindow.open()
      defer { window.screen.close() }
      let composer = try window.conversation(BudgetWindow.shown).composer
      composer.rules.slashCommands = [
        OmnigentCoreFFI.SlashCommand(
          name: "review", prefix: "/", description: "Review changes", isSkill: false)
      ]
      composer.mentions = ["x"]
      window.screen.settle(0.2)
      let editor = try #require(window.editor)
      // The text view's own insert, as the input system sends each key; then real key presses.
      for character in "/review @x more" {
        editor.insertText(
          String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        window.screen.settle(0.02)
      }
      try window.screen.type(" text")
      window.screen.settle(0.2)
      #expect(composer.text == "/review @x more text")
      #expect(editor.string == composer.text)
      let storage = NSAttributedString(attributedString: editor.attributedString())
      let mention = unsafe storage.attribute(.backgroundColor, at: 9, effectiveRange: nil)
      #expect(mention != nil, "the mention has its fill")
    }
  }
#endif
