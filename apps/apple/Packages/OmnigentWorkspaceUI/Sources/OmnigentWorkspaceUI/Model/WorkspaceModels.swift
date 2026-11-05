import Foundation
public import Observation

/// Content search: the query being edited, and the last search's results. Editing the query
/// does not clear the results; they stay labeled with the query that produced them until the
/// next search finishes, as in the web panel.
@Observable
public final class ContentSearchModel {
  private let source: any WorkspaceDataSource
  private var generation = 0

  /// The query being edited.
  public var query = ContentSearchQuery()
  /// Whether the include and exclude fields are shown.
  public var showsFilters = false
  /// The last search.
  public private(set) var state: LoadState<ContentSearchResult> = .idle
  /// The query that produced `state`.
  public private(set) var searchedQuery: ContentSearchQuery?
  /// The selected match id.
  public var selection: String?

  /// A search model over `source`.
  /// - Parameter source: Where results come from.
  public init(source: any WorkspaceDataSource) {
    self.source = source
  }

  /// Runs the current query. A search started later wins over one still in flight.
  public func search() async {
    guard query.isSubmittable else { return }
    generation += 1
    let current = generation
    let submitted = query
    state = .loading
    searchedQuery = submitted
    let result: LoadState<ContentSearchResult>
    do {
      result = .loaded(try await source.searchContent(submitted))
    } catch {
      result = .failed(error)
    }
    guard current == generation else { return }
    state = result
    selection = result.value?.files.first?.matches.first?.id
  }

  /// Shows `result` as the last search of the current query, for previews and restored state.
  /// - Parameter result: The result to show.
  public func restore(_ result: ContentSearchResult) {
    generation += 1
    state = .loaded(result)
    searchedQuery = query
    selection = result.files.first?.matches.first?.id
  }

  /// All matches in display order, for keyboard navigation.
  public var matches: [ContentMatch] { state.value?.files.flatMap(\.matches) ?? [] }

  /// Moves the selection `offset` matches, clamped to the ends.
  /// - Parameter offset: Positive moves down.
  public func moveSelection(by offset: Int) {
    let all = matches
    guard !all.isEmpty else { return }
    guard let selection, let index = all.firstIndex(where: { $0.id == selection }) else {
      self.selection = all.first?.id
      return
    }
    self.selection = all[min(max(index + offset, 0), all.count - 1)].id
  }
}

/// The changed-files list.
@Observable
public final class ChangesModel {
  private let source: any WorkspaceDataSource
  private var generation = 0

  /// The list.
  public private(set) var state: LoadState<ChangesList> = .idle
  /// The selected path.
  public var selection: String?

  /// A list over `source`.
  /// - Parameter source: Where changes come from.
  public init(source: any WorkspaceDataSource) {
    self.source = source
  }

  /// Reads the list, keeping the previous one on screen while it loads.
  public func reload() async {
    generation += 1
    let current = generation
    if state.value == nil { state = .loading }
    let result: LoadState<ChangesList>
    do {
      result = .loaded(try await source.changes())
    } catch {
      result = .failed(error)
    }
    guard current == generation else { return }
    state = result
    if let selection, result.value?.files.contains(where: { $0.path == selection }) != true {
      self.selection = nil
    }
  }

  /// Moves the selection `offset` files, clamped to the ends.
  /// - Parameter offset: Positive moves down.
  public func moveSelection(by offset: Int) {
    let files = state.value?.files ?? []
    guard !files.isEmpty else { return }
    guard let selection, let index = files.firstIndex(where: { $0.path == selection }) else {
      self.selection = files.first?.path
      return
    }
    self.selection = files[min(max(index + offset, 0), files.count - 1)].path
  }
}

/// What the document area shows.
nonisolated public enum WorkspaceDocument: Hashable, Sendable {
  /// A file, optionally scrolled to a 1-based line.
  case file(path: String, line: UInt64?)
  /// A changed file's diff.
  case diff(path: String)

  /// The document's path.
  public var path: String {
    switch self {
    case .file(let path, _), .diff(let path): path
    }
  }

  /// Identifies the document's tab: one tab per file and one per diff, whatever the line.
  public var tabID: String {
    switch self {
    case .file(let path, _): "file:\(path)"
    case .diff(let path): "diff:\(path)"
    }
  }
}

