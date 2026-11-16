#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif
import SwiftUI

// MARK: Lists

nonisolated extension MessageTextBuilder {
  mutating func list(
    ordered: Bool, start: Int, items: [MarkdownListItem], in context: Context
  ) {
    let font = palette.font(size: ramp.body)
    for (index, item) in items.enumerated() {
      if index > 0 { pendingGap += TypeRamp.listSpacing }
      let marker = marker(ordered: ordered, number: start + index, task: item.task, font: font)
      let width = max(ordered ? 22 : 12, marker.size().width.rounded(.up))
      var inner = context
      inner.indent = context.indent + width + MessageTextMetrics.small
      pendingMarker = Marker(text: marker, start: context.indent, end: context.indent + width)
      switch item.blocks.first {
      case .paragraph, .heading:
        break
      default:
        // The marker gets a line of its own above a block that is not text.
        emit(
          Paragraph(
            content: NSAttributedString(), lineHeight: ramp.bodyLineHeight, font: font,
            indent: inner.indent, isPlaceholder: true), in: inner)
      }
      append(item.blocks, in: inner)
    }
  }

  private func marker(ordered: Bool, number: Int, task: MarkdownTask, font: PlatformFont)
    -> NSAttributedString
  {
    if task != .none, let checkbox = checkbox(checked: task == .checked, font: font) {
      return checkbox
    }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: ordered
        ? PlatformFont.monospacedDigitSystemFont(ofSize: ramp.body, weight: .regular) : font,
      .foregroundColor: palette.secondary,
    ]
    return NSAttributedString(string: ordered ? "\(number)." : "\u{2022}", attributes: attributes)
  }

  /// A task's checkbox, as ``MarkdownView`` draws it: the symbol at the body size, centered on
  /// the text.
  private func checkbox(checked: Bool, font: PlatformFont) -> NSAttributedString? {
    guard
      let image = MessageTextPlatform.symbol(
        checked ? "checkmark.square.fill" : "square", size: ramp.body,
        color: checked ? palette.text : palette.secondary,
        description: checked ? "Done" : "Not done")
    else { return nil }
    let attachment = NSTextAttachment()
    attachment.image = image
    let size = image.size
    attachment.bounds = CGRect(
      x: 0, y: ((font.capHeight - size.height) / 2).rounded(), width: size.width,
      height: size.height)
    return NSAttributedString(attachment: attachment)
  }
}

// MARK: Code

nonisolated extension MessageTextBuilder {
  /// A header line the layers and the Copy button sit on, then a paragraph per code line.
  mutating func codeBlock(_ code: String, language: String?, in context: Context) {
    lastBlock += 1
    let block = lastBlock
    hasWideBlocks = true
    chrome[block] = .code(code: code, language: language)
    emit(
      Paragraph(
        content: space(palette.sectionFont), lineHeight: Self.codeHeaderHeight + 1,
        font: palette.sectionFont, indent: context.indent,
        mark: MessageBlockMark(block: block, role: .codeHeader, indent: context.indent),
        spacesUnderGlyphs: false, isPlaceholder: true),
      in: context)
    let font = palette.codeFont
    let colored = highlighted(code, language: language, font: font)
    let lines = Self.lineRanges(in: colored.string)
    for (index, range) in lines.enumerated() {
      let isLast = index == lines.count - 1
      emit(
        Paragraph(
          content: colored.attributedSubstring(from: range), lineHeight: ramp.codeLineHeight,
          font: font, indent: context.indent + Self.codePadding, tailIndent: -Self.codePadding,
          before: index == 0 ? Self.codePadding : 0, after: isLast ? Self.codePadding : 0,
          mark: MessageBlockMark(
            block: block, role: .codeLine(isLast: isLast), indent: context.indent),
          keepsDefaultTabs: true), in: context)
    }
  }

  /// `code` in the code font, colored as ``CodeHighlightCache`` colors it.
  private func highlighted(_ code: String, language: String?, font: PlatformFont)
    -> NSMutableAttributedString
  {
    let colored = NSMutableAttributedString(
      string: code, attributes: [.font: font, .foregroundColor: palette.text])
    guard CodeHighlighting.supports(language) else { return colored }
    for span in CodeSpanCache.shared.spans(code, language: language) {
      let range = NSRange(location: span.range.lowerBound, length: span.range.count)
      // A span past the end would raise; the tokenizer's spans stay inside the code.
      guard range.location >= 0, NSMaxRange(range) <= colored.length else { continue }
      colored.addAttribute(.foregroundColor, value: palette.color(span.token), range: range)
    }
    return colored
  }

  /// Each line of `text`, without its line break, in UTF-16 offsets.
  static func lineRanges(in text: String) -> [NSRange] {
    var ranges: [NSRange] = []
    var location = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let length = line.utf16.count
      ranges.append(NSRange(location: location, length: length))
      location += length + 1
    }
    return ranges
  }
}

