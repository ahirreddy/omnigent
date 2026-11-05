import OmnigentWorkspaceUI
import SwiftUI

/// Workspace files: the file viewer's review and edit modes, and the Files tab's search.
enum WorkspaceFilesCatalog {
  static var entries: [CatalogEntry] {
    [
      .component(
        .inspector, "workspace-files", "File Viewer and Editor",
        summary: "Comments on lines, the editor's save states and conflicts, and file search.",
        systemImage: "doc.text", canvas: .fixed(width: 720, height: 460),
        keywords: ["files", "edit", "save", "comment", "search", "sort"],
        states: [
          CatalogState("review", "Review") { WorkspaceFileSample(stage: .review) },
          CatalogState("edit", "Unsaved edit") { WorkspaceFileSample(stage: .edit) },
          CatalogState("conflict", "Conflict") { WorkspaceFileSample(stage: .conflict) },
          CatalogState("search", "File search") { WorkspaceFileSample(stage: .search) },
        ])
    ]
  }
}

/// One stage of the sample workspace, prepared on appear.
private struct WorkspaceFileSample: View {
  enum Stage { case review, edit, conflict, search }

  let stage: Stage
  @State private var source = SampleWorkspaceDataSource()
  @State private var browser: WorkspaceBrowserModel?

  var body: some View {
    Group {
      if let browser {
        if stage == .search {
          FileTreeView(model: browser.tree, source: source, actions: .none)
            .frame(width: 340)
        } else {
          WorkspaceDocumentView(model: browser, actions: actions)
        }
      } else {
        ProgressView()
      }
    }
    .defaultAppStorage(defaults)
    .task { await prepare() }
  }

  private var actions: WorkspaceActions {
    var actions = WorkspaceActions(mention: { _ in })
    actions.ask = { _ in }
    actions.canEdit = true
    return actions
  }

  /// The view mode the stage opens in, kept apart from the app's own setting.
  private var defaults: UserDefaults {
    let defaults = UserDefaults(suiteName: "gallery.workspace-files") ?? .standard
    defaults.set(stage == .review ? "source" : "edit", forKey: "workspace.fileViewMode")
    return defaults
  }

  private func prepare() async {
    let browser = WorkspaceBrowserModel(source: source)
    let path = WorkspaceSamples.mainFile.path
    if let span = FileTextSpan.line(2, in: WorkspaceSamples.mainText, path: path) {
      do {
        try await source.addComment("Should this print to stderr instead?", on: span)
      } catch {
        assertionFailure("The sample source does not fail comments: \(error)")
      }
    }
    await browser.open(.file(path: path, line: nil))
    let editor = browser.editors[path]
    editor?.autosaveDelay = nil
    switch stage {
    case .review:
      break
    case .edit:
      editor?.text = WorkspaceSamples.mainText + "\n// TODO: handle --verbose\n"
    case .conflict:
      editor?.text = WorkspaceSamples.mainText + "\n// mine\n"
      editor?.serverChanged(WorkspaceSamples.mainText + "\n// the agent's change\n")
    case .search:
      await browser.tree.loadRoot()
      browser.tree.sort = .size
      browser.tree.filter = ".rs"
      await browser.tree.searchNow()
    }
    self.browser = browser
  }
}
