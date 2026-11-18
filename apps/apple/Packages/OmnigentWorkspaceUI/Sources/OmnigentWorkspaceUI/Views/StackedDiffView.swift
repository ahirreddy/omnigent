public import SwiftUI

/// Every file of a change set in one scroll, as a pull request's Files view shows it: a header
/// per file that collapses its diff, a menu that jumps to a file, and Collapse All. Views can sit
/// under lines and file headers (review conversations), and line numbers can choose lines.
public struct StackedDiffView: View {
  private let files: [FileDiff]
  private let annotations: StackedDiffAnnotations
  @State private var collapsed: Set<String> = []
  @State private var scroll: StackedDiffScroll?

  /// A stacked diff.
  /// - Parameters:
  ///   - files: The diffs, in patch order.
  ///   - annotations: What shows beside the lines.
  public init(files: [FileDiff], annotations: StackedDiffAnnotations = StackedDiffAnnotations()) {
    self.files = files
    self.annotations = annotations
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
    VStack(spacing: 0) {
      toolbar
      Divider()
      StackedDiffList(content: content, actions: actions)
    }
  }

  private var content: StackedDiffContent {
    var content = StackedDiffContent(files: files.map(StackedDiffFile.init(diff:)))
    content.annotations = annotations
    content.collapsed = collapsed
    content.scroll = scroll
    return content
  }

  private var actions: StackedDiffActions {
    var actions = StackedDiffActions()
    actions.toggle = { path in
      if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
    }
    return actions
  }

  private var toolbar: some View {
    HStack(spacing: 8) {
      Menu {
        ForEach(files, id: \.path) { file in
          Button(file.path) {
            collapsed.remove(file.path)
            scroll = StackedDiffScroll(token: (scroll?.token ?? 0) + 1, target: .file(file.path))
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
}

/// A file's header in the stacked diff: clicking it collapses or expands the file; controls
/// beside it act on the file.
struct StackedFileHeader: View {
  let file: StackedDiffFile
  let isCollapsed: Bool
  let accessory: AnyView?
  let toggle: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Button(action: toggle) {
        HStack(spacing: 6) {
          Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 12)
            .accessibilityHidden(true)
          Image(systemName: Self.symbol(file.kind))
            .font(.caption)
            .foregroundStyle(Self.color(file.kind))
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
          if file.added != nil || file.removed != nil {
            LineCounts(added: file.added, removed: file.removed)
          }
        }
        .padding(.leading, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(file.renamedFrom.map { "\($0) \u{2192} \(file.path)" } ?? file.path)
      .accessibilityLabel("\(file.path), \(isCollapsed ? "collapsed" : "expanded")")
      .accessibilityHint("Shows or hides this file's changes")
      if let accessory { accessory }
    }
    .padding(.trailing, 10)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var subtitle: String {
    if let previous = file.renamedFrom { return "\(previous) \u{2192} \(file.path)" }
    switch file.kind {
    case .added: return "new file"
    case .deleted: return "deleted"
    case .renamed, .modified: return WorkspacePaths.directory(of: file.path)
    }
  }

  /// A file glyph carrying the change, as the web's status icons.
  static func symbol(_ kind: ChangedFileKind) -> String {
    switch kind {
    case .added: "doc.badge.plus"
    case .modified: "doc.badge.ellipsis"
    case .deleted: "doc.badge.minus"
    case .renamed: "arrow.right.doc.on.clipboard"
    }
  }

  /// The glyph's color: green added, amber modified, red deleted, blue renamed.
  static func color(_ kind: ChangedFileKind) -> Color {
    switch kind {
    case .added: .green
    case .modified: .orange
    case .deleted: .red
    case .renamed: .blue
    }
  }
}

#Preview("Stacked diff") {
  StackedDiffView(files: [WorkspaceSamples.mainDiff, WorkspaceSamples.mainDiff])
    .frame(width: 520, height: 420)
}
