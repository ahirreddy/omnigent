import SwiftUI

/// A `/btw` side question and its answer (the web's "Claude Quick Answer" overlay).
nonisolated public struct ComposerQuickAnswer: Hashable, Sendable {
  /// The question.
  public var question: String
  /// The answer, as Markdown.
  public var answer: String
  /// The terminal cut the answer short.
  public var isTruncated: Bool

  /// Creates an answer.
  /// - Parameters:
  ///   - question: The question.
  ///   - answer: The answer.
  ///   - isTruncated: Cut short.
  public init(question: String, answer: String, isTruncated: Bool = false) {
    self.question = question
    self.answer = answer
    self.isTruncated = isTruncated
  }
}

/// The `/btw` answer over the composer, never in the transcript: the question, the answer, and
/// a close button (Esc on the Mac). Sending waits until it is closed, as on the web.
struct QuickAnswerView: View {
  let answer: ComposerQuickAnswer
  let dismiss: (@MainActor () -> Void)?
  @Environment(\.composerLayoutStyle) private var layout

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack(alignment: .firstTextBaseline) {
        Label("Claude Quick Answer", systemImage: "bubble.left.and.text.bubble.right")
          .font(.callout.weight(.semibold))
        Spacer()
        if let dismiss {
          Button("Close", systemImage: "xmark", action: dismiss)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Close")
            .accessibilityIdentifier("quick-answer-close")
        }
      }
      part("Question") { Text(answer.question).textSelection(.enabled) }
      part("Answer") { MarkdownView(answer.answer) }
      if answer.isTruncated {
        Text("Answer was truncated")
          .font(.caption)
          .italic()
          .foregroundStyle(.secondary)
      }
      if layout != .touch {
        Text("Press Esc to close").font(.caption).foregroundStyle(.tertiary)
      }
    }
    .padding(Theme.Spacing.medium)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(cornerRadius: Theme.Radius.medium)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("quick-answer")
  }

  private func part(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      content()
    }
  }
}
