/// A message that left the composer when Send was pressed and that the server has not accepted:
/// what the field held and the files the core holds for it. It is never sent again on its own.
public struct UnsentSend: Equatable, Sendable {
  /// The text, quotes and `@` paths the field held.
  public let draft: SavedDraft
  /// Its uploaded files (held in the core) and `@` paths.
  let extras: MessageQueue.Extras
  /// Why it did not go out; `nil` while it is in flight.
  public internal(set) var failure: String?

  init(draft: SavedDraft, extras: MessageQueue.Extras = MessageQueue.Extras()) {
    self.draft = draft
    self.extras = extras
  }
}
