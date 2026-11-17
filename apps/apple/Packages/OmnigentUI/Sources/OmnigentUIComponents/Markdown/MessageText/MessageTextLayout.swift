#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

// How a laid-out run is read for the layers drawn with it: shared by the Mac's text views and
// the drawn-ahead (raster) runs, on and off the main actor.

/// The design system's metrics the builder sets text with, as constants it can read off the
/// main actor; a test checks they match `Theme`'s.
nonisolated enum MessageTextMetrics {
  /// `Theme.Control.target`.
  #if os(macOS)
    static let controlTarget: CGFloat = 28
  #else
    static let controlTarget: CGFloat = 44
  #endif
  /// `Theme.Spacing`.
  static let extraSmall: CGFloat = 4
  static let small: CGFloat = 8
  static let medium: CGFloat = 12
  static let large: CGFloat = 16
  static let extraLarge: CGFloat = 24
  /// `MarkdownTableView.rowPadding`.
  static let tableRowPadding: CGFloat = 10
  /// A code block's header band: a control's height and the padding around it, then a rule.
  static let codeHeaderHeight = controlTarget + 2 * extraSmall
  /// Inside a code block, around its code.
  static let codePadding = large
  /// Under a table, its controls' row.
  static let tableControlsHeight = controlTarget
  static let quoteBarWidth: CGFloat = 3
}

/// What the layers behind the text draw.
nonisolated enum MessageTextShape: Equatable {
  /// A code block: its rounded surface, header band and the rule under the header.
  case codeBlock(CGRect)
  /// A rule, a table's rule or a quote's bar.
  case fill(CGRect, Fill)
  /// Typeset inline math, over its clear attachment.
  case image(CGImage, CGRect)

  enum Fill: Equatable, Sendable {
    case separator
    case border
    case hover
    case quoteBar
  }
}

