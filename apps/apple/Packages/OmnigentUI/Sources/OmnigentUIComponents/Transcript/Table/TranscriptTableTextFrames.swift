#if os(macOS)
  import AppKit

  /// Where a text cell puts a message's entries, from their sizes: the cell lays its views out
  /// by it, and a row far from view is measured by it with no views.
  struct TranscriptTableTextFrames: Equatable {
    /// Each entry's frame, top to bottom (``TranscriptTableTextMessage/entries``).
    var entries: [CGRect] = []
    /// A user's bubble.
    var bubble: CGRect?
    /// What shows under a prompt's bubble, at the column's trailing edge.
    var belowBubble: CGRect?
    /// A shared session author's avatar, beside their prompt's bubble.
    var avatar: CGRect?
    /// An answer's "Worked for" line.
    var worked: CGRect?
    /// Where the actions' row starts (under the text, or on the "Worked for" line) and ends.
    var actionsTop: CGFloat = 0
    var actionsLineHeight: CGFloat = 0
    var actionsTrailing: CGFloat = 0
    /// The message's own frame, as its SwiftUI row lays it out in the column: what keyboard
    /// focus rings and a linked message's flash tints.
    var content: CGRect = .zero
    var height: CGFloat = 0

    /// - Parameters:
    ///   - role: An answer's entries go down the column; a prompt's sit in a bubble that hugs
    ///     them at its trailing edge.
    ///   - gaps: The gap above each entry.
    ///   - sizes: Each entry's size: an answer's as wide as the column, a prompt's as its own.
    ///   - metrics: The column.
    ///   - workedHeight: The "Worked for" line's height, when an answer has one.
    ///   - belowBubbleSize: The size of what shows under a prompt's bubble, if anything does.
    ///   - hasAvatar: A prompt shows its author's avatar beside its bubble.
    init(
      role: TranscriptTableTextMessage.Role, gaps: [CGFloat], sizes: [CGSize],
      metrics: TranscriptTableTextMetrics, workedHeight: CGFloat?,
      belowBubbleSize: CGSize? = nil, hasAvatar: Bool = false
    ) {
      actionsTrailing = metrics.columnX + metrics.columnWidth
      switch role {
      case .answer:
        stackAnswer(gaps: gaps, sizes: sizes, metrics: metrics, workedHeight: workedHeight)
      case .user:
        if hasAvatar {
          let size = TranscriptTableAvatarView.size
          avatar = CGRect(x: actionsTrailing - size, y: 0, width: size, height: size)
        }
        stackPrompt(gaps: gaps, sizes: sizes, metrics: metrics, belowBubbleSize: belowBubbleSize)
      }
    }

    private static func gap(_ gaps: [CGFloat], _ index: Int) -> CGFloat {
      gaps.indices.contains(index) ? gaps[index] : 0
    }

    /// An answer's entries down the column, then its footer.
    private mutating func stackAnswer(
      gaps: [CGFloat], sizes: [CGSize], metrics: TranscriptTableTextMetrics,
      workedHeight: CGFloat?
    ) {
      var bottom: CGFloat = 0
      for (index, size) in sizes.enumerated() {
        bottom += Self.gap(gaps, index)
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
      content = CGRect(x: metrics.columnX, y: 0, width: metrics.columnWidth, height: bottom)
      height = (bottom + Theme.Spacing.row).rounded(.up)
    }

    /// A prompt's entries in a bubble that hugs them at the column's trailing edge (before the
    /// avatar, if it has one), then what shows under them.
    private mutating func stackPrompt(
      gaps: [CGFloat], sizes: [CGSize], metrics: TranscriptTableTextMetrics,
      belowBubbleSize: CGSize?
    ) {
      let used = sizes.map(\.width).max() ?? 0
      let bubbleWidth = used + 2 * Theme.Spacing.large
      let trailing = actionsTrailing - (avatar == nil ? 0 : TranscriptTableTextMetrics.avatarLane)
      let bubbleX = trailing - bubbleWidth
      var bottom = Theme.Spacing.bubbleVertical
      for (index, size) in sizes.enumerated() {
        bottom += Self.gap(gaps, index)
        entries.append(
          CGRect(
            x: bubbleX + Theme.Spacing.large, y: bottom, width: size.width, height: size.height))
        bottom += size.height
      }
      let bubbleHeight = bottom + Theme.Spacing.bubbleVertical
      bubble = CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: bubbleHeight)
      // The row's stack spaces what follows the bubble and avatar at its trailing edge: a line,
      // then the actions.
      bottom = max(bubbleHeight, avatar?.maxY ?? 0)
      if let belowBubbleSize {
        bottom += Theme.Spacing.extraSmall
        belowBubble = CGRect(
          x: actionsTrailing - belowBubbleSize.width, y: bottom, width: belowBubbleSize.width,
          height: belowBubbleSize.height)
        bottom += belowBubbleSize.height
      }
      actionsTop = bottom
      // The row's stack ends with the actions' row, which takes no height.
      content = CGRect(
        x: metrics.columnX, y: 0, width: metrics.columnWidth,
        height: bottom + Theme.Spacing.extraSmall)
      height = (bottom + Theme.Spacing.extraSmall + Theme.Spacing.row).rounded(.up)
    }
  }
#endif
