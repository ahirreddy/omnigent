#if os(macOS)
  import AppKit
  import SwiftUI

  /// A settled chat message a text cell draws in AppKit (``TranscriptTableTextCell``): an answer
  /// or a user's prompt as TextKit text runs, with the blocks only SwiftUI draws (math, a
  /// diagram, an image, a wide table) hosted between them, and nothing beside it that only
  /// SwiftUI draws (attachments, mentions, a collapsed prompt, linked paths).
  struct TranscriptTableTextMessage {
    enum Role {
      case user
      case answer
    }

    let role: Role
    let row: Row
    let decoration: MessageDecoration
    /// The markdown shown: the answer's text, or the prompt's without its mentions.
    let markdown: String
    let split: MessageTextSplit

    /// The message row `row` shows, when a text cell can draw all of it at `ramp`.
    static func make(_ row: TranscriptTableRow, ramp: TypeRamp) -> Self? {
      guard case .segment(let entry) = row.content,
        case .item(.message(let message)) =
          entry.segment
      else { return nil }
      guard !message.isStreaming, !message.text.isEmpty, message.attachments.isEmpty,
        message.activity == nil, !message.interrupted
      else { return nil }
      let decoration = entry.decorations[message.id] ?? MessageDecoration()
      let role: Role
      let markdown: String
      switch message.role {
      case .assistant:
        role = .answer
        markdown = message.text
      case .user:
        let prompt = UserPrompt.parse(message.text)
        guard !decoration.showsAvatar, prompt.mentions.isEmpty, !prompt.text.isEmpty,
          UserPrompt.collapsed(prompt.text) == nil
        else { return nil }
        role = .user
        markdown = prompt.text
      case .tool:
        return nil
      }
      let split = MessageTextSplits.shared.split(markdown, ramp: ramp)
      guard split.cited.isEmpty, !split.pieces.isEmpty else { return nil }
      return Self(
        role: role, row: message, decoration: decoration, markdown: markdown, split: split)
    }

    /// One run of text blocks and the gap above it.
    struct Run {
      var id: Int
      var gapAbove: CGFloat
      var blocks: [MarkdownBlock]
    }

    /// The text runs, top to bottom.
    var runs: [Run] {
      split.pieces.compactMap { piece in
        guard case .text(let blocks) = piece.content else { return nil }
        return Run(id: piece.id, gapAbove: piece.gapAbove, blocks: blocks)
      }
    }
  }

  /// Where a text cell puts a message at a table width: the chat column, as
  /// ``TranscriptColumn`` places it, and the widths the text lays out at.
  struct TranscriptTableTextMetrics: Equatable {
    /// The column's leading edge and width in the cell.
    var columnX: CGFloat
    var columnWidth: CGFloat

    init(width: CGFloat, layoutWidth: LayoutWidth, maxWidth: CGFloat) {
      let gutter = layoutWidth == .compact ? Theme.Spacing.compactGutter : Theme.Spacing.gutter
      let limit = layoutWidth == .compact ? CGFloat.infinity : maxWidth
      columnWidth = max(0, min(limit, width - 2 * gutter))
      columnX = ((width - columnWidth - 2 * gutter) / 2).rounded(.down) + gutter
    }

    /// The space a bubble keeps on its leading side, as the stack's spacer does.
    static func bubbleLead(_ layoutWidth: LayoutWidth) -> CGFloat {
      (layoutWidth == .compact ? Theme.Spacing.extraLarge : Theme.Spacing.section)
        + Theme.Spacing.small
    }

    /// The width a user's prompt may lay out at inside its bubble.
    func promptWidth(_ layoutWidth: LayoutWidth) -> CGFloat {
      let bubble = min(Theme.userMessageWidth, columnWidth - Self.bubbleLead(layoutWidth))
      return max(0, bubble - 2 * Theme.Spacing.large)
    }
  }
#endif
