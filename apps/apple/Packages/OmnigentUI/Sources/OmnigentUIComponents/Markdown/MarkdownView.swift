public import SwiftUI

/// Renders markdown text: paragraphs, headings, lists and task lists, block quotes, GFM tables,
/// fenced code with a copy button, and rules. Text is selectable; links open only for
/// `http(s)` and `mailto`.
public struct MarkdownView: View {
  private let text: String
  private let isStreaming: Bool

  /// Creates the view.
  /// - Parameters:
  ///   - text: Markdown source.
  ///   - isStreaming: The text is still growing; skips the parse cache.
  public init(_ text: String, isStreaming: Bool = false) {
    self.text = text
    self.isStreaming = isStreaming
  }

  /// The rendered blocks.
  public var body: some View {
    let blocks =
      isStreaming ? MarkdownParser.parse(text) : MarkdownCache.shared.blocks(for: text)
    MarkdownBlocksView(blocks: blocks)
      .tint(Theme.link)
  }
}

struct MarkdownBlocksView: View {
  let blocks: [MarkdownBlock]

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.paragraph) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        MarkdownBlockView(block: block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MarkdownBlockView: View {
  let block: MarkdownBlock

  var body: some View {
    switch block {
    case .paragraph(let text):
      Text(text)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .heading(let level, let text):
      Text(text)
        .font(headingFont(level))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, level <= 2 ? 6 : 2)
        .accessibilityAddTraits(.isHeader)
    case .code(let language, let code):
      CodeBlockView(code: code, language: language)
    case .quote(let blocks):
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(.tertiary)
          .frame(width: 3)
        MarkdownBlocksView(blocks: blocks)
          .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    case .list(let ordered, let start, let items):
      MarkdownListView(ordered: ordered, start: start, items: items)
    case .table(let table):
      MarkdownTableView(table: table)
    case .rule:
      Divider().padding(.vertical, 4)
    case .html(let raw):
      Text(verbatim: raw)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title2.weight(.semibold)
    case 2: .title3.weight(.semibold)
    case 3: .headline
    default: .subheadline.weight(.semibold)
    }
  }
}

private struct MarkdownListView: View {
  let ordered: Bool
  let start: Int
  let items: [MarkdownListItem]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          marker(index: index, item: item)
            .frame(minWidth: ordered ? 22 : 12, alignment: .trailing)
          MarkdownBlocksView(blocks: item.blocks)
        }
      }
    }
  }

  @ViewBuilder
  private func marker(index: Int, item: MarkdownListItem) -> some View {
    if item.task != .none {
      let checked = item.task == .checked
      Image(systemName: checked ? "checkmark.square.fill" : "square")
        .foregroundStyle(checked ? Theme.accent : ThemeColor.secondary)
        .accessibilityLabel(checked ? "Done" : "Not done")
    } else if ordered {
      Text(verbatim: "\(start + index).")
        .monospacedDigit()
        .foregroundStyle(.secondary)
    } else {
      Text(verbatim: "\u{2022}")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }
}

private struct MarkdownTableView: View {
  let table: MarkdownTable

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
            cellView(cell, column: column)
              .font(.callout.weight(.semibold))
          }
        }
        .background(.quaternary.opacity(0.6))
        ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
          Divider().gridCellUnsizedAxes(.horizontal)
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
              cellView(cell, column: column)
                .font(.callout)
            }
          }
          .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.05))
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
      .overlay {
        RoundedRectangle(cornerRadius: Theme.Radius.small)
          .strokeBorder(.separator)
      }
    }
    .scrollIndicators(.automatic)
  }

  private func cellView(_ text: AttributedString, column: Int) -> some View {
    let alignment = column < table.alignments.count ? table.alignments[column] : .leading
    return Text(text)
      .textSelection(.enabled)
      .multilineTextAlignment(textAlignment(alignment))
      .frame(minWidth: 60, maxWidth: 360, alignment: frameAlignment(alignment))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .gridColumnAlignment(horizontalAlignment(alignment))
  }

  private func textAlignment(_ alignment: MarkdownAlignment) -> TextAlignment {
    switch alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  private func frameAlignment(_ alignment: MarkdownAlignment) -> Alignment {
    switch alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  private func horizontalAlignment(_ alignment: MarkdownAlignment) -> HorizontalAlignment {
    switch alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }
}

/// A fenced code block: a language label, a copy button, and horizontally scrolling,
/// selectable monospaced text.
struct CodeBlockView: View {
  let code: String
  let language: String?
  /// Lines shown before the block scrolls vertically; `nil` shows every line.
  var maxLines: Int?
  @ScaledMetric(relativeTo: .footnote) private var lineHeight: CGFloat = 15

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text(verbatim: language ?? "code")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        CopyButton(text: code, label: "Copy code")
      }
      .padding(.leading, 12)
      .padding(.trailing, 6)
      .padding(.vertical, 4)
      Divider().opacity(0.6)
      codeBody
    }
    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(.separator.opacity(0.6))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Code block\(language.map { ", \($0)" } ?? "")")
  }

  @ViewBuilder private var codeBody: some View {
    let text = Text(verbatim: code)
      .font(Theme.codeFont)
      .textSelection(.enabled)
      .fixedSize(horizontal: true, vertical: true)
      .padding(12)
    if let maxLines, Theme.lineCount(code) > maxLines {
      ScrollView([.horizontal, .vertical]) { text }
        .frame(height: lineHeight * CGFloat(maxLines) + 24)
    } else {
      ScrollView(.horizontal) { text }
    }
  }
}