// MARK: Tables

nonisolated extension MessageTextBuilder {
  /// A row per line, cells on tab stops, with room for the rules and the Copy menu.
  mutating func table(_ table: MarkdownTable, in context: Context) {
    lastBlock += 1
    let block = lastBlock
    chrome[block] = .table(table)
    // A grid's cells draw inline code at the body size.
    let header = table.header.map {
      inline($0, size: ramp.body, weight: .semibold, codeSize: ramp.body, color: context.color)
    }
    let rows = table.rows.map { row in
      row.map { inline($0, size: ramp.body, codeSize: ramp.body, color: context.color) }
    }
    let all = [header] + rows
    let columns = MessageTableColumns(
      widths: MessageTableColumns.widths(of: all), alignments: table.alignments,
      indent: context.indent)
    let tab = NSAttributedString(string: "\t", attributes: [.font: palette.font(size: ramp.body)])
    for (index, cells) in all.enumerated() {
      let isHeader = index == 0
      let isLast = index == all.count - 1
      let content = NSMutableAttributedString()
      for (column, cell) in cells.enumerated() {
        if column > 0 || columns.leadsWithTab { content.append(tab) }
        content.append(cell)
      }
      let rule: CGFloat = isLast ? 0 : 1
      let role = MessageBlockMark.Role.tableRow(
        isHeader: isHeader, isLast: isLast, width: columns.width)
      emit(
        Paragraph(
          content: content, lineHeight: ramp.bodyLineHeight,
          font: palette.font(size: ramp.body, weight: isHeader ? .semibold : .regular),
          indent: context.indent, before: MessageTextMetrics.tableRowPadding,
          after: MessageTextMetrics.tableRowPadding + rule
            + (isLast ? Self.tableControlsHeight : 0),
          tabs: columns.tabs,
          mark: MessageBlockMark(block: block, role: role, indent: context.indent),
          lineBreak: .byClipping), in: context)
    }
  }
}

/// A table's columns as tab stops, sized as ``MarkdownTableView``'s grid sizes them: each
/// column as wide as its widest cell, between 60 and 360 points, then a gap.
nonisolated struct MessageTableColumns {
  static let minimum: CGFloat = 60
  static let maximum: CGFloat = 360
  /// The widest table drawn as text; a wider one stays a grid that scrolls sideways.
  static let widest: CGFloat = 600

  /// A tab stop per column but a leading first one, which starts at the paragraph's edge.
  let tabs: [NSTextTab]
  /// The first column is centered or trailing, so a row starts with a tab to it.
  let leadsWithTab: Bool
  /// All columns and their gaps.
  let width: CGFloat

  init(widths: [CGFloat], alignments: [MarkdownAlignment], indent: CGFloat) {
    var tabs: [NSTextTab] = []
    var start = indent
    for (column, width) in widths.enumerated() {
      let alignment = column < alignments.count ? alignments[column] : .leading
      switch alignment {
      case .leading: tabs.append(NSTextTab(textAlignment: .left, location: start))
      case .center: tabs.append(NSTextTab(textAlignment: .center, location: start + width / 2))
      case .trailing: tabs.append(NSTextTab(textAlignment: .right, location: start + width))
      }
      start += width + MessageTextMetrics.extraLarge
    }
    leadsWithTab = alignments.first.map { $0 != .leading } ?? false
    if !leadsWithTab, !tabs.isEmpty { tabs.removeFirst() }
    self.tabs = tabs
    width = start - indent
  }

  static func widths(of rows: [[NSAttributedString]]) -> [CGFloat] {
    var widths: [CGFloat] = []
    for row in rows {
      for (column, cell) in row.enumerated() {
        let width = max(minimum, cell.size().width.rounded(.up))
        if column < widths.count {
          widths[column] = max(widths[column], width)
        } else {
          widths.append(width)
        }
      }
    }
    return widths.map { min($0, maximum) }
  }

  /// Whether `table` draws as text: no cell wraps and the whole fits ``widest``. Measured with
  /// the plain text in the body font.
  static func fits(_ table: MarkdownTable, ramp: TypeRamp) -> Bool {
    let regular = PlatformFont.systemFont(ofSize: ramp.body)
    let bold = PlatformFont.systemFont(ofSize: ramp.body, weight: .semibold)
    func plain(_ cell: AttributedString, _ font: PlatformFont) -> NSAttributedString {
      NSAttributedString(string: String(cell.characters), attributes: [.font: font])
    }
    let rows =
      [table.header.map { plain($0, bold) }]
      + table.rows.map { $0.map { plain($0, regular) } }
    let natural = rows.flatMap { $0.map { $0.size().width } }
    guard natural.allSatisfy({ $0 <= maximum }) else { return false }
    let total = widths(of: rows).reduce(0) { $0 + $1 + MessageTextMetrics.extraLarge }
    return total <= widest
  }
}
