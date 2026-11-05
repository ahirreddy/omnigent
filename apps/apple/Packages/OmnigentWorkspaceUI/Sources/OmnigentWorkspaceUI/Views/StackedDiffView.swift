public import SwiftUI

/// Every file of a change set in one scroll, as a pull request's Files view shows it: a header
/// per file that collapses its diff, a menu that jumps to a file, and Collapse All.
public struct StackedDiffView: View {
  private let files: [FileDiff]
  @State private var collapsed: Set<String> = []

  /// A stacked diff.
  /// - Parameter files: The diffs, in patch order.
  public init(files: [FileDiff]) {
    self.files = files
  }

  private enum Row {
    case file(FileDiff)
    case notice(path: String, text: String)
    case hunk(path: String, index: Int, header: String)
    case line(DiffLine)
  }

  /// One flat list, so the lazy stack sizes and recycles rows reliably in both scroll axes.
  private var rows: [Row] {
    files.flatMap { file -> [Row] in
      guard !collapsed.contains(file.path) else { return [.file(file)] }
      if file.binary { return [.file(file), .notice(path: file.path, text: "Binary file")] }
      if file.tooLarge {
        return [.file(file), .notice(path: file.path, text: "This change is too large to show.")]
      }
      return [.file(file)]
        + file.hunks.enumerated().flatMap { index, hunk in
          [Row.hunk(path: file.path, index: index, header: hunk.header)] + hunk.lines.map(Row.line)
        }
    }
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
    case .line(let line):
      UnifiedLineRow(line: line, compactGutter: DiffGutter.isCompact(width))
    }
  }

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
        Image(systemName: allCollapsed ? "chevron.up.chevron.down" : "chevron.down.chevron.up")
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