/// The panels a workspace inspector offers.
nonisolated public enum WorkspaceTab: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// The file tree.
  case files
  /// Content search.
  case search
  /// Changed files.
  case changes

  /// The tab title.
  public var title: String {
    switch self {
    case .files: "Files"
    case .search: "Search"
    case .changes: "Changes"
    }
  }

  /// The tab symbol.
  public var symbol: String {
    switch self {
    case .files: "folder"
    case .search: "magnifyingglass"
    case .changes: "plusminus"
    }
  }

  /// The raw value.
  public var id: String { rawValue }
}

/// One session environment's workspace: the tree, search, changes and the open document.
@Observable
public final class WorkspaceBrowserModel {
  /// Where everything is read from.
  public let source: any WorkspaceDataSource
  /// The file tree.
  public let tree: FileTreeModel
  /// Content search.
  public let search: ContentSearchModel
  /// Changed files.
  public let changes: ChangesModel
  /// The selected inspector tab.
  public var tab: WorkspaceTab = .files
  /// The shown document; `nil` shows the panel.
  public private(set) var document: WorkspaceDocument?
  /// The documents open as tabs, in the order they opened.
  public private(set) var openDocuments: [WorkspaceDocument] = []
  /// The open file, when `document` is a file.
  public private(set) var file: LoadState<WorkspaceFile> = .idle
  /// The open diff, when `document` is a diff.
  public private(set) var diff: LoadState<FileDiff> = .idle
  private var generation = 0

  /// A browser over `source`.
  /// - Parameter source: Where everything is read from.
  public init(source: any WorkspaceDataSource) {
    self.source = source
    tree = FileTreeModel(source: source)
    search = ContentSearchModel(source: source)
    changes = ChangesModel(source: source)
    tree.onOpen = { [weak self] entry in
      Task { await self?.open(.file(path: entry.path, line: nil)) }
    }
  }

  /// Opens `document` as a tab (or in its existing tab) and shows it, reading it.
  /// - Parameter document: The file or diff.
  public func open(_ document: WorkspaceDocument) async {
    generation += 1
    let current = generation
    if let index = openDocuments.firstIndex(where: { $0.tabID == document.tabID }) {
      openDocuments[index] = document
    } else {
      openDocuments.append(document)
    }
    self.document = document
    switch document {
    case .file(let path, _):
      diff = .idle
      file = .loading
      let result: LoadState<WorkspaceFile>
      do {
        result = .loaded(try await source.readFile(path))
      } catch {
        result = .failed(error)
      }
      if current == generation { file = result }
    case .diff(let path):
      file = .idle
      diff = .loading
      let result: LoadState<FileDiff>
      do {
        result = .loaded(try await source.diff(path))
      } catch {
        result = .failed(error)
      }
      if current == generation { diff = result }
    }
  }

  /// Marks `line` in the shown file without reading it again (a file comment's position, once
  /// the file's text is known).
  /// - Parameter line: A 1-based line.
  public func reveal(line: UInt64) {
    guard case .file(let path, let shown) = document, shown != line else { return }
    let revealed = WorkspaceDocument.file(path: path, line: line)
    if let index = openDocuments.firstIndex(where: { $0.tabID == revealed.tabID }) {
      openDocuments[index] = revealed
    }
    document = revealed
  }

  /// Closes the shown document's tab and shows the panel.
  public func close() {
    if let document { openDocuments.removeAll { $0.tabID == document.tabID } }
    hideDocument()
  }

  /// Closes `document`'s tab. When it was shown, the tab after it (else the last) shows, or
  /// the panel when no tab is left.
  /// - Parameter document: The document.
  public func close(_ document: WorkspaceDocument) async {
    guard let index = openDocuments.firstIndex(where: { $0.tabID == document.tabID }) else {
      return
    }
    openDocuments.remove(at: index)
    guard self.document?.tabID == document.tabID else { return }
    if let next = openDocuments.indices.contains(index) ? openDocuments[index] : openDocuments.last
    {
      await open(next)
    } else {
      hideDocument()
    }
  }

  /// Shows the panel, keeping the open tabs.
  public func hideDocument() {
    generation += 1
    document = nil
    file = .idle
    diff = .idle
  }

  /// Handles `session.changed_files.invalidated`: reloads changes and the tree, and the open
  /// document when it may have changed.
  public func changedFilesInvalidated() async {
    await changes.reload()
    await tree.refresh()
    if let document { await open(document) }
  }
}
