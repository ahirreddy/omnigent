import OmnigentCoreFFI

/// Reply quotes, as the web's composer keeps them: each quoted selection is a block with the
/// text typed before it, and the draft sends them as Markdown block quotes (the core's
/// `ReplyDraft`).
extension ComposerStore {
  /// What sending the draft sends: the quotes, a blank line apart, then ``text``.
  public var draftMessage: String {
    quotes.isEmpty ? text : replyDraftMessage(draft: ReplyDraft(quotes: quotes, text: text))
  }

  /// Quotes `selection` after the draft; the text typed so far moves before the quote and the
  /// reply starts empty. A blank selection changes nothing.
  /// - Parameter selection: The transcript text.
  public func quote(_ selection: String) {
    apply(replyDraftQuoting(draft: ReplyDraft(quotes: quotes, text: text), selection: selection))
  }

  /// Removes quote `index`; the text typed before it joins the text after it.
  /// - Parameter index: The quote.
  public func removeQuote(at index: Int) {
    guard quotes.indices.contains(index) else { return }
    apply(replyDraftRemoving(draft: ReplyDraft(quotes: quotes, text: text), index: UInt32(index)))
  }

  /// Replaces the text typed before quote `index`.
  /// - Parameters:
  ///   - index: The quote.
  ///   - text: The new text.
  public func editQuoteLead(at index: Int, text: String) {
    guard quotes.indices.contains(index), quotes[index].before != text else { return }
    quotes[index].before = text
  }

  /// Empties the draft: text, quotes and `@` paths.
  func clearDraft() {
    quotes = []
    text = ""
    mentions = []
  }

  private func apply(_ draft: ReplyDraft) {
    quotes = draft.quotes
    text = draft.text
  }
}
