#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

/// A code block's or table's paragraphs in a document's text: what drawing it in a copy that
/// scrolls sideways needs, when its code doesn't wrap or the table is wider than the column.
nonisolated struct MessageTextBlockSpan: Equatable {
  enum Kind: Equatable {
    case code
    /// A table, as wide as its columns and their gaps.
    case table(width: CGFloat)
  }

  var range: NSRange
  /// The block's leading edge.
  var indent: CGFloat
  var kind: Kind
  /// A code block's header line, whose label stays put while the code scrolls.
  var header: NSRange?

  /// Each code block's and table's span in `text`, by block.
  static func spans(in text: NSAttributedString) -> [Int: Self] {
    var spans: [Int: Self] = [:]
    // The block's third argument is AppKit's stop pointer, unused here.
    unsafe text.enumerateAttribute(
      .messageBlock, in: NSRange(location: 0, length: text.length)
    ) { value, range, _ in
      guard let mark = value as? MessageBlockMark else { return }
      let kind: Kind
      switch mark.role {
      case .codeHeader, .codeLine: kind = .code
      case .tableRow(_, _, let width): kind = .table(width: width)
      case .rule: return
      }
      if let span = spans[mark.block] {
        spans[mark.block]?.range = NSUnionRange(span.range, range)
      } else {
        spans[mark.block] = Self(range: range, indent: mark.indent, kind: kind)
      }
      if case .codeHeader = mark.role { spans[mark.block]?.header = range }
    }
    return spans
  }

  /// Whether the block is drawn by a copy that scrolls: code that doesn't wrap, or a table
  /// wider than the `width` it is laid out at.
  func overflows(width: CGFloat, wraps: Bool) -> Bool {
    switch kind {
    case .code: !wraps
    case .table(let tableWidth): tableWidth > width - indent + 0.5
    }
  }
}

nonisolated extension NSAttributedString {
  /// The paragraphs in `range` as a text of their own that never wraps, moved `indent` to the
  /// left: what a block that scrolls sideways shows.
  func overflowText(in range: NSRange, indent: CGFloat) -> NSAttributedString {
    var range = range
    // The last paragraph's break would add an empty line under it.
    let last = NSRange(location: NSMaxRange(range) - 1, length: 1)
    if range.length > 0, attributedSubstring(from: last).string == "\n" { range.length -= 1 }
    let piece = NSMutableAttributedString(attributedString: attributedSubstring(from: range))
    let whole = NSRange(location: 0, length: piece.length)
    var styles: [(NSRange, NSParagraphStyle)] = []
    // The block's third argument is AppKit's stop pointer, unused here.
    unsafe piece.enumerateAttribute(.paragraphStyle, in: whole) { value, run, _ in
      if let style = value as? NSParagraphStyle { styles.append((run, style)) }
    }
    for (run, style) in styles {
      piece.addAttribute(.paragraphStyle, value: style.unwrapped(shiftedBy: indent), range: run)
    }
    return piece
  }
}

nonisolated extension NSParagraphStyle {
  /// This style on lines that never wrap, its indents and tab stops moved `shift` to the left.
  func unwrapped(shiftedBy shift: CGFloat = 0) -> NSParagraphStyle {
    guard let style = mutableCopy() as? NSMutableParagraphStyle else { return self }
    style.headIndent -= shift
    style.firstLineHeadIndent -= shift
    style.tailIndent = 0
    style.lineBreakMode = .byClipping
    style.tabStops = tabStops.map {
      NSTextTab(textAlignment: $0.alignment, location: $0.location - shift, options: $0.options)
    }
    return style
  }
}