/// Reads where a laid-out document's marked paragraphs landed: the code blocks, rules, table
/// rules, quote bars and typeset math to draw, and where each control goes.
nonisolated struct MessageTextLayerCollector {
  let width: CGFloat
  private var codeBlocks: [Int: CGRect] = [:]
  /// Each quote's bar so far.
  private var quoteBars: [Int: QuoteSpan] = [:]

  /// A quote bar's leading edge and how far down it reaches.
  private struct QuoteSpan {
    var leading: CGFloat
    var top: CGFloat
    var bottom: CGFloat
  }
  private var fills: [MessageTextShape] = []
  private var images: [MessageTextShape] = []
  private(set) var chromeFrames: [Int: CGRect] = [:]
  /// Each table's rows, from the header's line to under the last row.
  private var tables: [Int: CGRect] = [:]
  /// The lowest point any layer or control reaches.
  private(set) var bottom: CGFloat = 0

  init(width: CGFloat) {
    self.width = width
  }

  var shapes: [MessageTextShape] {
    codeBlocks.keys.sorted().compactMap { codeBlocks[$0].map(MessageTextShape.codeBlock) }
      + quoteBars.keys.sorted().compactMap { id in
        quoteBars[id].map { bar in
          .fill(
            CGRect(
              x: bar.leading, y: bar.top, width: MessageTextMetrics.quoteBarWidth,
              height: bar.bottom - bar.top), .quoteBar)
        }
      } + fills + images
  }

  mutating func add(_ fragment: NSTextLayoutFragment) {
    guard let paragraph = fragment.textElement as? NSTextParagraph,
      let first = fragment.textLineFragments.first, let last = fragment.textLineFragments.last
    else { return }
    let string = paragraph.attributedString
    guard string.length > 0 else { return }
    // Nothing reads the effective ranges back.
    let style =
      unsafe string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    let mark =
      unsafe string.attribute(.messageBlock, at: 0, effectiveRange: nil) as? MessageBlockMark
    let quotes =
      unsafe string.attribute(.messageQuotes, at: 0, effectiveRange: nil) as? MessageQuoteMarks
    let origin = fragment.layoutFragmentFrame.origin
    let top = origin.y + first.typographicBounds.minY
    // A line's spacing under its glyphs is part of its height, as in SwiftUI; TextKit leaves
    // the last line's out.
    let lineHeight = style.map { $0.minimumLineHeight + $0.lineSpacing } ?? 0
    let lastTop = origin.y + last.typographicBounds.minY
    var bottom = max(
      origin.y + last.typographicBounds.maxY + (style?.lineSpacing ?? 0), lastTop + lineHeight)
    self.bottom = max(self.bottom, bottom)
    addMath(in: fragment, string: string)
    guard mark != nil || quotes != nil else { return }
    if let mark { bottom = place(mark, top: top, bottom: bottom) }
    for bar in quotes?.bars ?? [] {
      let start = quoteBars[bar.id]?.top ?? top
      quoteBars[bar.id] = QuoteSpan(leading: bar.leading, top: start, bottom: bottom)
    }
    self.bottom = max(self.bottom, bottom)
  }

  /// Where a code block or table landed: a code block from its header's top to its bottom, a
  /// table from its header row's line to under its last row.
  func frame(of block: Int) -> CGRect? {
    codeBlocks[block] ?? tables[block]
  }

  /// Each typeset math image, its baseline on its line's.
  private mutating func addMath(in fragment: NSTextLayoutFragment, string: NSAttributedString) {
    let origin = fragment.layoutFragmentFrame.origin
    let lines = fragment.textLineFragments
    var found: [MessageTextShape] = []
    // The block's third argument is AppKit's stop pointer, unused here.
    unsafe string.enumerateAttribute(
      .messageMath, in: NSRange(location: 0, length: string.length)
    ) { value, range, _ in
      guard let math = value as? MessageMathMark,
        let line = lines.first(where: { NSLocationInRange(range.location, $0.characterRange) })
      else { return }
      let bounds = line.typographicBounds
      let baseline = origin.y + bounds.minY + line.glyphOrigin.y
      let leading = origin.x + bounds.minX + line.locationForCharacter(at: range.location).x
      found.append(
        .image(
          math.image,
          CGRect(
            x: leading, y: baseline - math.baseline, width: math.size.width,
            height: math.size.height)))
    }
    images += found
  }

  /// Records a marked paragraph's layer and control; returns where its block ends below it.
  private mutating func place(_ mark: MessageBlockMark, top: CGFloat, bottom: CGFloat)
    -> CGFloat
  {
    let span = width - mark.indent
    switch mark.role {
    case .codeHeader:
      let header = CGRect(
        x: mark.indent, y: top, width: span, height: MessageTextMetrics.codeHeaderHeight)
      codeBlocks[mark.block] = CGRect(x: mark.indent, y: top, width: span, height: bottom - top)
      chromeFrames[mark.block] = header
      return bottom
    case .codeLine(let isLast):
      let end = bottom + (isLast ? MessageTextMetrics.codePadding : 0)
      if let block = codeBlocks[mark.block] {
        codeBlocks[mark.block] = CGRect(
          x: block.minX, y: block.minY, width: block.width, height: end - block.minY)
      }
      return end
    case .rule:
      let middle = ((top + bottom) / 2).rounded(.down)
      fills.append(.fill(CGRect(x: mark.indent, y: middle, width: span, height: 1), .separator))
      return bottom
    case .tableRow(let isHeader, let isLast, let tableWidth):
      let below = bottom + MessageTextMetrics.tableRowPadding
      let start = isHeader ? top : tables[mark.block]?.minY ?? top
      tables[mark.block] = CGRect(x: mark.indent, y: start, width: span, height: below - start)
      guard !isLast else {
        let controls = CGRect(
          x: mark.indent, y: below, width: min(span, max(tableWidth, 120)),
          height: MessageTextMetrics.tableControlsHeight)
        chromeFrames[mark.block] = controls
        return controls.maxY
      }
      fills.append(
        .fill(
          CGRect(x: mark.indent, y: below, width: min(span, tableWidth), height: 1),
          isHeader ? .border : .hover))
      return below + 1
    }
  }
}
