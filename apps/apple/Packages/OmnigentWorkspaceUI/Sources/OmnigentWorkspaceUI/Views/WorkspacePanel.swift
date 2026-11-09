public import SwiftUI

/// The inspector panel: Files, Search and Changes tabs in a column narrow enough for an
/// inspector (about 280 to 360 points). Opening something sets the browser's document, which
/// `WorkspaceDocumentView` shows.
public struct WorkspacePanel: View {
  @Bindable private var model: WorkspaceBrowserModel
  private let actions: WorkspaceActions

  /// A panel.
  /// - Parameters:
  ///   - model: The browser state.
  ///   - actions: Host hooks.
  public init(model: WorkspaceBrowserModel, actions: WorkspaceActions = .none) {
    self.model = model
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    VStack(spacing: 0) {
      Picker("Panel", selection: $model.tab) {
        ForEach(WorkspaceTab.allCases) { tab in
          Label(tab.title, systemImage: tab.symbol).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(8)
      Divider()
      switch model.tab {
      case .files:
        FileTreeView(model: model.tree, source: model.source, actions: actions)
      case .search:
        ContentSearchPanel(model: model.search, source: model.source, actions: actions) { match in
          Task { await model.open(.file(path: match.path, line: match.line)) }
        }
      case .changes:
        ChangedFilesList(model: model.changes, source: model.source, actions: actions) { file in
          Task { await model.open(.diff(path: file.path)) }
        }
      }
    }
    .background(alignment: .topLeading) { shortcuts }
  }

  /// Command-Shift-F opens Search, as in the web app; Command-1 to 3 pick tabs.
  private var shortcuts: some View {
    Group {
      Button("Search File Contents") { model.tab = .search }
        .keyboardShortcut("f", modifiers: [.command, .shift])
      ForEach(Array(WorkspaceTab.allCases.enumerated()), id: \.element) { index, tab in
        Button(tab.title) { model.tab = tab }
          .keyboardShortcut(
            KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
      }
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }
}

/// The open document: a file viewer or a diff viewer, with loading and failure states.
public struct WorkspaceDocumentView: View {
  private let model: WorkspaceBrowserModel
  private let actions: WorkspaceActions

  /// A document view.
  /// - Parameters:
  ///   - model: The browser state.
  ///   - actions: Host hooks.
  public init(model: WorkspaceBrowserModel, actions: WorkspaceActions = .none) {
    self.model = model
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    document
      .alert(
        closeTitle, isPresented: closeConfirmation, presenting: model.pendingClose
      ) { document in
        Button("Save") { Task { await model.finishClose(of: document, saving: true) } }
        Button("Don't Save", role: .destructive) {
          Task { await model.finishClose(of: document, saving: false) }
        }
        Button("Cancel", role: .cancel) { model.pendingClose = nil }
      } message: { _ in
        Text("Your changes will be lost if you don't save them.")
      }
  }

  private var closeTitle: String {
    "Save changes to \(model.pendingClose.map { WorkspacePaths.name(of: $0.path) } ?? "the file")?"
  }

  private var closeConfirmation: Binding<Bool> {
    Binding(
      get: { model.pendingClose != nil },
      set: { presented in if !presented, model.pendingClose != nil { model.pendingClose = nil } })
  }

  @ViewBuilder private var document: some View {
    switch model.document {
    case nil:
      ContentUnavailableView(
        "No File Selected", systemImage: "doc.text.magnifyingglass",
        description: Text("Choose a file, a search result or a changed file."))
    case .file(_, let line):
      switch model.file {
      case .idle, .loading:
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let failure):
        FailureView(failure: failure) { reopen() }
      case .loaded(let file):
        FileViewerView(
          file: file, line: line, source: model.source, actions: actions,
          editor: actions.canEdit ? model.editors[file.path] : nil, review: review(for: file))
      }
    case .diff:
      switch model.diff {
      case .idle, .loading:
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let failure):
        FailureView(failure: failure) { reopen() }
      case .loaded(let diff):
        DiffViewerView(diff: diff, source: model.source, actions: actions)
          .id(diff.path)
      }
    }
  }

  private func reopen() {
    guard let document = model.document else { return }
    Task { await model.open(document) }
  }

  /// Comments, and handing spans to the agent through the host's hooks.
  private func review(for file: WorkspaceFile) -> FileReviewContext? {
    guard actions.canEdit || actions.mention != nil || actions.ask != nil else { return nil }
    let model = model
    let mention = actions.mention
    let ask = actions.ask
    let path = file.path
    var review = FileReviewContext(
      comments: model.comments[file.path]?.value ?? [], canComment: actions.canEdit,
      add: { body, span throws(WorkspaceFailure) in try await model.addComment(body, on: span) },
      reveal: { line in model.reveal(line: line) },
      attach: mention.map { mention in { span in mention(span.reference) } },
      ask: ask)
    guard actions.canEdit else { return review }
    review.update = { comment, body, open throws(WorkspaceFailure) in
      try await model.updateComment(comment.id, on: path, body: body, open: open)
    }
    review.delete = { comment throws(WorkspaceFailure) in
      try await model.deleteComment(comment.id, on: path)
    }
    review.sendAll = { () throws(WorkspaceFailure) in try await model.sendOpenComments(on: path) }
    return review
  }
}

/// The whole browser: the document beside the panel, as an inspector would place it on a Mac.
/// On a compact width the panel fills the screen and the document is pushed on top.
public struct WorkspaceBrowserView: View {
  private let model: WorkspaceBrowserModel
  private let actions: WorkspaceActions
  @Environment(\.horizontalSizeClass) private var sizeClass

  /// A browser.
  /// - Parameters:
  ///   - model: The browser state.
  ///   - actions: Host hooks.
  public init(model: WorkspaceBrowserModel, actions: WorkspaceActions = .none) {
    self.model = model
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    if sizeClass == .compact {
      NavigationStack {
        WorkspacePanel(model: model, actions: actions)
          .navigationDestination(isPresented: documentPresented) {
            WorkspaceDocumentView(model: model, actions: actions)
          }
      }
    } else {
      HStack(spacing: 0) {
        WorkspaceDocumentView(model: model, actions: actions)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        WorkspacePanel(model: model, actions: actions)
          .frame(width: 320)
      }
    }
  }

  private var documentPresented: Binding<Bool> {
    Binding(
      get: { model.document != nil },
      set: { presented in if !presented { model.close() } })
  }
}

#Preview("Workspace browser") {
  @Previewable @State var model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
  WorkspaceBrowserView(model: model)
    .frame(width: 1_100, height: 640)
}
