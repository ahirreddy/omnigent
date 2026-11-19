import Foundation

/// A user's reply to Codex async questions (``Row/questionReplies``) as the text its prompt is
/// drawn from. Each answer reads under its question, `↪ Re: <question>`, as the web shows it;
/// the question is a small quoted line in the secondary color.
///
/// The text caches and prewarms key a message by one string and parse it again whenever they
/// need its blocks, so a reply's text is a prefix no message starts with followed by its
/// replies as JSON, and ``MarkdownParser`` reads it back into ``blocks(_:)``.
nonisolated enum QuestionReplyMarkdown {
  /// What starts a reply's text.
  static let prefix = "\u{0}omnigent-question-reply\u{0}"
  /// What the web puts before each question.
  static let quotePrefix = "\u{21AA} Re: "

  /// The text a reply's prompt is drawn from; `nil` for no replies.
  static func text(_ replies: [QuestionReply]) -> String? {
    guard !replies.isEmpty else { return nil }
    let pairs = replies.map { [$0.question, $0.answer] }
    let data: Data
    do {
      data = try JSONEncoder().encode(pairs)
    } catch {
      // Strings always encode; without the JSON the prompt draws as its plain text.
      return nil
    }
    return String(bytes: data, encoding: .utf8).map { prefix + $0 }
  }

  /// The replies `text` holds; none unless it is a reply's text.
  static func replies(in text: String) -> [QuestionReply] {
    guard text.hasPrefix(prefix) else { return [] }
    let json = Data(text.dropFirst(prefix.count).utf8)
    let pairs: [[String?]]
    do {
      pairs = try JSONDecoder().decode([[String?]].self, from: json)
    } catch {
      // Only ``text(_:)`` writes the prefix; anything else after it is ordinary text.
      return []
    }
    var replies: [QuestionReply] = []
    for pair in pairs {
      guard pair.count == 2, let answer = pair[1] else { return [] }
      replies.append(QuestionReply(question: pair[0], answer: answer))
    }
    return replies
  }

  /// The blocks of `replies`: each question as a quoted line, then its answer's markdown.
  static func blocks(_ replies: [QuestionReply]) -> [MarkdownBlock] {
    replies.flatMap { reply -> [MarkdownBlock] in
      let answer = MarkdownParser.parse(reply.answer)
      guard let question = reply.question else { return answer }
      return [.paragraph(quote(question))] + answer
    }
  }

  /// `↪ Re: <question>`, marked as a reply's quoted question.
  static func quote(_ question: String) -> AttributedString {
    var quote = AttributedString(quotePrefix + question)
    quote[QuestionReplyQuoteAttribute.self] = true
    return quote
  }
}

/// Marks a paragraph as a reply's quoted question, which draws small and secondary.
nonisolated enum QuestionReplyQuoteAttribute: AttributedStringKey {
  typealias Value = Bool
  static let name = "omnigent.questionReplyQuote"
}

nonisolated extension AttributedString {
  /// Whether it is a reply's quoted question (``QuestionReplyMarkdown/quote(_:)``).
  var isQuestionReplyQuote: Bool {
    runs.first?[QuestionReplyQuoteAttribute.self] == true
  }
}

nonisolated extension TypeRamp {
  /// A reply's quoted question, as a multiple of the body.
  static let questionQuoteScale: CGFloat = 0.85
  /// The gap between a reply's quoted question and its answer.
  static let questionQuoteBelow: CGFloat = 4

  /// A reply's quoted question's size.
  var questionQuote: CGFloat { (body * Self.questionQuoteScale).rounded() }

  /// A reply's quoted question's line height.
  var questionQuoteLineHeight: CGFloat { Self.snapped(questionQuote * Self.headingLeading) }
}