#if os(macOS)
  /// A code block or table drawn again over its own hidden text, in a view that scrolls sideways
  /// as SwiftUI's horizontal scroll view does. A vertical scroll goes on to the transcript.
  final class MessageTextOverflowView: InnerScrollView {
    let textView: MessageTextKitView
    /// How wide the text is past its leading edge.
    private(set) var contentWidth: CGFloat = 0
    private let trailingPadding: CGFloat

    init(
      text: NSAttributedString, palette: MessageTextPalette, trailingPadding: CGFloat,
      minimumWidth: CGFloat = 0
    ) {
      self.trailingPadding = trailingPadding
      textView = MessageTextKitView(usingTextLayoutManager: true)
      super.init(frame: .zero)
      drawsBackground = false
      contentView.drawsBackground = false
      hasVerticalScroller = false
      hasHorizontalScroller = true
      autohidesScrollers = true
      verticalScrollElasticity = .none
      horizontalScrollElasticity = .allowed
      textView.configureForMessage(palette: palette)
      textView.isHorizontallyResizable = false
      if let container = textView.textLayoutManager?.textContainer {
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.size = CGSize(width: 100_000, height: MessageTextPreparedLayout.unlimitedHeight)
      }
      textView.textContentStorage?.textStorage?.setAttributedString(text)
      textView.linkAt = { [weak self] point in self?.link(at: point) }
      documentView = textView
      contentWidth = max(minimumWidth, measuredWidth())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    /// The text laid out, its widest line's trailing edge plus the block's padding.
    private func measuredWidth() -> CGFloat {
      guard let layout = textView.textLayoutManager else { return 0 }
      var width: CGFloat = 0
      _ = layout.enumerateTextLayoutFragments(
        from: layout.documentRange.location, options: [.ensuresLayout]
      ) { fragment in
        for line in fragment.textLineFragments {
          width = max(width, fragment.layoutFragmentFrame.minX + line.typographicBounds.maxX)
        }
        return true
      }
      return (width + trailingPadding).rounded(.up)
    }

    /// Sizes the text to the view's height and at least its width.
    func fit() {
      let size = CGSize(width: max(bounds.width, contentWidth), height: bounds.height)
      if textView.frame.size != size { textView.frame = CGRect(origin: .zero, size: size) }
    }

    override func layout() {
      super.layout()
      fit()
    }

    /// The link at `point`, in the text view's coordinates.
    private func link(at point: CGPoint) -> URL? {
      guard let layout = textView.textLayoutManager, let storage = textView.textContentStorage,
        let text = storage.attributedString
      else { return nil }
      return MessageTextLinkRect.rects(in: layout, links: MessageTextDocument.links(in: text))
        .first { $0.rect.contains(point) }?.url
    }
  }

  extension MessageTextContentView {
    /// Hides the text of `blocks`, which copies that scroll draw instead, and shows the rest's
    /// again. Hidden code doesn't wrap, so its lines keep the copy's height.
    func hideText(of blocks: Set<Int>) {
      guard blocks != hiddenBlocks, let storage = textView.textContentStorage?.textStorage else {
        return
      }
      storage.beginEditing()
      for block in hiddenBlocks.subtracting(blocks) {
        guard let span = spans[block] else { continue }
        // The block's third argument is AppKit's stop pointer, unused here.
        unsafe document.text.enumerateAttributes(in: span.range) { attributes, run, _ in
          storage.setAttributes(attributes, range: run)
        }
      }
      for block in blocks.subtracting(hiddenBlocks) {
        guard let span = spans[block] else { continue }
        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: span.range)
        storage.removeAttribute(.backgroundColor, range: span.range)
        storage.removeAttribute(.link, range: span.range)
        guard case .code = span.kind else { continue }
        var styles: [(NSRange, NSParagraphStyle)] = []
        // The block's third argument is AppKit's stop pointer, unused here.
        unsafe storage.enumerateAttribute(.paragraphStyle, in: span.range) { value, run, _ in
          if let style = value as? NSParagraphStyle { styles.append((run, style)) }
        }
        for (run, style) in styles {
          storage.addAttribute(.paragraphStyle, value: style.unwrapped(), range: run)
        }
        // The header's label stays drawn here, over the code that scrolls.
        if let header = span.header {
          // The block's third argument is AppKit's stop pointer, unused here.
          unsafe document.text.enumerateAttributes(in: header) { attributes, run, _ in
            storage.setAttributes(attributes, range: run)
          }
        }
      }
      storage.endEditing()
      hiddenBlocks = blocks
    }

    /// Places a copy that scrolls over each of `blocks`, where its text landed.
    func placeOverflows(
      _ blocks: Set<Int>, collector: MessageTextLayerCollector, width: CGFloat
    ) {
      for (block, view) in overflows where !blocks.contains(block) {
        view.removeFromSuperview()
        overflows[block] = nil
      }
      for block in blocks.sorted() {
        guard let span = spans[block], let frame = collector.frame(of: block) else { continue }
        let view = overflows[block] ?? makeOverflow(span)
        overflows[block] = view
        view.frame = CGRect(
          x: span.indent, y: frame.minY + document.topInset, width: max(0, width - span.indent),
          height: frame.height)
        view.fit()
      }
    }

    private func makeOverflow(_ span: MessageTextBlockSpan) -> MessageTextOverflowView {
      let text = NSMutableAttributedString(
        attributedString: document.text.overflowText(in: span.range, indent: span.indent))
      // The label stays put in the text below; the copy only keeps its line's room.
      if let header = span.header {
        text.addAttribute(
          .foregroundColor, value: NSColor.clear, range: NSRange(location: 0, length: header.length)
        )
      }
      let view: MessageTextOverflowView
      switch span.kind {
      case .code:
        view = MessageTextOverflowView(
          text: text, palette: document.palette, trailingPadding: MessageTextBuilder.codePadding)
      case .table(let width):
        view = MessageTextOverflowView(
          text: text, palette: document.palette, trailingPadding: 0, minimumWidth: width)
      }
      view.textView.delegate = self
      addSubview(view, positioned: .above, relativeTo: textView)
      return view
    }
  }
#endif
