import SwiftUI

/// A user's reply to an agent's questions in a bubble: its reply's text
/// (``QuestionReplyMarkdown``) as markdown, each answer under its quoted question, built from
/// the same blocks a text cell draws.
struct QuestionReplyBody: View {
  /// The reply's text, from ``QuestionReplyMarkdown/text(_:)``.
  let source: String

  var body: some View {
    MessageMarkdown(text: source, fillsWidth: false)
      .environment(\.markdownFillsWidth, false)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("question-reply")
  }
}

/// `↪ Re: <question>` over a reply's answer, as ``MarkdownView`` draws the quoted line: smaller
/// than the answer, in the secondary color.
struct QuestionReplyQuoteLine: View {
  let line: String
  @Environment(\.typeRamp) private var ramp

  var body: some View {
    Text(verbatim: line)
      .font(.system(size: ramp.questionQuote))
      .lineHeight(.exact(points: ramp.questionQuoteLineHeight))
      .foregroundStyle(.secondary)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("question-reply-quote")
  }
}
