#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A sent prompt's leading command, tinted in the transcript as the web's bubble tints it.
  @MainActor
  @Suite("Transcript: a sent prompt's leading command")
  struct PromptCommandTests {
    private let commands = [
      SlashCommand(name: "review"), SlashCommand(name: "lint", prefix: "$", isSkill: true),
    ]

    @Test("only a leading command the session knows is marked, where it starts the first line")
    func marking() {
      #expect(
        PromptCommand.marked("/review the store", commands: commands)
          == "[/review](omnigent-command:) the store")
      #expect(
        PromptCommand.marked("\n/REVIEW now", commands: commands)
          == "\n[/REVIEW](omnigent-command:) now")
      #expect(
        PromptCommand.marked("$lint src", commands: commands) == "[$lint](omnigent-command:) src")
      for plain in ["/unknown thing", "please /review", "    /review indented", "/reviewer"] {
        #expect(PromptCommand.marked(plain, commands: commands) == plain, "\(plain)")
      }
      #expect(PromptCommand.marked("/review", commands: []) == "/review")
    }

    @Test("the parser keeps a marked command's words, draws no link and marks them")
    func parsing() throws {
      let blocks = MarkdownParser.parse(PromptCommand.marked("/review it", commands: commands))
      guard case .paragraph(let text) = try #require(blocks.first) else {
        Issue.record("not a paragraph: \(blocks)")
        return
      }
      #expect(String(text.characters) == "/review it")
      let marked = text.runs[PromptCommandAttribute.self].filter { $0.0 == true }
      #expect(marked.map { String(text[$0.1].characters) } == ["/review"])
      #expect(text.runs.allSatisfy { $0.link == nil })
      let tinted = PromptCommand.tinted(text, color: .orange)
      #expect(tinted.runs.first?.foregroundColor == .orange)
    }

    @Test("TextKit text draws the marked command in the accent and the rest as text")
    func textKit() throws {
      let document = MessageTextFixture.document(
        PromptCommand.marked("/review the store", commands: commands))
      let text = document.text
      #expect(text.string == "/review the store")
      let palette = MessageTextPalette(MessageTextFixture.style)
      let command = MessageTextFixture.value(.foregroundColor, at: 1, in: text, as: NSColor.self)
      let rest = MessageTextFixture.value(.foregroundColor, at: "store", in: text, as: NSColor.self)
      #expect(command == palette.accent)
      #expect(rest == palette.text)
      #expect(MessageTextFixture.value(.link, at: 1, in: text, as: URL.self) == nil)
    }

    @Test("a CLI prompt's leading command takes the composer's tint")
    func cliTextKit() throws {
      let palette = CLIPalette(theme: .nord, dark: true, increasedContrast: false)
      let tint = SRGB(red: 1, green: 0.5, blue: 0)
      let style = CLITextStyle(
        points: CGFloat(TranscriptAppearance.defaultFontSize), scale: 2, palette: palette,
        promptCommands: commands, commandTint: tint)
      let build = CLITextBuilder.build(.prompt("/review the store"), style: style)
      let command = unsafe build.text.attribute(.foregroundColor, at: 1, effectiveRange: nil)
      let rest = unsafe build.text.attribute(.foregroundColor, at: 10, effectiveRange: nil)
      #expect((command as? NSColor) == tint.platformColor)
      #expect((rest as? NSColor) == palette.userText.platformColor)
      let plain = CLITextBuilder.build(
        .prompt("/review the store"),
        style: CLITextStyle(points: style.points, scale: 2, palette: palette))
      let untinted = unsafe plain.text.attribute(.foregroundColor, at: 1, effectiveRange: nil)
      #expect((untinted as? NSColor) == palette.userText.platformColor)
    }
  }
#endif
