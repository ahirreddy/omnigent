public import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// Every file of a change set in one scroll, as a pull request's Files view shows it: a header
/// per file that collapses its diff, a menu that jumps to a file, and Collapse All. Views can sit
/// under lines and file headers (review conversations), and line numbers can choose lines.
public struct StackedDiffView: View {
  private let files: [FileDiff]
  private let annotations: StackedDiffAnnotations
  @State private var collapsed: Set<String> = []

  /// A stacked diff.
  /// - Parameters:
  ///   - files: The diffs, in patch order.
  ///   - annotations: What shows beside the lines.
  public init(files: [FileDiff], annotations: StackedDiffAnnotations = StackedDiffAnnotations()) {
    self.files = files
    self.annotations = annotations
  }

  private enum Row {
    case file(FileDiff)
    case notice(path: String, text: String)
    case hunk(path: String, index: Int, header: String)
    case line(path: String, hunk: Int, DiffLine)
    case annotation(AnyView)
  }

  /// One flat list, so the lazy stack sizes and recycles rows reliably in both scroll axes.
  private var rows: [Row] {
    files.flatMap { file -> [Row] in
      guard !collapsed.contains(file.path) else { return [.file(file)] }
      let note = annotations.files[file.path].map { [Row.annotation($0)] } ?? []
      if file.binary {
        return [.file(file)] + note + [.notice(path: file.path, text: "Binary file")]
      }
      if file.tooLarge {
        return [.file(file)] + note
          + [.notice(path: file.path, text: "This change is too large to show.")]
      }
      return [.file(file)] + note + lineRows(file)
    }
  }

  /// A file's hunks and lines, with each annotation under its line.
  private func lineRows(_ file: FileDiff) -> [Row] {
    let placements = Self.placements(file, among: Set(annotations.lines.keys))
    var rows: [Row] = []
    var position = 0
    for (index, hunk) in file.hunks.enumerated() {
      rows.append(.hunk(path: file.path, index: index, header: hunk.header))
      for line in hunk.lines {
        rows.append(.line(path: file.path, hunk: index, line))
        for anchor in placements[position] ?? [] {
          if let view = annotations.lines[anchor] { rows.append(.annotation(view)) }
        }
        position += 1
      }
    }
    return rows
  }

  /// Which of `anchors` go under which of the file's lines, counted across its hunks: each
  /// under the first line that carries it.
  static func placements(_ file: FileDiff, among anchors: Set<DiffLineAnchor>)
    -> [Int: [DiffLineAnchor]]
  {
    var placed: Set<DiffLineAnchor> = []
    var result: [Int: [DiffLineAnchor]] = [:]
    let lines = file.hunks.flatMap(\.lines)
    for (position, line) in lines.enumerated() {
      for anchor in DiffLineAnchor.all(line, path: file.path)
      where anchors.contains(anchor) && !placed.contains(anchor) {
        placed.insert(anchor)
        result[position, default: []].append(anchor)
      }
    }
    return result
  }

