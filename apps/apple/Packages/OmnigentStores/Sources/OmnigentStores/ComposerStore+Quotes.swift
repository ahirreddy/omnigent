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

  /// What the field holds: text, quotes and `@` paths.
  var fieldDraft: SavedDraft {
    SavedDraft(
      text: text, quotes: quotes.map { SavedDraft.Quote(before: $0.before, text: $0.text) },
      mentions: mentions)
  }

  /// The draft to keep across launches: the field, then the messages that left it and were not
  /// accepted, so quitting while one is out loses nothing.
  var savedDraft: SavedDraft {
    (unsentOffers + [inFlight].compactMap(\.self)).reduce(fieldDraft) { $0.appending($1.draft) }
  }

  /// Puts a kept draft back, recording it once (the core's text, the sidebar marker, the file).
  /// - Parameter draft: The draft.
  func restore(_ draft: SavedDraft) {
    isRestoring = true
    quotes = draft.replyQuotes
    text = draft.text
    mentions = draft.mentions
    isRestoring = false
    draftDidChange()
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
