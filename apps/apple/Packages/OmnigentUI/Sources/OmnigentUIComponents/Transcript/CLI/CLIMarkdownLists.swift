import SwiftUI

extension EnvironmentValues {
  /// How far a list sits inside the item that holds it, in characters: a nested list starts
  /// four columns in from its parent's marker, as the Codex CLI indents it.
  @Entry var cliNestedListIndent = 0
  /// Blocks sit a whole blank line apart, so a quote's column of markers stays on its lines.
  @Entry var cliQuoteLineGrid = false
}

/// A list as a terminal draws it: `•`, `1.` or a checkbox in a marker column, the item's text on
/// the column beside it.
struct CLIListView: View {
  /// The columns from a marker to the list nested under it.
  nonisolated static let nestedColumns = 4

  let ordered: Bool
  let start: Int
  let items: [MarkdownListItem]
  let cursor: Bool
  @Environment(\.cliPalette) private var palette
  @Environment(\.cliNestedListIndent) private var indent
  private(set) var size = CLIFontSize()

  /// The marker column's width in characters: the longest marker and the space after it.
  private var columns: Int {
    let number = ordered ? "\(start + items.count).".count + 1 : 0
    let hasTask = items.contains { $0.task != .none }
    return ordered ? number + (hasTask ? 2 : 0) : 2
  }

  var body: some View {
    let columns = columns
    // A list still streaming stays compact, so its items don't jump apart as one wraps.
    CLIListLayout(
      lineHeight: size.lineHeight, compact: size.lineSpacing,
      loose: cursor ? size.lineSpacing : size.blankLine
    ) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          let label = CLIListMarker.label(ordered ? start + index : nil, task: item.task)
          Text(marker(index: index, item: item))
            .frame(width: size.character * CGFloat(columns), alignment: .leading)
            .accessibilityLabel(label)
            .accessibilityHidden(label.isEmpty)
          CLIBlocks(
            blocks: item.blocks, cursor: cursor && index == items.count - 1, isListItem: true
          )
          .environment(\.cliNestedListIndent, max(0, Self.nestedColumns - columns))
        }
      }
    }
    .padding(.leading, size.character * CGFloat(indent))
  }

  /// Numbers in the path blue, bullets and checkboxes in the marker color.
  private func marker(index: Int, item: MarkdownListItem) -> AttributedString {
    var marker = AttributedString(ordered ? "\(start + index). " : "")
    marker.foregroundColor = palette.path.color
    var glyph = AttributedString(CLIListMarker.glyph(ordered: ordered, task: item.task))
    glyph.foregroundColor = palette.marker.color
    marker.append(glyph)
    return marker
  }
}

/// What stands before a list item: a checkbox after its number or in place of its bullet.
nonisolated enum CLIListMarker {
  static func glyph(ordered: Bool, task: MarkdownTask) -> String {
    switch task {
    case .checked: "\u{2611}"
    case .unchecked: "\u{2610}"
    case .none: ordered ? "" : "\u{2022}"
    }
  }

  /// What VoiceOver reads for the marker; empty for a plain bullet, which says nothing.
  static func label(_ number: Int?, task: MarkdownTask) -> String {
    let state: String? =
      switch task {
      case .checked: "Done"
      case .unchecked: "Not done"
      case .none: nil
      }
    return [number.map(String.init), state].compactMap(\.self).joined(separator: ", ")
  }
}

/// Stacks a list's items one line pitch apart, or a blank line apart once any item takes more
/// than one line, as the Codex CLI spaces a list.
struct CLIListLayout: Layout {
  let lineHeight: CGFloat
  let compact: CGFloat
  let loose: CGFloat

  /// The gap between items of these heights.
  func gap(heights: [CGFloat]) -> CGFloat {
    heights.contains { $0 > lineHeight * 1.5 } ? loose : compact
  }

  private func sizes(_ subviews: Subviews, width: CGFloat?) -> [CGSize] {
    subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = sizes(subviews, width: proposal.width)
    let heights = sizes.map(\.height)
    let gaps = gap(heights: heights) * CGFloat(max(0, sizes.count - 1))
    return CGSize(
      width: proposal.width ?? sizes.map(\.width).max() ?? 0,
      height: heights.reduce(0, +) + gaps)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let sizes = sizes(subviews, width: bounds.width)
    let spacing = gap(heights: sizes.map(\.height))
    var top = bounds.minY
    for (subview, size) in zip(subviews, sizes) {
      subview.place(
        at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: size.height))
      top += size.height + spacing
    }
  }
}

/// A block quote as a terminal draws it: `>` before every line, the text in the quote color.
struct CLIQuoteView: View {
  let blocks: [MarkdownBlock]
  let cursor: Bool
  @Environment(\.cliPalette) private var palette
  private(set) var size = CLIFontSize()

  var body: some View {
    CLIBlocks(blocks: blocks, cursor: cursor)
      .environment(\.cliQuoteLineGrid, true)
      .environment(\.cliNestedListIndent, 0)
      .padding(.leading, size.character * 2)
      .background(alignment: .topLeading) { markers }
      .foregroundStyle(palette.quote.color)
  }

  /// A column of markers on the quote's line pitch, cut off where the quote ends.
  private var markers: some View {
    let count = blocks.reduce(blocks.count) { $0 + $1.lineBound }
    return Text(verbatim: Array(repeating: ">", count: count).joined(separator: "\n"))
      .fixedSize()
      // No taller than the quote: without a minimum the frame grows to fit every marker.
      .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
      .clipped()
      .textSelection(.disabled)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

extension MarkdownBlock {
  /// The fewest characters a line is taken to hold when bounding a block's lines.
  nonisolated static let narrowestLine = 16

  /// An upper bound on the lines the block draws in a column at least ``narrowestLine`` wide.
  nonisolated var lineBound: Int {
    switch self {
    case .paragraph(let text), .heading(_, let text):
      Self.lineBound(String(text.characters)) + 1
    case .code(_, let code): Self.lineBound(code)
    case .html(let text), .math(let text): Self.lineBound(text)
    case .image(let source, let alt), .video(let source, let alt):
      Self.lineBound(source + alt) + 1
    case .quote(let blocks): blocks.reduce(blocks.count) { $0 + $1.lineBound }
    case .list(_, _, let items):
      items.reduce(0) { total, item in
        total + item.blocks.reduce(item.blocks.count + 1) { $0 + $1.lineBound }
      }
    case .table(let table): 2 * (table.rows.count + 2)
    case .rule: 1
    }
  }

  private nonisolated static func lineBound(_ text: String) -> Int {
    text.split(separator: "\n", omittingEmptySubsequences: false)
      .reduce(0) { $0 + $1.count / narrowestLine + 1 }
  }
}