  /// The view.
  public var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        VStack(spacing: 0) {
          toolbar(proxy: proxy)
          Divider()
          ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                content(row, width: geometry.size.width)
              }
            }
            .frame(minWidth: geometry.size.width, alignment: .leading)
            .textSelection(.enabled)
          }
          .defaultScrollAnchor(.topLeading, for: .alignment)
        }
      }
    }
    .accessibilityIdentifier("workspace.stacked-diff")
  }

  @ViewBuilder private func content(_ row: Row, width: CGFloat) -> some View {
    switch row {
    case .file(let file):
      StackedFileHeader(
        file: file, isCollapsed: collapsed.contains(file.path),
        toggle: { toggle(file.path) }
      )
      .frame(width: width)
      .id(file.path)
    case .notice(_, let text):
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
    case .hunk(_, _, let header):
      HunkHeaderRow(header: header, isCurrent: false)
    case .line(let path, let hunk, let line):
      lineRow(line, path: path, hunk: hunk, width: width)
    case .annotation(let view):
      view
        .frame(width: max(width - 24, 0), alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
  }

  @ViewBuilder
  private func lineRow(_ line: DiffLine, path: String, hunk: Int, width: CGFloat) -> some View {
    let compact = DiffGutter.isCompact(width)
    let row = UnifiedLineRow(line: line, compactGutter: compact)
    if let select = annotations.select, let anchor = DiffLineAnchor.of(line, path: path) {
      let chosen = annotations.selection?.contains(anchor) == true
      row
        .overlay(alignment: .leading) {
          Color.accentColor.opacity(chosen ? 0.18 : 0.001)
            .frame(width: (compact ? DiffGutter.compactWidth : DiffGutter.width * 2) + 8)
            .contentShape(Rectangle())
            .onTapGesture { select(selection(anchor, hunk: hunk)) }
            .help("Comment on this line\(Self.extendHint)")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Comment on line \(anchor.line)")
        }
    } else {
      row
    }
  }

  /// A click chooses the line; on the Mac, Shift-click extends the choice within its hunk.
  private func selection(_ anchor: DiffLineAnchor, hunk: Int) -> DiffLineSelection {
    let single = DiffLineSelection(
      path: anchor.path, side: anchor.side, start: anchor.line, end: anchor.line, hunk: hunk)
    #if os(macOS)
      if NSEvent.modifierFlags.contains(.shift), let current = annotations.selection {
        return current.extended(to: anchor, hunk: hunk)
      }
    #endif
    return single
  }

  #if os(macOS)
    private static let extendHint = "; Shift-click to choose a range"
  #else
    private static let extendHint = ""
  #endif

  private func toolbar(proxy: ScrollViewProxy) -> some View {
    HStack(spacing: 8) {
      Menu {
        ForEach(files, id: \.path) { file in
          Button(file.path) {
            collapsed.remove(file.path)
            proxy.scrollTo(file.path, anchor: .top)
          }
        }
      } label: {
        Text(files.count == 1 ? "1 file" : "\(files.count) files")
      }
      .menuStyle(.button)
      .buttonStyle(.borderless)
      .fixedSize()
      .help("Jump to a file")
      LineCounts(
        added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed })
      Spacer(minLength: 8)
      let allCollapsed = !files.isEmpty && collapsed.count == files.count
      Button {
        collapsed = allCollapsed ? [] : Set(files.map(\.path))
      } label: {
        Image(
          systemName: allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical"
        )
        .accessibilityLabel(allCollapsed ? "Expand all files" : "Collapse all files")
      }
      .buttonStyle(.borderless)
      .help(allCollapsed ? "Expand all files" : "Collapse all files")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  private func toggle(_ path: String) {
    if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
  }
}

/// A file's header in the stacked diff; clicking it collapses or expands the file.
private struct StackedFileHeader: View {
  let file: FileDiff
  let isCollapsed: Bool
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 6) {
        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 12)
          .accessibilityHidden(true)
        Text(WorkspacePaths.name(of: file.path))
          .font(.callout.weight(.semibold))
          .lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
        Spacer(minLength: 8)
        LineCounts(added: file.added, removed: file.removed)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .help(file.path)
    .accessibilityLabel("\(file.path), \(isCollapsed ? "collapsed" : "expanded")")
    .accessibilityHint("Shows or hides this file's changes")
  }

  private var subtitle: String {
    switch file.change {
    case .renamed, .copied: "\(file.oldPath ?? "") \u{2192} \(file.newPath ?? "")"
    case .added: "new file"
    case .deleted: "deleted"
    case .modified: WorkspacePaths.directory(of: file.path)
    }
  }
}

#Preview("Stacked diff") {
  StackedDiffView(files: [WorkspaceSamples.mainDiff, WorkspaceSamples.mainDiff])
    .frame(width: 520, height: 420)
}
