import Testing

@testable import OmnigentUIComponents

#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  @testable import OmnigentUITestSupport
#endif

/// The draft's tints, as the web's composer paints them: a leading command or skill the
/// session knows, a shell command's `!`, and tagged `@` paths.
@Suite("Composer: tinted commands, shell commands and mentions")
@MainActor
struct ComposerTokenTests {
  private let commands = [
    SlashCommand(name: "review"), SlashCommand(name: "compact"),
    SlashCommand(name: "deploy-notes", isSkill: true),
    SlashCommand(name: "lint", prefix: "$", isSkill: true),
  ]

  private func tokens(_ draft: String, shell: Bool = false, mentions: [String] = [])
    -> [ComposerTokens.Token]
  {
    ComposerTokens(
      draft: draft,
      source: ComposerTokenSource(commands: commands, isShell: shell, mentions: mentions)
    ).tokens
  }

  @Test("A leading known command or skill is tinted; an unknown one stays plain")
  func knownCommands() {
    #expect(tokens("/review the store") == [.init(kind: .command, range: 0..<7)])
    #expect(tokens("  /compact") == [.init(kind: .command, range: 2..<10)])
    #expect(tokens("/REVIEW now") == [.init(kind: .command, range: 0..<7)], "commands any case")
    #expect(tokens("/Deploy-notes").isEmpty, "skills as written")
    #expect(tokens("$lint src") == [.init(kind: .command, range: 0..<5)])
    #expect(tokens("/reviewer").isEmpty)
    #expect(tokens("/unknown thing").isEmpty)
    #expect(tokens("please /review").isEmpty, "only a leading command")
  }

  @Test("A shell command tints its `!` rather than a command")
  func shell() {
    #expect(tokens("!git status", shell: true) == [.init(kind: .shell, range: 0..<1)])
    #expect(tokens("  !ls", shell: true) == [.init(kind: .shell, range: 2..<3)])
    #expect(tokens("!git status").isEmpty, "not a shell command here")
  }

  @Test("Tagged paths are tinted where they start a word and end at a boundary")
  func mentions() {
    let paths = ["src/app.swift", "src/app.swift:3-9", "README.md"]
    #expect(
      tokens("see @src/app.swift:3-9, and @README.md.", mentions: paths) == [
        .init(kind: .mention, range: 4..<22), .init(kind: .mention, range: 28..<38),
      ])
    #expect(tokens("x@README.md", mentions: paths).isEmpty)
    #expect(tokens("@README.mdx", mentions: paths).isEmpty)
    #expect(
      tokens("/review @README.md", mentions: paths) == [
        .init(kind: .command, range: 0..<7), .init(kind: .mention, range: 8..<18),
      ])
  }

  #if os(macOS)
    @Test("A composer with its completion list open claims Escape, and one without doesn't")
    func claimsEscape() throws {
      final class Claim {
        var value = false
      }
      var state = ComposerSamples.idle
      state.slashCommands = commands
      for (draft, expected) in [("/re", true), ("hello", false)] {
        let claim = Claim()
        let screen = OffscreenWindow(
          ComposerView(draft: .constant(draft), state: state, actions: ComposerActions(send: {}))
            .onPreferenceChange(ComposerClaimsEscape.self) { claim.value = $0 }
            .frame(width: 480, height: 300))
        defer { screen.close() }
        screen.settle()
        #expect(claim.value == expected, "\(draft)")
      }
    }

    @Test("The editor shows the tint on the command and keeps typing plain after it")
    func editorTint() throws {
      var state = ComposerSamples.idle
      state.slashCommands = commands
      let model = ComposerScreenModel(draft: "/review", state: state)
      let screen = openComposer(model, ComposerActionLog().actions)
      defer { screen.close() }
      try screen.type(" now")
      screen.settle()
      #expect(model.draft == "/review now")
      let textView = try #require(screen.textView)
      let storage = NSAttributedString(attributedString: textView.attributedString())
      #expect(storage.string == "/review now")
      let command = unsafe storage.attribute(.foregroundColor, at: 1, effectiveRange: nil)
      let typed = unsafe storage.attribute(.foregroundColor, at: 9, effectiveRange: nil)
      #expect(command != nil, "the command is tinted")
      #expect(
        (typed as? NSColor) != (command as? NSColor), "text typed after it takes no tint")
    }

    @Test(
      "Untinted text has a color that reads on the appearance: a text view draws none as black",
      arguments: [true, false])
    func untintedTextColor(isDark: Bool) throws {
      var state = ComposerSamples.idle
      state.slashCommands = commands
      let model = ComposerScreenModel(state: state)
      let screen = openComposer(
        model, ComposerActionLog().actions, appearance: isDark ? .darkAqua : .aqua)
      defer { screen.close() }
      let textView = try #require(screen.textView)
      try screen.type("hello")
      screen.settle()
      let typed = Self.luminances(textView)
      #expect(typed.count == 5)
      #expect(typed.allSatisfy { $0.map { isDark ? $0 > 0.5 : $0 < 0.5 } == true }, "\(typed)")

      model.draft = "/review"
      screen.settle()
      try screen.type(" now")
      screen.settle()
      let tinted = Self.luminances(textView)
      #expect(textView.string == "/review now")
      #expect(tinted.allSatisfy { $0 != nil }, "every character has a color: \(tinted)")
      let after = tinted.dropFirst(7)
      #expect(after.allSatisfy { $0.map { isDark ? $0 > 0.5 : $0 < 0.5 } == true }, "\(tinted)")
    }

    @Test("Typing after a tinted command and mention keeps the draft and the editor in step")
    func typingAfterTints() throws {
      var state = ComposerSamples.idle
      state.slashCommands = commands
      state.mentions = ["x"]
      let model = ComposerScreenModel(state: state)
      let screen = openComposer(model, ComposerActionLog().actions)
      defer { screen.close() }
      let textView = try #require(screen.textView)
      // The text view's own insert, as the input system sends each key; then real key presses.
      for character in "/review @x more" {
        textView.insertText(
          String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        screen.settle(0.02)
      }
      try screen.type(" text")
      screen.settle()
      #expect(model.draft == "/review @x more text")
      #expect(textView.string == model.draft)
      let storage = NSAttributedString(attributedString: textView.attributedString())
      let command = unsafe storage.attribute(.foregroundColor, at: 1, effectiveRange: nil)
      let mention = unsafe storage.attribute(.backgroundColor, at: 9, effectiveRange: nil)
      let typed = unsafe storage.attribute(.backgroundColor, at: 12, effectiveRange: nil)
      #expect((command as? NSColor) != nil, "the command is tinted")
      #expect(mention != nil, "the mention has its fill")
      #expect(typed == nil, "text after the mention has none")
    }

    /// Each character's text color as its text view's appearance draws it, by relative
    /// luminance; `nil` for a character without one.
    private static func luminances(_ textView: NSTextView) -> [Double?] {
      let storage = NSAttributedString(attributedString: textView.attributedString())
      let appearance = textView.effectiveAppearance
      return (0..<storage.length).map { index in
        let value = unsafe storage.attribute(.foregroundColor, at: index, effectiveRange: nil)
        guard let color = value as? NSColor else { return nil }
        var luminance = 0.0
        appearance.performAsCurrentDrawingAppearance {
          guard let rgb = color.usingColorSpace(.sRGB) else { return }
          luminance =
            0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        }
        return luminance
      }
    }
  #endif
}
