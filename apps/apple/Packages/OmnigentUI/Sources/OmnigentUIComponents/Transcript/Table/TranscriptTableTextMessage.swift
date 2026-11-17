#if os(macOS)
  import AppKit
  import SwiftUI

  /// A settled chat message a text cell draws in AppKit (``TranscriptTableTextCell``): an answer
  /// or a user's prompt as TextKit text runs, with the blocks only SwiftUI draws (math, a
  /// diagram, an image, a wide table) hosted between them, and nothing beside it that only
  /// SwiftUI draws (attachments, mentions, a collapsed prompt).
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
      guard !split.pieces.isEmpty else { return nil }
      return Self(
        role: role, row: message, decoration: decoration, markdown: markdown, split: split)
    }

    /// One run of text blocks, the gap above it and the inline math its paragraphs typeset.
    struct Run {
      var id: Int
      var gapAbove: CGFloat
      var blocks: [MarkdownBlock]
      var inlineMath: [String]
    }

    /// The text runs, top to bottom.
    var runs: [Run] {
      split.pieces.compactMap { piece in
        guard case .text(let blocks) = piece.content else { return nil }
        return Run(
          id: piece.id, gapAbove: piece.gapAbove, blocks: blocks, inlineMath: piece.inlineMath)
      }
    }
  }

  /// Where a text cell puts a message at a table width: the chat column, as
  /// ``TranscriptColumn`` places it, and the widths the text lays out at.
  struct TranscriptTableTextMetrics: Equatable {
    /// The column's leading edge and width in the cell.
    var columnX: CGFloat
    var columnWidth: CGFloat

    /// The column in a cell `width` wide. A column narrower than its limit snaps down to a
    /// multiple of `snap` (0 for none), so a width dragged a point at a time lays text out only
    /// now and then.
    init(width: CGFloat, layoutWidth: LayoutWidth, maxWidth: CGFloat, snap: CGFloat = 0) {
      let gutter = layoutWidth == .compact ? Theme.Spacing.compactGutter : Theme.Spacing.gutter
      let limit = layoutWidth == .compact ? CGFloat.infinity : maxWidth
      var columnWidth = max(0, min(limit, width - 2 * gutter))
      if snap > 0, columnWidth < limit { columnWidth = (columnWidth / snap).rounded(.down) * snap }
      self.columnWidth = columnWidth
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

  /// Where a text cell puts a message's pieces, from their sizes: the cell lays its views out
  /// by it, and a row far from view is measured by it with no views.
  struct TranscriptTableTextFrames: Equatable {
    /// Each piece's frame, top to bottom.
    var pieces: [CGRect] = []
    /// A user's bubble.
    var bubble: CGRect?
    /// An answer's "Worked for" line.
    var worked: CGRect?
    /// Where the actions' row starts (under the text, or on the "Worked for" line) and ends.
    var actionsTop: CGFloat = 0
    var actionsLineHeight: CGFloat = 0
    var actionsTrailing: CGFloat = 0
    var height: CGFloat = 0

    /// - Parameters:
    ///   - role: An answer's pieces go down the column; a prompt's sit in a bubble that hugs
    ///     them at its trailing edge.
    ///   - gaps: The gap above each piece.
    ///   - sizes: Each piece's size: an answer's as wide as the column, a prompt's as its text.
    ///   - metrics: The column.
    ///   - workedHeight: The "Worked for" line's height, when an answer has one.
    init(
      role: TranscriptTableTextMessage.Role, gaps: [CGFloat], sizes: [CGSize],
      metrics: TranscriptTableTextMetrics, workedHeight: CGFloat?
    ) {
      func gap(_ index: Int) -> CGFloat { gaps.indices.contains(index) ? gaps[index] : 0 }
      actionsTrailing = metrics.columnX + metrics.columnWidth
      switch role {
      case .answer:
        var bottom: CGFloat = 0
        for (index, size) in sizes.enumerated() {
          bottom += gap(index)
          pieces.append(
            CGRect(x: metrics.columnX, y: bottom, width: size.width, height: size.height))
          bottom += size.height
        }
        // The footer follows the stack's spacing; without "Worked for" it takes no height and
        // the actions hang into the gap below the text.
        bottom += Theme.Spacing.small
        if let workedHeight {
          worked = CGRect(
            x: metrics.columnX, y: bottom, width: metrics.columnWidth / 2, height: workedHeight)
          actionsTop = bottom
          actionsLineHeight = workedHeight
          bottom += workedHeight
        } else {
          actionsTop = bottom - Theme.Spacing.small
        }
        height = (bottom + Theme.Spacing.row).rounded(.up)
      case .user:
        let used = sizes.map(\.width).max() ?? 0
        let bubbleWidth = used + 2 * Theme.Spacing.large
        let bubbleX = metrics.columnX + metrics.columnWidth - bubbleWidth
        var bottom = Theme.Spacing.bubbleVertical
        for (index, size) in sizes.enumerated() {
          bottom += gap(index)
          pieces.append(
            CGRect(
              x: bubbleX + Theme.Spacing.large, y: bottom, width: size.width,
              height: size.height))
          bottom += size.height
        }
        let bubbleHeight = bottom + Theme.Spacing.bubbleVertical
        bubble = CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: bubbleHeight)
        actionsTop = bubbleHeight
        height = (bubbleHeight + Theme.Spacing.extraSmall + Theme.Spacing.row).rounded(.up)
      }
    }
  }
#endif
