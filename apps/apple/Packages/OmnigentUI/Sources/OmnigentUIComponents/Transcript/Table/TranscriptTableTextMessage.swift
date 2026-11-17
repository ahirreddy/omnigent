#if os(macOS)
  import AppKit
  import SwiftUI

  /// A settled chat message a text cell draws in AppKit (``TranscriptTableTextCell``): an answer
  /// or a user's prompt as TextKit text runs, with the blocks only SwiftUI draws (math, a
  /// diagram, an image, a wide table) hosted between them, and the parts beside the text that
  /// SwiftUI draws (attachments, mentions, a long prompt's toggle) hosted where the message row
  /// stacks them.
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
    /// What the message stacks, top to bottom, as its row's stacks do: the parts beside the
    /// text that SwiftUI draws, and the text's pieces.
    let entries: [Entry]

    /// One thing the message stacks.
    enum Entry {
      /// A part beside the text that SwiftUI draws, hosted.
      case accessory(TranscriptTableAccessory)
      /// A piece of the text: a run of text blocks, or a block SwiftUI draws.
      case piece(MessageTextPiece)
      /// A prompt's body that shows nothing (its text was only upload markers): it takes no
      /// height, and its stack still spaces it.
      case empty
    }

    /// Whether a prompt over ``UserPrompt/collapseThreshold`` characters shows whole.
    enum PromptFold {
      case collapsed
      case expanded
    }

    /// A long prompt's fold; `nil` for any other message.
    var promptFold: PromptFold?

    /// The message row `row` shows, when a text cell can draw all of it at `ramp`.
    /// - Parameters:
    ///   - row: The row.
    ///   - ramp: The reading ramp the text splits at.
    ///   - expandsPrompt: A long prompt shows whole; it starts collapsed.
    /// - Returns: The message, or `nil` for a row that stays SwiftUI's.
    static func make(_ row: TranscriptTableRow, ramp: TypeRamp, expandsPrompt: Bool = false)
      -> Self?
    {
      guard case .segment(let entry) = row.content,
        case .item(.message(let message)) =
          entry.segment
      else { return nil }
      guard !message.isStreaming, message.activity == nil, !message.interrupted else {
        return nil
      }
      let decoration = entry.decorations[message.id] ?? MessageDecoration()
      let attachments: [Entry] =
        message.attachments.isEmpty ? [] : [.accessory(.attachments(message.attachments))]
      let made: Self
      switch message.role {
      case .assistant:
        guard !message.text.isEmpty else { return nil }
        let text = Self.pieces(of: message.text, ramp: ramp)
        made = Self(
          role: .answer, row: message, decoration: decoration, markdown: message.text,
          split: MessageTextSplits.shared.split(message.text, ramp: ramp),
          entries: (text.isEmpty ? [.empty] : text) + attachments)
      case .user:
        guard !decoration.showsAvatar else { return nil }
        made = prompt(
          message, decoration: decoration, leading: attachments, ramp: ramp,
          expands: expandsPrompt)
      case .tool:
        return nil
      }
      // A message that shows nothing at all stays SwiftUI's.
      guard made.entries.contains(where: { if case .empty = $0 { false } else { true } }) else {
        return nil
      }
      return made
    }

    /// A user's prompt: `leading` first in its bubble, then its body as ``UserPromptBody``
    /// stacks it: its mentions' chips, its text and a long prompt's toggle. A prompt of
    /// attachments alone has no body.
    private static func prompt(
      _ message: Row, decoration: MessageDecoration, leading: [Entry], ramp: TypeRamp,
      expands: Bool
    ) -> Self {
      let prompt = UserPrompt.parse(message.text)
      var markdown = prompt.text
      var fold: PromptFold?
      var toggle: [Entry] = []
      // A long prompt shows its start and "Show full prompt" until the reader expands it.
      if let collapsed = UserPrompt.collapsed(prompt.text) {
        fold = expands ? .expanded : .collapsed
        if !expands { markdown = collapsed + "\u{2026}" }
        let title = expands ? UserPrompt.collapseTitle : UserPrompt.expandTitle(prompt.text)
        toggle = [.accessory(.promptToggle(title: title, collapses: expands))]
      }
      let mentions: [Entry] =
        prompt.mentions.isEmpty ? [] : [.accessory(.mentions(prompt.mentions))]
      var body = mentions + pieces(of: markdown, ramp: ramp) + toggle
      if body.isEmpty, !message.text.isEmpty { body = [.empty] }
      return Self(
        role: .user, row: message, decoration: decoration, markdown: markdown,
        split: MessageTextSplits.shared.split(markdown, ramp: ramp), entries: leading + body,
        promptFold: fold)
    }

    /// The pieces `markdown` splits into at `ramp`.
    private static func pieces(of markdown: String, ramp: TypeRamp) -> [Entry] {
      guard !markdown.isEmpty else { return [] }
      return MessageTextSplits.shared.split(markdown, ramp: ramp).pieces.map(Entry.piece)
    }

    /// The parts beside the text, top to bottom.
    var accessories: [TranscriptTableAccessory] {
      entries.compactMap {
        if case .accessory(let accessory) = $0 { return accessory }
        return nil
      }
    }

    /// The gap above each entry, as the row's stacks space them: a small gap between any two,
    /// and a piece of text its own gap after another piece.
    var gaps: [CGFloat] {
      var gaps: [CGFloat] = []
      var afterPiece = false
      for entry in entries {
        switch entry {
        case .piece(let piece):
          gaps.append(piece.gapAbove + (gaps.isEmpty || afterPiece ? 0 : Theme.Spacing.small))
          afterPiece = true
        case .accessory, .empty:
          gaps.append(gaps.isEmpty ? 0 : Theme.Spacing.small)
          afterPiece = false
        }
      }
      return gaps
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

  /// Where a text cell puts a message's entries, from their sizes: the cell lays its views out
  /// by it, and a row far from view is measured by it with no views.
  struct TranscriptTableTextFrames: Equatable {
    /// Each entry's frame, top to bottom (``TranscriptTableTextMessage/entries``).
    var entries: [CGRect] = []
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
    ///   - role: An answer's entries go down the column; a prompt's sit in a bubble that hugs
    ///     them at its trailing edge.
    ///   - gaps: The gap above each entry.
    ///   - sizes: Each entry's size: an answer's as wide as the column, a prompt's as its own.
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
          entries.append(
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
          entries.append(
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
