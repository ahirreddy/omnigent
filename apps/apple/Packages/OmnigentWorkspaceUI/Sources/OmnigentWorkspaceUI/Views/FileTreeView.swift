public import SwiftUI

/// The lazily loaded file tree. Directories read their first page when expanded; long
/// directories end in a "Load more" row. Keyboard: up and down select, right expands or steps
/// in, left collapses or steps out, return opens, and the context menu copies or reveals paths.
public struct FileTreeView: View {
  @Bindable private var model: FileTreeModel
  private let source: any WorkspaceDataSource
  private let actions: WorkspaceActions
  @FocusState private var focused: Bool

  /// A tree.
  /// - Parameters:
  ///   - model: The tree state.
  ///   - source: Used for absolute paths in the context menu.
  ///   - actions: Host hooks for reveal, open and mention.
  public init(model: FileTreeModel, source: any WorkspaceDataSource, actions: WorkspaceActions) {
    self.model = model
    self.source = source
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    Group {
      if let failure = model.rootFailure {
        FailureView(failure: failure) { Task { await model.retry("") } }
      } else {
        rows
      }
    }
    .task { await model.loadRoot() }
  }

  private var rows: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(model.rows) { row in
            FileTreeRow(
              row: row, isSelected: row.id == model.selection,
              onToggle: { path in Task { await model.toggle(path) } },
              onLoadMore: { directory in Task { await model.loadMore(directory) } },
              onRetry: { directory in Task { await model.retry(directory) } }
            )
            .id(row.id)
            .contentShape(.rect)
            .accessibilityAddTraits(.isButton)
            .onTapGesture(count: 2) {
              guard let entry = row.entry else { return }
              model.selection = entry.path
              Task { await model.activateSelection() }
            }
            .onTapGesture {
              guard let entry = row.entry else { return }
              model.selection = entry.path
              focused = true
            }
            .contextMenu {
              if let entry = row.entry {
                PathMenu(path: entry.path, source: source, actions: actions)
              }
            }
          }
        }
        .padding(.vertical, 4)
      }
      .focusable()
      .focused($focused)
      .focusEffectDisabled()
      .onKeyPress(.upArrow) {
        model.moveSelection(by: -1)
        return .handled
      }
      .onKeyPress(.downArrow) {
        model.moveSelection(by: 1)
        return .handled
      }
      .onKeyPress(.rightArrow) {
        Task { await model.stepIn() }
        return .handled
      }
      .onKeyPress(.leftArrow) {
        model.stepOut()
        return .handled
      }
      .onKeyPress(.return) {
        Task { await model.activateSelection() }
        return .handled
      }
      .onChange(of: model.selection) { _, selection in
        guard let selection else { return }
        proxy.scrollTo(selection)
      }
      .accessibilityIdentifier("workspace.tree")
    }
  }
}

private struct FileTreeRow: View {
  let row: FileTreeModel.Row
  let isSelected: Bool
  let onToggle: (String) -> Void
  let onLoadMore: (String) -> Void
  let onRetry: (String) -> Void

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 4) {
      content
      Spacer(minLength: 0)
    }
    .padding(.leading, CGFloat(row.depth) * 14 + 6)
    .padding(.trailing, 8)
    .frame(height: 22)
    .background(isSelected ? Color.accentColor.opacity(0.22) : .clear, in: .rect(cornerRadius: 4))
    .padding(.horizontal, 4)
  }

  @ViewBuilder private var content: some View {
    switch row.content {
    case .entry(let entry, let isExpanded):
      if entry.kind.isDirectory {
        Button {
          onToggle(entry.path)
        } label: {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(isExpanded ? "Collapse \(entry.name)" : "Expand \(entry.name)")
      } else {
        Color.clear.frame(width: 12)
      }
      Image(systemName: icon(for: entry, isExpanded: isExpanded))
        .foregroundStyle(entry.kind.isDirectory ? Color.accentColor : .secondary)
        .frame(width: 16)
        .accessibilityHidden(true)
      Text(entry.name)
        .lineLimit(1)
        .truncationMode(.middle)
        .font(.system(size: 12))
      if let size = entry.size, !entry.kind.isDirectory {
        Spacer(minLength: 6)
        Text(size.formatted(.byteCount(style: .file)))
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
      }
    case .loading:
      ProgressView()
        .controlSize(.small)
      Text("Loading")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .loadMore:
      Button("Load more") { onLoadMore(row.directory) }
        .buttonStyle(.borderless)
        .font(.caption)
    case .empty:
      Text("Empty folder")
        .font(.caption)
        .foregroundStyle(.tertiary)
    case .failure(let failure):
      InlineFailure(failure: failure) { onRetry(row.directory) }
    }
  }

  private func icon(for entry: WorkspaceEntry, isExpanded: Bool) -> String {
    switch entry.kind {
    case .directory: isExpanded ? "folder.fill" : "folder"
    case .symlink: "arrow.triangle.turn.up.right.diamond"
    case .other, .unknown: "questionmark.square.dashed"
    case .file: FileIcons.symbol(forName: entry.name)
    }
  }
}

/// SF Symbols for file names, display only.
enum FileIcons {
  static func symbol(forName name: String) -> String {
    let lower = name.lowercased()
    let ext = lower.split(separator: ".").last.map(String.init) ?? ""
    switch ext {
    case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico", "svg": return "photo"
    case "md", "markdown", "txt", "rst": return "doc.text"
    case "json", "yaml", "yml", "toml", "plist", "xml": return "curlybraces"
    case "zip", "gz", "tar", "tgz", "xz": return "doc.zipper"
    case "pdf": return "doc.richtext"
    default: return "chevron.left.forwardslash.chevron.right"
    }
  }
}

#Preview("File tree") {
  @Previewable @State var model = FileTreeModel(source: SampleWorkspaceDataSource())
  FileTreeView(model: model, source: SampleWorkspaceDataSource(), actions: .none)
    .frame(width: 300, height: 480)
}
