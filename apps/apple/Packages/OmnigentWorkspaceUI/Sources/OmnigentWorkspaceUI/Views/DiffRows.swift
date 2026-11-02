import SwiftUI

// The rows of `DiffViewerView`: hunk headers, unified lines and side-by-side cells.

enum DiffIDs {
  static func hunk(_ index: Int) -> String { "hunk-\(index)" }
}

/// The unified diff's line-number gutter: old and new columns, or on a phone-width pane one
/// narrower column (the new number, else the old), which leaves about 60 pt more for code.
enum DiffGutter {
  /// Widths under this get the single column.
  static let compactBelow: CGFloat = 520
  static let width: CGFloat = 44
  static let compactWidth: CGFloat = 32

  static func isCompact(_ width: CGFloat) -> Bool { width > 0 && width < compactBelow }

  /// The numbers shown for `line`: both columns, or the single one.
  static func numbers(_ line: DiffLine, compact: Bool) -> [UInt64?] {
    compact ? [line.newNumber ?? line.oldNumber] : [line.oldNumber, line.newNumber]
  }
}

struct HunkHeaderRow: View {
  let header: String
  let isCurrent: Bool

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Text(header)
      .font(WorkspaceTheme.gutter)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
      .background(WorkspaceTheme.hunkBackground(scheme))
      .overlay(alignment: .leading) {
        if isCurrent {
          Rectangle().fill(Color.accentColor).frame(width: 3)
        }
      }
  }
}

struct UnifiedDiffBody: View {
  let hunks: [DiffHunk]
  let current: Int?
  let width: CGFloat

  private enum Row {
    case header(index: Int, text: String)
    case line(DiffLine)
  }

  /// One flat list, so the lazy stack sizes and recycles rows reliably in both scroll axes.
  private var rows: [Row] {
    hunks.enumerated().flatMap { index, hunk in
      [Row.header(index: index, text: hunk.header)] + hunk.lines.map(Row.line)
    }
  }

  var body: some View {
    ScrollView([.vertical, .horizontal]) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          switch row {
          case .header(let index, let text):
            HunkHeaderRow(header: text, isCurrent: current == index)
              .id(DiffIDs.hunk(index))
          case .line(let line):
            UnifiedLineRow(line: line, compactGutter: DiffGutter.isCompact(width))
          }
        }
      }
      .frame(minWidth: width, alignment: .leading)
      .textSelection(.enabled)
    }
    .defaultScrollAnchor(.topLeading, for: .alignment)
  }
}

private struct UnifiedLineRow: View {
  let line: DiffLine
  let compactGutter: Bool

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      ForEach(Array(DiffGutter.numbers(line, compact: compactGutter).enumerated()), id: \.offset) {
        gutter($0.element)
      }
      Text(marker)
        .font(WorkspaceTheme.code)
        .foregroundStyle(markerColor)
        .frame(width: 16)
        .accessibilityHidden(true)
      Text(DiffText.display(line.text))
        .font(WorkspaceTheme.code)
        .fixedSize(horizontal: true, vertical: false)
      if line.missingNewline {
        Image(systemName: "return")
          .font(.system(size: 9))
          .foregroundStyle(.red)
          .padding(.leading, 4)
          .help("No newline at end of file")
          .accessibilityLabel("No newline at end of file")
      }
      Spacer(minLength: 16)
    }
    .frame(maxWidth: .infinity, minHeight: WorkspaceTheme.lineHeight, alignment: .leading)
    .background(background)
  }

  private func gutter(_ number: UInt64?) -> some View {
    Text(number.map(String.init) ?? "")
      .font(WorkspaceTheme.gutter)
      .foregroundStyle(.tertiary)
      .frame(
        width: compactGutter ? DiffGutter.compactWidth : DiffGutter.width, alignment: .trailing
      )
      .padding(.trailing, 4)
      .background(WorkspaceTheme.gutterBackground(scheme))
      .accessibilityHidden(true)
  }

  private var marker: String {
    switch line.kind {
    case .added: "+"
    case .removed: "-"
    case .context: " "
    }
  }

  private var markerColor: Color {
    switch line.kind {
    case .added: .green
    case .removed: .red
    case .context: .secondary
    }
  }

  private var background: Color {
    switch line.kind {
    case .added: WorkspaceTheme.addedBackground(scheme)
    case .removed: WorkspaceTheme.removedBackground(scheme)
    case .context: .clear
    }
  }
}

struct SplitDiffBody: View {
  let rows: [SplitRow]
  let current: Int?

  var body: some View {
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          switch row {
          case .hunk(let index, let header):
            HunkHeaderRow(header: header, isCurrent: current == index)
              .id(DiffIDs.hunk(index))
          case .line(let left, let right):
            HStack(spacing: 0) {
              SplitCellView(cell: left)
              Divider()
              SplitCellView(cell: right)
            }
          }
        }
      }
      .textSelection(.enabled)
    }
  }
}

private struct SplitCellView: View {
  let cell: SplitCell?

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(cell.map { String($0.number) } ?? "")
        .font(WorkspaceTheme.gutter)
        .foregroundStyle(.tertiary)
        .frame(width: 44, alignment: .trailing)
        .padding(.trailing, 8)
        .background(WorkspaceTheme.gutterBackground(scheme))
        .accessibilityHidden(true)
      if let cell {
        Text(text(for: cell))
          .font(WorkspaceTheme.code)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: WorkspaceTheme.lineHeight, alignment: .leading)
    .background(background)
  }

  private func text(for cell: SplitCell) -> AttributedString {
    let display = DiffText.display(cell.text)
    guard let changed = cell.changed, cell.kind != .context else {
      return AttributedString(display)
    }
    let span = TextRange(
      start: min(changed.start, display.utf8.count), end: min(changed.end, display.utf8.count))
    return Highlighting.marked(
      display, range: span.utf8Range(in: display),
      background: WorkspaceTheme.spanBackground(cell.kind, scheme))
  }

  private var background: Color {
    switch cell?.kind {
    case .added: WorkspaceTheme.addedBackground(scheme)
    case .removed: WorkspaceTheme.removedBackground(scheme)
    case .context: .clear
    case nil: Color.secondary.opacity(0.06)
    }
  }
}

/// Display text for a diff line: a trailing carriage return is not drawn.
enum DiffText {
  static func display(_ text: String) -> String {
    text.hasSuffix("\r") ? String(text.dropLast()) : text
  }
}
