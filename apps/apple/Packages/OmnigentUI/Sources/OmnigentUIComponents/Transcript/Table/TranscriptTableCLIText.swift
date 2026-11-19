import Foundation

/// A settled CLI block a CLI text cell draws as TextKit text (``TranscriptTableCLICell``): an
/// answer in Plain or Styled rendering, a user's prompt, the line under a settled turn, or a
/// turn's tool work. A block holding anything only SwiftUI draws (attachments, most
/// activities, an interruption, a sub-agent) stays hosted, as does Rich rendering.
nonisolated struct TranscriptTableCLIText: Sendable {
  enum Kind: Sendable {
    case answer
    case prompt
    case footer
    case work
  }

  let kind: Kind
  let spec: CLITextSpec
  /// The message, for its actions; `nil` for a footer and tool work.
  var message: Row?
  var decoration = MessageDecoration()
  /// Tool work's regions' targets, and the Worked group the reader may collapse.
  var work: CLIWork?
  var group: String?

  /// The CLI text `row` shows, when a CLI text cell can draw all of it in `rendering`.
  @MainActor
  static func make(
    _ row: TranscriptTableRow, rendering: OutputRendering, palette: CLIPalette,
    expansions: CLIWorkExpansions
  ) -> Self? {
    guard rendering != .rich, case .block(let entry) = row.content else { return nil }
    switch entry.block {
    case .footer(_, let text):
      guard !text.isEmpty else { return nil }
      return Self(kind: .footer, spec: .footer(text))
    case .segment(.item(.message(let message))):
      // A message from another session folds, which the hosted band draws.
      guard !message.isStreaming, !message.text.isEmpty, message.attachments.isEmpty,
        message.activity == nil, !message.interrupted, message.originSessionId == nil,
        let spec = spec(of: message, rendering: rendering)
      else { return nil }
      return Self(
        kind: message.role == .user ? .prompt : .answer, spec: spec, message: message,
        decoration: entry.decorations[message.id] ?? MessageDecoration())
    case .segment(.worked(let id, _, let items, let isLive)):
      guard !isLive else { return nil }
      return work(items, group: id, palette: palette, expansions: expansions)
    case .segment(.item(let item)):
      return work([item], group: nil, palette: palette, expansions: expansions)
    }
  }

  @MainActor
  private static func work(
    _ items: [TranscriptItem], group: String?, palette: CLIPalette,
    expansions: CLIWorkExpansions
  ) -> Self? {
    guard let work = CLIWork.make(items, group: group, palette: palette, expansions: expansions)
    else { return nil }
    return Self(kind: .work, spec: .work(work.spec), work: work, group: group)
  }

  /// What a settled message draws as: an answer in its rendering, a prompt as typed.
  private static func spec(of message: Row, rendering: OutputRendering) -> CLITextSpec? {
    switch (message.role, rendering) {
    case (.assistant, .plain):
      return .plain(message.text)
    case (.assistant, .styled):
      return MarkdownCache.shared.blocks(for: message.text).isEmpty ? nil : .styled(message.text)
    case (.user, _):
      let source = UserPrompt.source(message)
      return UserPrompt.runs(source).isEmpty ? nil : .prompt(source)
    case (.assistant, .rich), (.tool, _):
      return nil
    }
  }
}
