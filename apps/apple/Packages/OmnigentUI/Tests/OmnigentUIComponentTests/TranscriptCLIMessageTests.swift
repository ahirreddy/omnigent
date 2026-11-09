#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("CLI messages", .serialized)
  @MainActor
  struct TranscriptCLIMessageTests {
    private typealias Fixture = TranscriptFixture

    init() {
      SystemSideEffects.reset()
    }

    @Test("A prompt's quoted lines split out, unless they're inside a code fence")
    func promptRuns() {
      #expect(UserPrompt.runs("plain") == [UserPrompt.Run(text: "plain", isQuote: false)])
      #expect(
        UserPrompt.runs("> quoted\n>tight\nreply") == [
          UserPrompt.Run(text: "quoted\ntight", isQuote: true),
          UserPrompt.Run(text: "reply", isQuote: false),
        ])
      #expect(
        UserPrompt.runs("```\n> code\n```") == [
          UserPrompt.Run(text: "```\n> code\n```", isQuote: false)
        ])
      #expect(UserPrompt.runs(">").isEmpty)
    }

    @Test("A prompt with a quote shows both the quote and the reply")
    func quotedPrompt() throws {
      let screen = transcriptScreen(CLIUserText(text: "> It said this\nMy reply"))
      defer { screen.close() }
      #expect(try screen.shows("It said this"))
      #expect(try screen.shows("My reply"))
      let plain = transcriptScreen(CLIUserText(text: "Just text"))
      defer { plain.close() }
      #expect(try plain.shows("Just text"))
    }

    @Test("Line text joins its parts, whatever their color")
    func lineParts() {
      var line = CLILineText()
      line.append("a", .init(red: 1, green: 0, blue: 0), bold: true)
      line.append("b")
      #expect(line.plain == "ab")
      #expect(String(line.attributed.characters) == "ab")
    }

    @Test("User bands and assistant blocks draw every part of a message")
    func messages() throws {
      var actions = ConversationActions()
      actions.forkFrom = { _ in }
      let row = Row(
        id: "u", role: .user, text: "Asked",
        activity: Activity(kind: .unknown, title: "Audio"),
        attachments: [Attachment(id: "f", kind: .file, title: "doc.txt")], interrupted: true)
      let band = transcriptScreen(
        CLIItemView(item: .message(row), decorations: ["u": MessageDecoration()]), actions: actions)
      defer { band.close() }
      for text in ["Asked", "doc.txt", "Interrupted"] { #expect(try band.shows(text), "\(text)") }

      let preparing = transcriptScreen(
        CLIItemView(
          item: .message(Row(id: "a", role: .assistant, isStreaming: true)), decorations: [:]))
      defer { preparing.close() }

      var answer = Fixture.answer("a", "Replied")
      answer.interrupted = true
      answer.activity = Activity(kind: .unknown, title: "Audio")
      for rendering in OutputRendering.allCases {
        let block = transcriptScreen(
          CLIItemView(item: .message(answer), decorations: [:])
            .transcriptAppearance(TranscriptAppearance(style: .cli, outputRendering: rendering)),
          actions: actions)
        defer { block.close() }
        #expect(try block.shows("Replied"), "\(rendering)")
        #expect(try block.shows("Interrupted"), "\(rendering)")
        let menu = try #require(try block.firstContextMenu())
        try block.choose("Copy", in: menu)
        #expect(copiedText() == "Replied")
      }

      let streaming = transcriptScreen(
        CLIItemView(
          item: .message(Row(id: "a", role: .assistant, text: "Part", isStreaming: true)),
          decorations: [:]
        )
        .transcriptAppearance(TranscriptAppearance(style: .cli, outputRendering: .rich)))
      defer { streaming.close() }
      #expect(try streaming.shows("Part"))
    }

    @Test("A settled turn's footer has the duration and time; the live one has none")
    func footer() throws {
      let answer = Fixture.answer("a")
      let segment = TurnSegment.item(.message(answer))
      let blocks = CLILayout.blocks(
        [segment], durations: ["resp-1": 12], timestamps: [:], isRunning: false)
      #expect(blocks.count == 2)
      guard case .footer(_, let text)? = blocks.last else {
        Issue.record("Expected a footer")
        return
      }
      #expect(text == "Worked for 12s")
      let live = CLILayout.blocks(
        [segment], durations: ["resp-1": 12], timestamps: [:], isRunning: true)
      #expect(live.count == 1)
      let closed = CLILayout.blocks(
        [segment], durations: ["resp-1": 12], timestamps: [:], isRunning: true,
        closesLastTurn: true)
      #expect(closed.count == 2)
      #expect(
        CLILayout.footer([segment], durations: [:], timestamps: [:], now: Date()) == nil)

      let line = transcriptScreen(CLIFooterLine(text: "Worked for 12s"))
      defer { line.close() }
      #expect(try line.shows("Worked for 12s"))
    }
  }
#endif
