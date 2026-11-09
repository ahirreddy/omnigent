import OmnigentWorkspaceUI
public import SwiftUI

/// Renders markdown text: paragraphs, headings, lists and task lists, block quotes, GFM tables,
/// syntax-highlighted fenced code with a copy button, rules, math, and workspace and `data:`
/// images. Text is selectable; links open only for `http(s)`, `mailto` and, with
/// ``WorkspaceFileLinks`` in the environment, workspace files that exist.
public struct MarkdownView: View {
  private let text: String
  private let isStreaming: Bool
  @Environment(\.markdownOutputRendering) private var rendering
  @State private var memo = MarkdownRenderMemo()

  /// Creates the view.
  /// - Parameters:
  ///   - text: Markdown source.
  ///   - isStreaming: The text is still growing: each update parses only its open block.
  public init(_ text: String, isStreaming: Bool = false) {
    self.text = text
    self.isStreaming = isStreaming
  }

  /// The rendered blocks, or agent output in its Plain or Styled rendering.
  public var body: some View {
    rendered.countsRenders("markdown")
  }

  @ViewBuilder private var rendered: some View {
    switch rendering {
    case .plain: CLISourceText(text: text, isStreaming: isStreaming)
    case .styled: CLIStyledMarkdown(text: text, isStreaming: isStreaming)
    case .rich:
      MarkdownBlocksView(
        blocks: memo.blocks(for: text, isStreaming: isStreaming), lastIsOpen: isStreaming
      )
      .readingProseStyle()
      .tint(Theme.link)
      .modifier(WorkspacePathLinking(paths: isStreaming ? [] : memo.citedPaths(for: text)))
    }
  }
}

/// Checks the workspace paths a message cites and routes in-app file links, when the host
/// provided ``WorkspaceFileLinks``.
private struct WorkspacePathLinking: ViewModifier {
  let paths: [CitedPath]
  @Environment(\.workspaceFileLinks) private var links
  @Environment(\.openURL) private var openURL

  func body(content: Content) -> some View {
    if let links {
      content
        .environment(\.openURL, links.openURLAction(fallback: openURL))
        .task(id: paths) { await links.check(paths) }
    } else {
      content
    }
  }
}

extension EnvironmentValues {
  @Entry var markdownFillsWidth = true
  /// The block below is the one a stream is still writing.
  @Entry var markdownBlockIsOpen = false
}

struct MarkdownBlocksView: View {
  let blocks: [MarkdownBlock]
  /// The last block is still being streamed.
  var lastIsOpen = false
  @Environment(\.markdownFillsWidth) private var fillsWidth

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
        MarkdownBlockView(block: block)
          .transformEnvironment(\.markdownBlockIsOpen) { isOpen in
            if lastIsOpen, index == blocks.count - 1 { isOpen = true }
          }
          .padding(
            .top, TypeRamp.spacing(above: block, after: index > 0 ? blocks[index - 1] : nil))
      }
    }
    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
  }
}

private struct MarkdownBlockView: View {
  let block: MarkdownBlock
  @Environment(\.markdownFillsWidth) private var fillsWidth
  @Environment(\.typeRamp) private var ramp
  @Environment(\.workspaceFileLinks) private var links

  var body: some View {
    switch block {
    case .paragraph(let text):
      MarkdownParagraphText(
        text: ramp.sizingMath(
          in: ramp.sizingCode(in: linked(text), size: ramp.code), size: ramp.body)
      )
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    case .heading(let level, let text):
      let size = ramp.heading(level)
      Text(ramp.sizingCode(in: linked(text), size: (size * TypeRamp.codeScale).rounded(.down)))
        .font(.system(size: size, weight: .semibold))
        .lineHeight(.exact(points: ramp.headingLineHeight(level)))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    case .code(let language, let code):
      if CodeHighlighting.fenceName(language) == "mermaid" {
        MermaidBlockView(source: code)
      } else {
        CodeBlockView(code: code, language: language)
      }
    case .quote(let blocks):
      MarkdownGutterLayout(gutter: .fullHeightRule, spacing: Theme.Spacing.medium) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(.tertiary)
          .frame(width: 3)
        MarkdownBlocksView(blocks: blocks)
          .foregroundStyle(.secondary)
      }
    case .list(let ordered, let start, let items):
      MarkdownListView(ordered: ordered, start: start, items: items)
    case .table(let table):
      MarkdownTableBlock(table: table)
    case .rule:
      Divider().padding(.vertical, Theme.Spacing.extraSmall)
    case .html(let raw):
      Text(verbatim: raw)
        .font(CodeTypography.shared.font(size: ramp.code))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    case .image(let source, let alt):
      MarkdownImageView(source: source, alt: alt)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    case .math(let tex):
      MathBlockView(tex: tex)
    }
  }

  /// `text` with the workspace files it cites linked, once they are known to exist.
  private func linked(_ text: AttributedString) -> AttributedString {
    links?.linking(text) ?? text
  }
}

private struct MarkdownListView: View {
  let ordered: Bool
  let start: Int
  let items: [MarkdownListItem]

  var body: some View {
    VStack(alignment: .leading, spacing: TypeRamp.listSpacing) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        MarkdownGutterLayout(gutter: .baselineMarker, spacing: Theme.Spacing.small) {
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

struct MarkdownTableView: View {
  let table: MarkdownTable
  @Environment(\.workspaceFileLinks) private var links

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
    return Text(links?.linking(text) ?? text)
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
  @Environment(\.typeRamp) private var ramp
  @Environment(\.colorScheme) private var scheme
  @Environment(\.markdownBlockIsOpen) private var isOpen

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Spacing.small) {
        Text(verbatim: CodeLanguageName.label(for: language))
          .font(Theme.Typography.section)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .layoutPriority(1)
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
        CodeBlockDownloadButton(code: code, language: language)
        CopyButton(text: code, label: "Copy code", showsLabel: true)
      }
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.extraSmall)
      .background(ThemeColor.hover)
      Divider()
      if let maxLines {
        BoundedScrollView(
          maxHeight: ramp.codeLineHeight * CGFloat(maxLines) + Theme.Spacing.extraLarge
        ) {
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
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Code block, \(CodeLanguageName.label(for: language))")
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

  /// The code, colored unless its block is still streaming (it colors once, when it closes).
  private var codeText: some View {
    let highlighted =
      isOpen ? nil : CodeHighlightCache.shared.attributed(code, language: language, scheme: scheme)
    return Text(highlighted ?? AttributedString(code))
      .font(CodeTypography.shared.font(size: ramp.code))
      .lineHeight(.exact(points: ramp.codeLineHeight))
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .padding(Theme.Spacing.large)
  }
}
