public import SwiftUI

/// Renders markdown text: paragraphs, headings, lists and task lists, block quotes, GFM tables,
/// fenced code with a copy button, and rules. Text is selectable; links open only for
/// `http(s)` and `mailto`.
public struct MarkdownView: View {
  private let text: String
  private let isStreaming: Bool
  @Environment(\.markdownOutputRendering) private var rendering

  /// Creates the view.
  /// - Parameters:
  ///   - text: Markdown source.
  ///   - isStreaming: The text is still growing; skips the parse cache.
  public init(_ text: String, isStreaming: Bool = false) {
    self.text = text
    self.isStreaming = isStreaming
  }

  /// The rendered blocks, or agent output in its Plain or Styled rendering.
  public var body: some View {
    switch rendering {
    case .plain: CLISourceText(text: text, isStreaming: isStreaming)
    case .styled: CLIStyledMarkdown(text: text, isStreaming: isStreaming)
    case .rich:
      let blocks =
        isStreaming ? MarkdownParser.parse(text) : MarkdownCache.shared.blocks(for: text)
      MarkdownBlocksView(blocks: blocks)
        .proseStyle()
        .tint(Theme.link)
    }
  }
}

extension EnvironmentValues {
  @Entry var markdownFillsWidth = true
}

struct MarkdownBlocksView: View {
  let blocks: [MarkdownBlock]
  @Environment(\.markdownFillsWidth) private var fillsWidth

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.paragraph) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        MarkdownBlockView(block: block)
      }
    }
    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
  }
}

private struct MarkdownBlockView: View {
  let block: MarkdownBlock
  @Environment(\.markdownFillsWidth) private var fillsWidth

  var body: some View {
    switch block {
    case .paragraph(let text):
      Text(text)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    case .heading(let level, let text):
      Text(text)
        .font(headingFont(level))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, level <= 2 ? Theme.Spacing.small : Theme.Spacing.extraSmall)
        .accessibilityAddTraits(.isHeader)
    case .code(let language, let code):
      CodeBlockView(code: code, language: language)
    case .quote(let blocks):
      HStack(alignment: .top, spacing: Theme.Spacing.medium) {
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
      Divider().padding(.vertical, Theme.Spacing.extraSmall)
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
    case 1: .title.weight(.semibold)
    case 2: Theme.Typography.title
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
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
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
        .foregroundStyle(checked ? ThemeColor.primary : ThemeColor.secondary)
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
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.small)
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

/// Selectable code with a language header, wrap control and copy confirmation.
struct CodeBlockView: View {
  let code: String
  let language: String?
  var maxLines: Int?
  @State private var wrapsLines = true
  @ScaledMetric(relativeTo: .callout) private var lineHeight: CGFloat = 20

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Spacing.small) {
        Text(verbatim: language?.isEmpty == false ? (language ?? "Code") : "Code")
          .font(Theme.Typography.section)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: Theme.Spacing.small)
        Toggle(isOn: $wrapsLines) {
          Image(systemName: "text.word.spacing")
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .frame(minWidth: Theme.Control.target, minHeight: Theme.Control.target)
        .foregroundStyle(.secondary)
        .help(wrapsLines ? "Scroll long lines" : "Wrap long lines")
        .accessibilityLabel("Wrap code lines")
        CopyButton(text: code, label: "Copy code", showsLabel: true)
      }
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.extraSmall)
      .background(ThemeColor.hover)
      Divider()
      if let maxLines {
        BoundedScrollView(maxHeight: lineHeight * CGFloat(maxLines) + Theme.Spacing.extraLarge) {
          codeBody
        }
      } else {
        codeBody
      }
    }
    .background(ThemeColor.codeSurface)
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(ThemeColor.border)
    }
    .environment(\.colorScheme, .dark)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Code block\(language.map { ", \($0)" } ?? "")")
  }

  @ViewBuilder private var codeBody: some View {
    if wrapsLines {
      codeText.frame(maxWidth: .infinity, alignment: .leading)
    } else {
      ScrollView(.horizontal) {
        codeText.fixedSize(horizontal: true, vertical: true)
      }
    }
  }

  private var codeText: some View {
    Text(verbatim: code)
      .font(Theme.codeFont)
      .lineSpacing(Theme.Spacing.extraSmall)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .padding(Theme.Spacing.large)
  }
}
