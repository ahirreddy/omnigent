import Foundation

/// A settled CLI block a CLI text cell draws as TextKit text (``TranscriptTableCLICell``): an
/// answer in Plain or Styled rendering, a user's prompt, or the line under a settled turn. A
/// block holding anything only SwiftUI draws (attachments, an activity, an interruption) stays
/// hosted, as do the turn's tool work and Rich rendering.
nonisolated struct TranscriptTableCLIText: Sendable {
  enum Kind: Sendable {
    case answer
    case prompt
    case footer
  }

  let kind: Kind
  let spec: CLITextSpec
  /// The message, for its actions; `nil` for a footer.
  let message: Row?
  let decoration: MessageDecoration

  /// The CLI text `row` shows, when a CLI text cell can draw all of it in `rendering`.
  static func make(_ row: TranscriptTableRow, rendering: OutputRendering) -> Self? {
    guard case .block(let entry) = row.content else { return nil }
    switch entry.block {
    case .footer(_, let text):
      guard !text.isEmpty else { return nil }
      return Self(kind: .footer, spec: .footer(text), message: nil, decoration: MessageDecoration())
    case .segment(.item(.message(let message))):
      guard !message.isStreaming, !message.text.isEmpty, message.attachments.isEmpty,
        message.activity == nil, !message.interrupted,
        let spec = spec(of: message, rendering: rendering)
      else { return nil }
      return Self(
        kind: message.role == .user ? .prompt : .answer, spec: spec, message: message,
        decoration: entry.decorations[message.id] ?? MessageDecoration())
    case .segment:
      return nil
    }
  }

  /// What a settled message draws as: an answer in its rendering, a prompt as typed.
  private static func spec(of message: Row, rendering: OutputRendering) -> CLITextSpec? {
    switch (message.role, rendering) {
    case (.assistant, .plain):
      return .plain(message.text)
    case (.assistant, .styled):
      return MarkdownCache.shared.blocks(for: message.text).isEmpty ? nil : .styled(message.text)
    case (.user, _):
      return UserPrompt.runs(message.text).isEmpty ? nil : .prompt(message.text)
    case (.assistant, .rich), (.tool, _):
      return nil
    }
  }
}
