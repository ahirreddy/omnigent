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
    VStack(spacing: 0) {
      FileTreeToolbar(model: model, source: source, actions: actions)
      Divider()
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
            .accessibilityIdentifier(
              row.entry.map { "workspace.tree.row.\($0.path)" } ?? "",
              isEnabled: row.entry != nil
            )
            .onTapGesture {
              guard let entry = row.entry else { return }
              model.selection = entry.path
              focused = true
              Task { await model.activateSelection() }
            }
            .contextMenu {
              if let entry = row.entry {
                PathMenu(
                  path: entry.path, source: source, actions: actions,
                  isFile: !entry.kind.isDirectory)
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

/// The tree's header, as the web's Files panel: a workspace-wide file search with include and
/// exclude globs, the sort order, show hidden files, refresh, and the working folder's path
/// actions.
private struct FileTreeToolbar: View {
  @Bindable var model: FileTreeModel
  let source: any WorkspaceDataSource
  let actions: WorkspaceActions
  @State private var isRefreshing = false

  var body: some View {
    VStack(spacing: 4) {
      buttons
      if model.showsSearchFilters {
        TextField("Files to include, e.g. src/**, *.ts", text: $model.include)
          .accessibilityIdentifier("workspace.tree.include")
        TextField("Files to exclude, e.g. **/test/**", text: $model.exclude)
          .accessibilityIdentifier("workspace.tree.exclude")
      }
    }
    .textFieldStyle(.roundedBorder)
    .controlSize(.small)
    .autocorrectionDisabled()
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
  }

  private var buttons: some View {
    HStack(spacing: 4) {
      TextField("Find files by name", text: $model.filter)
        .onSubmit { Task { await model.searchNow() } }
        .accessibilityIdentifier("workspace.tree.filter")
      Button {
        model.showsSearchFilters.toggle()
      } label: {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .symbolVariant(model.showsSearchFilters ? .fill : .none)
      }
      .help(model.showsSearchFilters ? "Hide search filters" : "Show search filters")
      .accessibilityLabel("Search filters")
      .accessibilityIdentifier("workspace.tree.searchFilters")
      Menu {
        Picker("Sort Files", selection: $model.sort) {
          ForEach(FileTreeSort.allCases) { sort in
            Label(sort.title, systemImage: sort.symbol).tag(sort)
          }
        }
        .pickerStyle(.inline)
      } label: {
        Image(systemName: "arrow.up.arrow.down")
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Sort files: \(model.sort.title)")
      .accessibilityLabel("Sort files: \(model.sort.title)")
      .accessibilityIdentifier("workspace.tree.sort")
      Button {
        model.showsHidden.toggle()
      } label: {
        Image(systemName: model.showsHidden ? "eye.slash" : "eye")
      }
      .help(model.showsHidden ? "Hide hidden files" : "Show hidden files")
      .accessibilityLabel(model.showsHidden ? "Hide hidden files" : "Show hidden files")
      .accessibilityIdentifier("workspace.tree.hidden")
      Button {
        isRefreshing = true
        Task {
          await model.refresh()
          isRefreshing = false
        }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .disabled(isRefreshing)
      .help("Refresh files")
      .accessibilityLabel("Refresh files")
      .accessibilityIdentifier("workspace.tree.refresh")
      if let root = source.absoluteLocation(of: "") {
        Menu {
          Button("Copy Folder Path") { WorkspacePlatform.copy(root) }
          if let reveal = actions.reveal {
            Button("Reveal in \(WorkspacePlatform.fileManagerName)") { reveal(root) }
          }
          if let open = actions.openExternally {
            Button("Open in Editor") { open(root) }
          }
        } label: {
          Image(systemName: "folder")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(root)
        .accessibilityLabel("Folder actions")
        .accessibilityIdentifier("workspace.tree.folder")
      }
    }
    .buttonStyle(.borderless)
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
      // One flexible gap, so every size ends on the row's right edge whatever the name's length.
      if case .entry(let entry, _) = row.content, let size = entry.size, !entry.kind.isDirectory {
        Text(size.formatted(.byteCount(style: .file)))
          .font(.system(size: 10))
          .monospacedDigit()
          .foregroundStyle(.tertiary)
          .fixedSize()
          .padding(.leading, 2)
      }
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
    case .match(let entry):
      Color.clear.frame(width: 12)
      Image(systemName: icon(for: entry, isExpanded: false))
        .foregroundStyle(entry.kind.isDirectory ? Color.accentColor : .secondary)
        .frame(width: 16)
        .accessibilityHidden(true)
      Text(entry.name)
        .lineLimit(1)
        .font(.system(size: 12))
        .layoutPriority(1)
      Text(row.directory)
        .lineLimit(1)
        .truncationMode(.head)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    case .note(let text):
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
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
public enum FileIcons {
  /// The symbol for a file called `name`.
  /// - Parameter name: The file name.
  /// - Returns: An SF Symbol name.
  public static func symbol(forName name: String) -> String {
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
