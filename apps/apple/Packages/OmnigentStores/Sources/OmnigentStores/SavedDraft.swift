import Foundation
public import OmnigentCoreFFI

/// A composer draft as ``ComposerDraftArchive`` keeps it: the text after the last quote, the
/// quote blocks with the text typed before each, and the `@` paths.
public struct SavedDraft: Codable, Equatable, Sendable {
  /// A quote block and the text typed before it.
  public struct Quote: Codable, Equatable, Sendable {
    /// The text typed before the quote.
    public var before: String
    /// The quoted text.
    public var text: String

    /// A quote of `text` after `before`.
    public init(before: String, text: String) {
      self.before = before
      self.text = text
    }
  }

  /// The text after the last quote.
  public var text: String
  /// The quote blocks, in order.
  public var quotes: [Quote]
  /// The tagged workspace paths.
  public var mentions: [String]

  /// A draft of `text` after `quotes`, with `mentions`.
  public init(text: String, quotes: [Quote] = [], mentions: [String] = []) {
    self.text = text
    self.quotes = quotes
    self.mentions = mentions
  }

  /// Nothing to keep: blank text, no quotes and no paths.
  public var isEmpty: Bool {
    quotes.isEmpty && mentions.isEmpty
      && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The quotes as the core's reply-draft records.
  public var replyQuotes: [ReplyQuote] {
    quotes.map { ReplyQuote(before: $0.before, text: $0.text) }
  }

  /// What sending it sends, without the `@` paths: the quotes as Markdown block quotes, then
  /// the text.
  public var message: String {
    quotes.isEmpty ? text : replyDraftMessage(draft: ReplyDraft(quotes: replyQuotes, text: text))
  }

  private enum CodingKeys: String, CodingKey { case text, quotes, mentions }

  /// Reads a draft object, or the plain text earlier versions saved.
  public init(from decoder: any Decoder) throws {
    let container: KeyedDecodingContainer<CodingKeys>
    do {
      container = try decoder.container(keyedBy: CodingKeys.self)
    } catch DecodingError.typeMismatch {
      self.init(text: try decoder.singleValueContainer().decode(String.self))
      return
    }
    self.init(
      text: try container.decode(String.self, forKey: .text),
      quotes: try container.decodeIfPresent([Quote].self, forKey: .quotes) ?? [],
      mentions: try container.decodeIfPresent([String].self, forKey: .mentions) ?? [])
  }
}
