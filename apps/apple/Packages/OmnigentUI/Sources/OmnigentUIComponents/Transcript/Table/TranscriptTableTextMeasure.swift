#if os(macOS)
  import AppKit

  extension TranscriptTableTextCell {
    /// `message`'s height at `width`, as a text cell shows it, from its runs' laid-out sizes
    /// and its hosted parts' sizes: a row far from view is measured with no text view. A run
    /// laid out nowhere yet lays out here, still with no view, and leaves its layout to the
    /// first view that shows it.
    /// - Parameters:
    ///   - message: The message.
    ///   - style: The style text cells draw in.
    ///   - width: The table's width.
    ///   - blockHeight: A block's height at a width, for blocks only SwiftUI draws.
    ///   - accessorySize: A part beside the text's size, offered a width, for message
    ///     `rowID`; `nil` measures each in a view of its own.
    /// - Returns: The height; `nil` before the style is known.
    static func measuredHeight(
      of message: TranscriptTableTextMessage, style: TranscriptTableTextStyle, width: CGFloat,
      blockHeight: (MarkdownBlock, Int, CGFloat) -> CGFloat,
      accessorySize: ((TranscriptTableAccessory, String, CGFloat) -> CGSize)? = nil
    ) -> CGFloat? {
      guard let textStyle = style.style else { return nil }
      let metrics = style.metrics(width: width)
      let isAnswer = message.role == .answer
      let textWidth = message.textWidth(metrics, layoutWidth: style.layoutWidth)
      let measureAccessory =
        accessorySize ?? { accessory, rowID, width in
          let view = TranscriptTableAccessoryView.make(environment: style.environment)
          view.show(accessory, rowID: rowID, width: width)
          return view.idealSize
        }
      let sizes = message.entries.map { entry -> CGSize in
        switch entry {
        case .piece(let piece):
          switch piece.content {
          case .text(let blocks):
            let document = MessageTextBlocksView.document(
              source: MessageTextSource(text: message.markdown, piece: piece.id),
              blocks: blocks, linked: [], math: typesetMath(piece.inlineMath, ramp: textStyle.ramp),
              style: textStyle, links: nil)
            let size = runSize(document, width: textWidth)
            // A prompt's bubble hugs its text, unless a block in it spans the column.
            let hugs = !isAnswer && !document.hasWideBlocks
            return CGSize(
              width: hugs ? min(textWidth, size.usedWidth) : textWidth, height: size.height)
          case .block(let block):
            return CGSize(width: textWidth, height: blockHeight(block, piece.id, textWidth))
          }
        case .accessory(let accessory):
          let size = measureAccessory(accessory, message.row.id, textWidth)
          return CGSize(
            width: isAnswer ? textWidth : min(textWidth, size.width), height: size.height)
        case .empty:
          return .zero
        }
      }
      let frames = TranscriptTableTextFrames(
        role: message.role, gaps: message.gaps, sizes: sizes, metrics: metrics,
        workedHeight: isAnswer ? message.decoration.workedFor.map { _ in workedLabelHeight } : nil,
        belowBubbleSize: message.belowBubble.map {
          measureAccessory($0, message.row.id, textWidth)
        },
        hasAvatar: message.avatar != nil)
      return frames.height
    }

    /// A piece's inline math typeset at `ramp`'s size so far, by TeX: from the renderer's
    /// cache, kept where the prewarm reads it too.
    static func typesetMath(_ math: [String], ramp: TypeRamp) -> [String: RenderedRichBlock] {
      var typeset: [String: RenderedRichBlock] = [:]
      for tex in math {
        let request = mathRequest(tex, ramp: ramp)
        if let image = RichBlockRenderer.shared.cached(request) {
          MessageTextTypesetMath.shared.store(image, for: request)
          typeset[tex] = image
        } else if let image = MessageTextTypesetMath.shared.image(for: request) {
          typeset[tex] = image
        }
      }
      return typeset
    }

    /// Inline math at `ramp`'s size, as ``MessageTextMarkdownView`` asks for it.
    nonisolated static func mathRequest(_ tex: String, ramp: TypeRamp) -> RichBlockRequest {
      RichBlockRequest(kind: .math(display: false, size: ramp.body), source: tex)
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
