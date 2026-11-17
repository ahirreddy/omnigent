import CoreText
import Foundation

#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

// MARK: Styled

nonisolated extension CLITextBuilder {
  /// A stack of blocks, as ``CLIBlocks`` spaces them.
  mutating func blocks(
    _ blocks: [MarkdownBlock], in context: Context, isListItem: Bool = false
  ) -> CLITextNode {
    var items: [CLITextStackItem] = []
    for (index, block) in blocks.enumerated() {
      var gap: CGFloat = 0
      if index > 0 {
        if isListItem, case .list = block {
          gap = metrics.lineSpacing
        } else {
          gap = context.onLineGrid ? metrics.blankLine : metrics.line
        }
      }
      items.append(CLITextStackItem(gap: gap, node: self.block(block, in: context)))
    }
    // An empty item still shows its marker, on a line of its own.
    if items.isEmpty, isListItem {
      return unit(NSAttributedString(), indent: context.indent)
    }
    return items.count == 1 ? items[0].node : .stack(items)
  }

  private mutating func block(_ block: MarkdownBlock, in context: Context) -> CLITextNode {
    let character = metrics.character
    switch block {
    case .paragraph(let text):
      return unit(
        inline(text.keepingSoftBreaks, base: InlineBase(color: context.color)),
        indent: context.indent)
    case .heading(let level, let text):
      return heading(level: level, text: text, in: context)
    case .code(let language, let code):
      return unit(
        highlighted(code, language: language, color: context.color), indent: context.indent)
    case .quote(let inner):
      var quoted = context
      quoted.indent += character * 2
      quoted.color = palette.quote
      quoted.onLineGrid = true
      quoted.nestedListIndent = 0
      return .quote(blocks(inner, in: quoted), markerX: context.indent, color: palette.quote)
    case .list(let ordered, let start, let items):
      return list(ordered: ordered, start: start, items: items, in: context)
    case .table(let table):
      return self.table(table, in: context)
    case .rule:
      return unit(plain("\u{2014}\u{2014}\u{2014}", color: context.color), indent: context.indent)
    case .html(let raw):
      return unit(plain(raw, color: context.color), indent: context.indent)
    case .image(let source, let alt):
      return unit(
        plain("[Image: \(alt.isEmpty ? source : alt)]", color: palette.dim),
        indent: context.indent)
    case .math(let tex):
      return unit(
        plain(MathText.unicode(tex), color: palette.code), indent: context.indent + character * 2)
    }
  }

  /// `#` markers kept: bold and underlined, bold, bold italic, then italic alone from the fourth
  /// level down.
  private mutating func heading(level: Int, text: AttributedString, in context: Context)
    -> CLITextNode
  {
    let minor = level >= 3
    let base = InlineBase(
      color: minor ? palette.strong : palette.heading,
      weight: level <= 3 ? .semibold : .regular, italic: minor, underline: level == 1)
    let content = NSMutableAttributedString(
      string: String(repeating: "#", count: max(1, level)) + " ", attributes: attributes(base))
    content.append(inline(text, base: base))
    content.addAttribute(
      .messageAccessibility, value: MessageAccessibilityMark(.heading(level: level)),
      range: NSRange(location: 0, length: content.length))
    return unit(content, indent: context.indent)
  }

  /// A list as ``CLIListView`` draws it: markers in a column, the items' blocks beside it.
  private mutating func list(
    ordered: Bool, start: Int, items: [MarkdownListItem], in context: Context
  ) -> CLITextNode {
    let hasTask = items.contains { $0.task != .none }
    let columns = ordered ? "\(start + items.count).".count + 1 + (hasTask ? 2 : 0) : 2
    let listX = context.indent + metrics.character * CGFloat(context.nestedListIndent)
    var inner = context
    inner.indent = listX + metrics.character * CGFloat(columns)
    inner.nestedListIndent = max(0, CLIListView.nestedColumns - columns)
    var nodes: [CLITextNode] = []
    for (index, item) in items.enumerated() {
      pendingMarker = Marker(
        text: marker(number: ordered ? start + index : nil, task: item.task), start: listX)
      nodes.append(blocks(item.blocks, in: inner, isListItem: true))
      pendingMarker = nil
    }
    return .list(
      items: nodes, compact: metrics.lineSpacing, loose: metrics.blankLine,
      threshold: metrics.estimatedLineHeight * 1.5)
  }

  /// Numbers in the path blue, bullets and checkboxes in the marker color.
  private func marker(number: Int?, task: MarkdownTask) -> NSAttributedString {
    let marker = NSMutableAttributedString(
      string: number.map { "\($0). " } ?? "",
      attributes: [.font: metrics.font(), .foregroundColor: palette.path.platformColor])
    marker.append(
      NSAttributedString(
        string: CLIListMarker.glyph(ordered: number != nil, task: task),
        attributes: [.font: metrics.font(), .foregroundColor: palette.marker.platformColor]))
    let mark: MessageAccessibilityMark.Kind =
      switch (number, task) {
      case (_, .checked), (_, .unchecked): .task(label: CLIListMarker.label(number, task: task))
      case (let number?, .none): .number("\(number)")
      case (nil, .none): .bullet
      }
    marker.addAttribute(
      .messageAccessibility, value: MessageAccessibilityMark(mark),
      range: NSRange(location: 0, length: marker.length))
    return marker
  }

  // MARK: Tables

  /// A table as ``CLITableView`` draws it: each row a line, its cells on tab stops in columns as
  /// wide as their widest cell, the rules under the rows drawn beside the text.
  private mutating func table(_ table: MarkdownTable, in context: Context) -> CLITextNode {
    let header = table.header.map {
      inline($0, base: InlineBase(color: palette.strong, weight: .semibold))
    }
    let body = table.rows.map { row in
      row.map { inline($0, base: InlineBase(color: context.color)) }
    }
    let rows = [header] + body
    let columns = columns(of: rows, at: context.indent)
    var units: [Int] = []
    var rules: [CGFloat] = []
    let pad = metrics.points * 0.5
    for (index, row) in rows.enumerated() {
      var tabs: [NSTextTab] = []
      let line = NSMutableAttributedString()
      for (column, cell) in row.enumerated() {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        tabs.append(tab(in: columns[column], alignment: alignment))
        line.append(NSAttributedString(string: "\t", attributes: [.font: metrics.font()]))
        line.append(cell)
      }
      let node = unit(
        line, indent: context.indent, tabs: tabs, lineBreak: .byClipping, padTop: pad,
        padBottom: pad)
      if case .text(let unit) = node { units.append(unit) }
      rules.append(index == 0 ? 2 : (index == rows.count - 1 ? 0 : 1))
    }
    return .table(rows: units, rules: rules, columns: columns, color: palette.rule)
  }

  /// Columns as wide as their widest cell and its padding, two characters apart, from `leading`.
  private func columns(of rows: [[NSAttributedString]], at leading: CGFloat) -> [CLITextColumn] {
    let character = metrics.character
    var widths = [CGFloat](repeating: 0, count: rows.map(\.count).max() ?? 0)
    for row in rows {
      for (column, cell) in row.enumerated() {
        widths[column] = max(
          widths[column], metrics.ceiled(Self.width(of: cell)) + 2 * character)
      }
    }
    var columns: [CLITextColumn] = []
    var edge = leading
    for width in widths {
      columns.append(CLITextColumn(leading: edge, width: width))
      edge += width + 2 * character
    }
    return columns
  }

  /// Where a cell's text goes in its column: after its padding, before it, or centered.
  private func tab(in column: CLITextColumn, alignment: MarkdownAlignment) -> NSTextTab {
    let character = metrics.character
    return switch alignment {
    case .leading: NSTextTab(textAlignment: .left, location: column.leading + character)
    case .trailing:
      NSTextTab(textAlignment: .right, location: column.leading + column.width - character)
    case .center: NSTextTab(textAlignment: .center, location: column.leading + column.width / 2)
    }
  }

  /// A line's typographic width.
  static func width(of text: NSAttributedString) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
  }

  // MARK: Code

  /// Fenced code in the terminal's colors (``CLICodeHighlightCache``), or plain in the block's
  /// color for a language the highlighter doesn't know.
  func highlighted(_ code: String, language: String?, color: SRGB) -> NSAttributedString {
    guard CodeHighlighting.supports(language) else { return plain(code, color: color) }
    let result = NSMutableAttributedString(attributedString: plain(code, color: palette.body))
    let utf16 = code.utf16
    var position = utf16.startIndex
    var offset = 0
    for span in CodeSpanCache.shared.spans(code, language: language)
    where span.range.lowerBound >= offset {
      // A span that runs past the end or splits a character is left out, as
      // CodeHighlighting leaves it.
      guard
        let lower = utf16.index(
          position, offsetBy: span.range.lowerBound - offset, limitedBy: utf16.endIndex),
        let upper = utf16.index(lower, offsetBy: span.range.count, limitedBy: utf16.endIndex),
        String.Index(lower, within: code) != nil, String.Index(upper, within: code) != nil
      else { continue }
      result.addAttribute(
        .foregroundColor, value: CLICodeHighlightCache.color(span.token, palette).platformColor,
        range: NSRange(location: span.range.lowerBound, length: span.range.count))
      position = upper
      offset = span.range.upperBound
    }
    return result
  }
}
