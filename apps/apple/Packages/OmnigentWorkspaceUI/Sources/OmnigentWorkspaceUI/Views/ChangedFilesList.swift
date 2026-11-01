public import SwiftUI

/// The session's changed files with their status and line counts. Selecting one opens its diff.
public struct ChangedFilesList: View {
  @Bindable private var model: ChangesModel
  private let source: any WorkspaceDataSource
  private let actions: WorkspaceActions
  private let onOpen: (ChangedFile) -> Void

  /// A list.
  /// - Parameters:
  ///   - model: The changes state.
  ///   - source: Used for absolute paths.
  ///   - actions: Host hooks.
  ///   - onOpen: Opens a file's diff.
  public init(
    model: ChangesModel, source: any WorkspaceDataSource, actions: WorkspaceActions,
    onOpen: @escaping (ChangedFile) -> Void
  ) {
    self.model = model
    self.source = source
    self.actions = actions
    self.onOpen = onOpen
  }

  /// The view.
  public var body: some View {
    content
      .task {
        if case .idle = model.state { await model.reload() }
      }
      .accessibilityIdentifier("workspace.changes")
  }

  @ViewBuilder private var content: some View {
    switch model.state {
    case .idle, .loading:
      ProgressView("Loading changes")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let failure):
      FailureView(failure: failure) { Task { await model.reload() } }
    case .loaded(let list):
      if list.files.isEmpty {
        ContentUnavailableView(
          "No Changes", systemImage: "checkmark.circle",
          description: Text("Files the agent creates, edits or deletes appear here."))
      } else {
        VStack(spacing: 0) {
          ChangeSummary(totals: list.totals)
          Divider()
          List(list.files, selection: $model.selection) { file in
            ChangedFileRow(file: file)
              .tag(file.path)
              .contextMenu { PathMenu(path: file.path, source: source, actions: actions) }
          }
          .listStyle(.plain)
          .onChange(of: model.selection) { _, selection in
            if let file = list.files.first(where: { $0.path == selection }) { onOpen(file) }
          }
          if list.hasMore {
            NoticeBar(symbol: "ellipsis", text: "The server listed the first \(list.files.count).")
          }
        }
      }
    }
  }
}

private struct ChangeSummary: View {
  let totals: ChangeTotals

  var body: some View {
    HStack(spacing: 10) {
      Text("\(totals.files) changed")
        .font(.system(size: 12, weight: .semibold))
      if totals.created > 0 { Label("\(totals.created)", systemImage: "plus.square") }
      if totals.modified > 0 { Label("\(totals.modified)", systemImage: "pencil.line") }
      if totals.deleted > 0 { Label("\(totals.deleted)", systemImage: "minus.square") }
      Spacer(minLength: 0)
      LineCounts(added: totals.linesAdded, removed: totals.linesRemoved)
    }
    .labelStyle(.titleAndIcon)
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }
}

private struct ChangedFileRow: View {
  let file: ChangedFile

  var body: some View {
    HStack(spacing: 8) {
      ChangeBadge(status: file.status)
      VStack(alignment: .leading, spacing: 0) {
        Text(WorkspacePaths.name(of: file.path))
          .font(.system(size: 12))
          .strikethrough(file.status == .deleted)
          .lineLimit(1)
        let directory = WorkspacePaths.directory(of: file.path)
        if !directory.isEmpty {
          Text(directory)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
      }
      Spacer(minLength: 4)
      LineCounts(added: file.linesAdded, removed: file.linesRemoved)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(file.status.label) \(file.path)")
  }
}

#Preview("Changed files") {
  @Previewable @State var model = ChangesModel(source: SampleWorkspaceDataSource())
  ChangedFilesList(model: model, source: SampleWorkspaceDataSource(), actions: .none) { _ in }
    .frame(width: 320, height: 360)
}
