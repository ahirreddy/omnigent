import SwiftUI

/// Styled output: the shared markdown parse (``MarkdownParser``) drawn the way a terminal UI
/// draws it: heading markers kept and colored, accent bold and italic, green inline code, blue
/// underlined links followed by their URL, `>` quotes and ruled tables.
struct CLIStyledMarkdown: View {
  let text: String
  var isStreaming = false
  @Environment(\.cliPalette) private var palette

  var body: some View {
    let blocks =
      isStreaming ? MarkdownParser.parse(text) : MarkdownCache.shared.blocks(for: text)
    CLIBlocks(blocks: blocks, cursor: isStreaming)
      .foregroundStyle(palette.body.color)
      .cliFont()
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Inline markdown restyled with CLI colors.
nonisolated enum CLIInline {
  static func styled(_ text: AttributedString, palette: CLIPalette) -> AttributedString {
    var result = AttributedString()
    let runs = Array(text.runs)
    for (index, run) in runs.enumerated() {
      var piece = AttributedString(text[run.range])
      piece.backgroundColor = nil
      let intent = run.inlinePresentationIntent ?? []
      if intent.contains(.code) {
        piece.foregroundColor = palette.code.color
      } else if intent.contains(.stronglyEmphasized) {
        piece.foregroundColor = palette.bold.color
      } else if intent.contains(.emphasized) {
        piece.foregroundColor = palette.italic.color
      }
      if let link = run.link {
        piece.foregroundColor = palette.link.color
        piece.underlineStyle = .single
        result.append(piece)
        let next = index + 1 < runs.count ? runs[index + 1].link : nil
        let label = String(text[run.range].characters)
        // The URL follows the link text, as a terminal shows it, unless the text is the URL.
        if next != link, label != link.absoluteString {
          var url = AttributedString(link.absoluteString)
          url.link = link
          url.foregroundColor = palette.link.color
          url.underlineStyle = .single
          result.append(AttributedString(" ("))
          result.append(url)
          result.append(AttributedString(")"))
        }
        continue
      }
      result.append(piece)
    }
    return result
  }
}

private struct CLIBlocks: View {
  let blocks: [MarkdownBlock]
  var cursor = false
  private let size = CLIFontSize()

  var body: some View {
    VStack(alignment: .leading, spacing: size.line) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
        CLIMarkdownBlockView(block: block, cursor: cursor && index == blocks.count - 1)
      }
      if cursor, blocks.isEmpty { CLIMarkdownBlockView(block: .paragraph(""), cursor: true) }
    }
  }
}

private struct CLIMarkdownBlockView: View {
  let block: MarkdownBlock
  var cursor = false
  @Environment(\.cliPalette) private var palette
  private let size = CLIFontSize()

  var body: some View {
    switch block {
    case .paragraph(let text):
      Text(withCursor(CLIInline.styled(text, palette: palette)))
        .fixedSize(horizontal: false, vertical: true)
    case .heading(let level, let text):
      heading(level: level, text: text)
    case .code(_, let code):
      Text(withCursor(colored(code, palette.code)))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, size.character * 2)
        .accessibilityLabel("Code: \(code)")
    case .quote(let blocks):
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text(verbatim: ">").foregroundStyle(palette.quote.color)
          .frame(width: size.character * 2, alignment: .leading)
          .accessibilityHidden(true)
        CLIBlocks(blocks: blocks, cursor: cursor).foregroundStyle(palette.quote.color)
      }
    case .list(let ordered, let start, let items):
      CLIListView(ordered: ordered, start: start, items: items, cursor: cursor)
    case .table(let table):
      CLITableView(table: table)
    case .rule:
      Rectangle().fill(palette.rule.color).frame(height: 1)
        .padding(.vertical, size.points * 0.4)
        .accessibilityHidden(true)
    case .html(let raw):
      Text(withCursor(colored(raw, palette.dim)))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func heading(level: Int, text: AttributedString) -> some View {
    let minor = level >= 3
    var marker = AttributedString(String(repeating: "#", count: max(1, level)) + " ")
    var body = CLIInline.styled(text, palette: palette)
    let color = minor ? palette.strong.color : palette.heading.color
    marker.foregroundColor = color
    for run in body.runs where run.foregroundColor == nil {
      body[run.range].foregroundColor = color
    }
    marker.append(body)
    return Text(withCursor(marker))
      .fontWeight(.semibold)
      .italic(minor)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityAddTraits(.isHeader)
  }

  private func colored(_ text: String, _ color: SRGB) -> AttributedString {
    var result = AttributedString(text)
    result.foregroundColor = color.color
    return result
  }

  private func withCursor(_ text: AttributedString) -> AttributedString {
    guard cursor else { return text }
    var result = text
    if !result.characters.isEmpty { result.append(AttributedString(" ")) }
    result.append(CLICursor.attributed(palette))
    return result
  }
}

private struct CLIListView: View {
  let ordered: Bool
  let start: Int
  let items: [MarkdownListItem]
  var cursor = false
  @Environment(\.cliPalette) private var palette
  private let size = CLIFontSize()

  var body: some View {
    let width =
      ordered ? size.character * CGFloat("\(start + items.count).".count + 1) : size.character * 2
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          marker(index: index, item: item).frame(width: width, alignment: .leading)
          CLIBlocks(blocks: item.blocks, cursor: cursor && index == items.count - 1)
        }
      }
    }
  }

  @ViewBuilder
  private func marker(index: Int, item: MarkdownListItem) -> some View {
    switch item.task {
    case .checked:
      Text(verbatim: "[x]").foregroundStyle(palette.marker.color).accessibilityLabel("Done")
    case .unchecked:
      Text(verbatim: "[ ]").foregroundStyle(palette.dim.color).accessibilityLabel("Not done")
    case .none:
      if ordered {
        Text(verbatim: "\(start + index).")
      } else {
        Text(verbatim: "\u{2022}").foregroundStyle(palette.marker.color).accessibilityHidden(true)
      }
    }
  }
}

/// A terminal table: a bold header, a heavier rule under it, a rule between rows, and column
/// gaps that break the rules, as the Codex CLI draws them.
private struct CLITableView: View {
  let table: MarkdownTable
  @Environment(\.cliPalette) private var palette
  private let size = CLIFontSize()

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: size.character * 2, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
            cellView(cell, column: column, rule: 2)
              .foregroundStyle(palette.strong.color)
              .fontWeight(.semibold)
          }
        }
        ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
              cellView(cell, column: column, rule: index == table.rows.count - 1 ? 0 : 1)
            }
          }
        }
      }
      .fixedSize()
    }
    .scrollIndicators(.automatic)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Table")
  }

  private func cellView(_ text: AttributedString, column: Int, rule: CGFloat) -> some View {
    let alignment = column < table.alignments.count ? table.alignments[column] : .leading
    return Text(CLIInline.styled(text, palette: palette))
      .padding(.horizontal, size.character)
      .padding(.vertical, size.points * 0.5)
      .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
      .overlay(alignment: .bottom) {
        if rule > 0 {
          Rectangle().fill(palette.rule.color).frame(height: rule).accessibilityHidden(true)
        }
      }
  }

  private func frameAlignment(_ alignment: MarkdownAlignment) -> Alignment {
    switch alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }
}
