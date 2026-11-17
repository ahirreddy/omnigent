#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// An answer as it streams in.
  @MainActor
  @Observable
  final class StreamedAnswer {
    var text: String
    var isStreaming = true

    init(_ text: String) {
      self.text = text
    }
  }

  private struct StreamedAnswerHost: View {
    let answer: StreamedAnswer

    var body: some View {
      MessageMarkdown(text: answer.text, isStreaming: answer.isStreaming)
        .environment(\.messageTextRenderer, .textKit)
        .frame(width: 500, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
    }
  }

  /// A streaming answer in the TextKit renderer: its text view takes each update in place.
  @MainActor
  @Suite("A streaming TextKit message", .serialized)
  struct MessageTextStreamingTests {
    private func color(of word: String, in view: MessageTextContentView) throws -> NSColor? {
      let text = try #require(view.textView.textContentStorage?.attributedString)
      return MessageTextFixture.value(.foregroundColor, at: word, in: text, as: NSColor.self)
    }

    @Test("Each update lands in the same text view, which grows; settling keeps it")
    func streams() throws {
      let answer = StreamedAnswer("First paragraph")
      let screen = transcriptScreen(StreamedAnswerHost(answer: answer), width: 520, height: 700)
      defer { screen.close() }
      let view = try #require(MessageTextFixture.contentViews(in: screen).first)
      #expect(view.isStreaming && view.textView.string == "First paragraph")
      let height = view.frame.height
      answer.text =
        "First paragraph.\n\nA second one, long enough to wrap: "
        + String(repeating: "more words ", count: 20)
      screen.settle()
      #expect(MessageTextFixture.contentViews(in: screen).first === view, "the same view")
      #expect(view.textView.string.hasPrefix("First paragraph.\nA second one"))
      #expect(view.frame.height > height, "the row grew: \(view.frame.height) from \(height)")
      answer.text += "\n\n```swift\nlet a = 1"
      screen.settle()
      #expect(try color(of: "let", in: view) == color(of: "a = 1", in: view), "still open")
      answer.text += "\n```"
      answer.isStreaming = false
      screen.settle()
      #expect(MessageTextFixture.contentViews(in: screen).first === view, "settling keeps it")
      #expect(!view.isStreaming)
      #expect(try color(of: "let", in: view) != color(of: "a = 1", in: view), "colored once closed")
      #expect(view.subviews.contains { $0 is MessageCodeHeaderView })
    }

    @Test("A run before the streaming block keeps its layout while the answer streams on")
    func earlierRunsKeepTheirLayout() throws {
      let answer = StreamedAnswer("Intro.\n\n$$\nx^2\n$$\n\nAfter")
      let screen = transcriptScreen(StreamedAnswerHost(answer: answer), width: 520, height: 700)
      defer { screen.close() }
      let views = MessageTextFixture.contentViews(in: screen)
      #expect(views.map(\.textView.string) == ["Intro.", "After"])
      let intro = try #require(views.first)
      let passes = intro.layoutPasses
      answer.text += " and more"
      screen.settle()
      #expect(MessageTextFixture.contentViews(in: screen).last?.textView.string == "After and more")
      #expect(intro.layoutPasses == passes, "an unchanged run lays out nothing again")
    }
  }
#endif
