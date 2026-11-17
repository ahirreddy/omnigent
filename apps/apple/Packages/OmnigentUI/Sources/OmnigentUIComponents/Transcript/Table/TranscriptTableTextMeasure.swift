#if os(macOS)
  import AppKit

  extension TranscriptTableTextCell {
    /// `message`'s height at `width`, as a text cell shows it, from its runs' laid-out sizes
    /// and its blocks' heights: a row far from view is measured with no text view. A run laid
    /// out nowhere yet lays out here, still with no view, and leaves its layout to the first
    /// view that shows it.
    /// - Parameters:
    ///   - message: The message.
    ///   - style: The style text cells draw in.
    ///   - width: The table's width.
    ///   - blockHeight: A block's height at a width, for blocks only SwiftUI draws.
    /// - Returns: The height; `nil` before the style is known.
    static func measuredHeight(
      of message: TranscriptTableTextMessage, style: TranscriptTableTextStyle, width: CGFloat,
      blockHeight: (MarkdownBlock, Int, CGFloat) -> CGFloat
    ) -> CGFloat? {
      guard let textStyle = style.style else { return nil }
      let metrics = TranscriptTableTextMetrics(
        width: width, layoutWidth: style.layoutWidth, maxWidth: style.maxWidth)
      let isAnswer = message.role == .answer
      let textWidth = isAnswer ? metrics.columnWidth : metrics.promptWidth(style.layoutWidth)
      var sizes: [CGSize] = []
      for piece in message.split.pieces {
        switch piece.content {
        case .text(let blocks):
          let document = MessageTextBlocksView.document(
            source: MessageTextSource(text: message.markdown, piece: piece.id), blocks: blocks,
            linked: [], style: textStyle, links: nil)
          let size = runSize(document, width: textWidth)
          // A prompt's bubble hugs its text, unless a block in it spans the column.
          let hugs = !isAnswer && !document.hasWideBlocks
          sizes.append(
            CGSize(width: hugs ? min(textWidth, size.usedWidth) : textWidth, height: size.height))
        case .block(let block):
          sizes.append(CGSize(width: textWidth, height: blockHeight(block, piece.id, textWidth)))
        }
      }
      let frames = TranscriptTableTextFrames(
        role: message.role, gaps: message.split.pieces.map(\.gapAbove), sizes: sizes,
        metrics: metrics,
        workedHeight: isAnswer ? message.decoration.workedFor.map { _ in workedLabelHeight } : nil)
      return frames.height
    }

    /// `document`'s size `width` wide: as laid out ahead or drawn, else laid out now.
    static func runSize(_ document: MessageTextDocument, width: CGFloat) -> MessageTextSize {
      if let size = MessageTextSizes.shared.size(document: document.serial, width: width) {
        return size
      }
      let layout = MessageTextPreparedLayout(text: document.text, width: width)
      let size = MessageTextSize.measure(layout.manager, width: width, topInset: document.topInset)
      MessageTextSizes.shared.store(size, document: document.serial, width: width)
      document.offer(layout)
      return size
    }
  }
#endif
