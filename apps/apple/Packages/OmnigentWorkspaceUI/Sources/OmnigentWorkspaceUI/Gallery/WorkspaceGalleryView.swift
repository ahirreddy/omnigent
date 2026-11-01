public import SwiftUI

/// A page of the workspace gallery.
nonisolated public enum WorkspaceGalleryPage: String, Hashable, Sendable, CaseIterable,
  Identifiable
{
  /// The browser: document beside the inspector panel.
  case browser
  /// The file tree with a directory expanded.
  case tree
  /// Text, clipped, image and binary files.
  case viewer
  /// Content search results and failures.
  case search
  /// The changed-files list.
  case changes
  /// Unified, side-by-side and special-case diffs.
  case diff

  /// The page title.
  public var title: String {
    switch self {
    case .browser: "Browser"
    case .tree: "File Tree"
    case .viewer: "File Viewer"
    case .search: "Content Search"
    case .changes: "Changed Files"
    case .diff: "Diffs"
    }
  }

  /// The raw value.
  public var id: String { rawValue }
}

/// Every workspace surface on sample data, for design review and screenshots.
public struct WorkspaceGalleryView: View {
  @State private var page: WorkspaceGalleryPage? = .browser

  /// The gallery.
  public init() {
    // The gallery has no inputs.
  }

  /// The view.
  public var body: some View {
    NavigationSplitView {
      List(WorkspaceGalleryPage.allCases, selection: $page) { page in
        Text(page.title).tag(page)
      }
      .navigationTitle("Workspace")
    } detail: {
      if let page {
        WorkspaceGalleryPageView(page: page)
          .navigationTitle(page.title)
      }
    }
  }
}

/// One gallery page, on its own sample models.
public struct WorkspaceGalleryPageView: View {
  private let page: WorkspaceGalleryPage
  @State private var browser = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
  @State private var tree = FileTreeModel(source: SampleWorkspaceDataSource())
  @State private var changes = ChangesModel(source: SampleWorkspaceDataSource())
  @State private var search = WorkspaceSamples.searchedModel()

  /// A page.
  /// - Parameter page: The page.
  public init(page: WorkspaceGalleryPage) {
    self.page = page
  }

  /// The view.
  public var body: some View {
    let source = SampleWorkspaceDataSource()
    switch page {
    case .browser:
      WorkspaceBrowserView(model: browser)
        .task { await WorkspaceGallery.prepare(browser) }
    case .tree:
      FileTreeView(model: tree, source: source, actions: .none)
        .frame(maxWidth: 360)
        .task { await WorkspaceGallery.prepare(tree) }
    case .viewer:
      VStack(spacing: 12) {
        HStack(spacing: 12) {
          FileViewerView(file: WorkspaceSamples.libFile, line: 7, source: source).galleryCard()
          FileViewerView(file: WorkspaceSamples.logoFile, source: source).galleryCard()
        }
        HStack(spacing: 12) {
          FileViewerView(file: WorkspaceSamples.generatedFile, source: source).galleryCard()
          FileViewerView(file: WorkspaceSamples.binaryFile, source: source).galleryCard()
        }
      }
      .padding(12)
    case .search:
      HStack(spacing: 12) {
        ContentSearchPanel(model: search, source: source, actions: .none) { _ in }
          .frame(width: 360)
          .galleryCard()
        FailureView(
          failure: WorkspaceFailure(
            .searchFailed,
            message: "regex parse error:\n    (unclosed\n    ^\nerror: unclosed group")
        )
        .galleryCard()
      }
      .padding(12)
    case .changes:
      ChangedFilesList(model: changes, source: source, actions: .none) { _ in }
        .frame(maxWidth: 360)
    case .diff:
      VStack(spacing: 12) {
        DiffViewerView(diff: WorkspaceSamples.libDiff, mode: .split, source: source).galleryCard()
        HStack(spacing: 12) {
          DiffViewerView(diff: WorkspaceSamples.mainDiff, mode: .unified, source: source)
            .galleryCard()
          DiffViewerView(diff: WorkspaceSamples.tooLargeDiff, source: source).galleryCard()
        }
      }
      .padding(12)
    }
  }
}

/// Loads sample models into the states the gallery shows.
public enum WorkspaceGallery {
  /// Loads the root and expands `src`.
  /// - Parameter tree: The tree.
  public static func prepare(_ tree: FileTreeModel) async {
    await tree.loadRoot()
    await tree.expand("src")
    await tree.expand("src/util")
    tree.selection = "src/main.rs"
  }

  /// Prepares the tree and opens the `src/lib.rs` diff.
  /// - Parameter browser: The browser.
  public static func prepare(_ browser: WorkspaceBrowserModel) async {
    await prepare(browser.tree)
    await browser.changes.reload()
    browser.tab = .files
    await browser.open(.diff(path: "src/lib.rs"))
  }
}

extension View {
  fileprivate func galleryCard() -> some View {
    background(.background, in: .rect(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
      .clipShape(.rect(cornerRadius: 8))
  }
}

#Preview("Workspace gallery") {
  WorkspaceGalleryView()
    .frame(width: 1_200, height: 760)
}
