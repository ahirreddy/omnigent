import Foundation
public import Observation

/// The file tree: directories load lazily, one page at a time, when first expanded.
///
/// `rows` is the flattened visible tree (entries plus loading, "load more", empty and error
/// placeholders), recomputed after every change so a long tree scrolls without re-walking it.
/// Keyboard navigation works on `rows`: up and down move the selection, right expands or steps
/// into a directory, left collapses or steps out to the parent, return opens.
@Observable
public final class FileTreeModel {
  /// What a visible row shows.
  nonisolated public enum RowContent: Hashable, Sendable {
    /// A file or directory.
    case entry(WorkspaceEntry, isExpanded: Bool)
    /// The directory's first page is loading.
    case loading
    /// More entries can be loaded.
    case loadMore
    /// The directory is empty.
    case empty
    /// The directory could not be read.
    case failure(WorkspaceFailure)
  }

  /// One visible row.
  nonisolated public struct Row: Hashable, Sendable, Identifiable {
    /// Unique among rows: the entry path, or the directory path plus a placeholder suffix.
    public var id: String
    /// The directory the row belongs to.
    public var directory: String
    /// Indentation level; top-level entries are 0.
    public var depth: Int
    /// What it shows.
    public var content: RowContent

    /// The entry, for entry rows.
    public var entry: WorkspaceEntry? {
      if case .entry(let entry, _) = content { return entry }
      return nil
    }
  }

  private enum Listing {
    case loading
    case loaded
    case failed(WorkspaceFailure)
  }

  private let source: any WorkspaceDataSource
  private var children: [String: [WorkspaceEntry]] = [:]
  private var cursors: [String: String] = [:]
  private var listings: [String: Listing] = [:]
  private var loadingMore: Set<String> = []

  /// Expanded directories.
  public private(set) var expanded: Set<String> = []
  /// The visible rows, in order.
  public private(set) var rows: [Row] = []
  /// The selected entry path.
  public var selection: String?
  /// Called when a file is opened (return, double click).
  public var onOpen: ((WorkspaceEntry) -> Void)?
  /// Shows entries whose name starts with a dot; hidden by default, as the web.
  public var showsHidden = false {
    didSet { if showsHidden != oldValue { rebuild() } }
  }
  /// Keeps loaded entries whose name contains this text, and the folders leading to them.
  public var filter = "" {
    didSet { if filter != oldValue { rebuild() } }
  }

  /// A tree over `source`. Call `loadRoot()` to read the first page.
  /// - Parameter source: Where entries come from.
  public init(source: any WorkspaceDataSource) {
    self.source = source
    rebuild()
  }

  /// The root failure, when the root could not be read.
  public var rootFailure: WorkspaceFailure? {
    if case .failed(let failure) = listings[""] { return failure }
    return nil
  }

  /// The selected entry.
  public var selectedEntry: WorkspaceEntry? {
    guard let selection else { return nil }
    return rows.first { $0.id == selection }?.entry
  }

  /// Reads the root's first page, once.
  public func loadRoot() async {
    guard listings[""] == nil else { return }
    await load("", after: nil)
  }

  /// Expands or collapses `path`.
  /// - Parameter path: A directory.
  public func toggle(_ path: String) async {
    if expanded.contains(path) {
      collapse(path)
    } else {
      await expand(path)
    }
  }

  /// Expands `path`, reading its first page when it has none.
  /// - Parameter path: A directory.
  public func expand(_ path: String) async {
    expanded.insert(path)
    rebuild()
    if listings[path] == nil {
      await load(path, after: nil)
    }
  }

  /// Collapses `path`. Its loaded entries are kept.
  /// - Parameter path: A directory.
  public func collapse(_ path: String) {
    expanded.remove(path)
    if let selection, selection.hasPrefix(path + "/") {
      self.selection = path
    }
    rebuild()
  }

  /// Reads the next page of `directory`.
  /// - Parameter directory: A directory with a next cursor.
  public func loadMore(_ directory: String) async {
    guard let cursor = cursors[directory], !loadingMore.contains(directory) else { return }
    loadingMore.insert(directory)
    defer { loadingMore.remove(directory) }
    await load(directory, after: cursor)
  }

  /// Retries a directory that failed.
  /// - Parameter directory: The directory.
  public func retry(_ directory: String) async {
    listings[directory] = nil
    await load(directory, after: nil)
  }

  /// Re-reads the root and every expanded directory from their first page, for example after
  /// `session.changed_files.invalidated`. Collapsed directories are forgotten and reload when
  /// expanded again.
  public func refresh() async {
    let directories = [""] + expanded.sorted()
    for directory in children.keys where !directories.contains(directory) {
      children[directory] = nil
      cursors[directory] = nil
      listings[directory] = nil
    }
    for directory in directories {
      await load(directory, after: nil)
    }
  }

  /// Expands every ancestor of `path` and selects it.
  /// - Parameter path: An entry path.
  public func reveal(_ path: String) async {
    var ancestor = ""
    for segment in path.split(separator: "/").dropLast() {
      ancestor = ancestor.isEmpty ? String(segment) : "\(ancestor)/\(segment)"
      await expand(ancestor)
    }
    selection = path
  }

  // MARK: Keyboard

  /// Moves the selection `offset` entry rows, clamped to the ends.
  /// - Parameter offset: Positive moves down.
  public func moveSelection(by offset: Int) {
    let entries = rows.compactMap(\.entry)
    guard !entries.isEmpty else { return }
    guard let selection, let index = entries.firstIndex(where: { $0.path == selection }) else {
      self.selection = (offset >= 0 ? entries.first : entries.last)?.path
      return
    }
    let target = min(max(index + offset, 0), entries.count - 1)
    self.selection = entries[target].path
  }

  /// Right arrow: expands a collapsed directory, or steps into an expanded one.
  public func stepIn() async {
    guard let entry = selectedEntry, entry.kind.isDirectory else { return }
    if expanded.contains(entry.path) {
      if let first = children[entry.path]?.first { selection = first.path }
    } else {
      await expand(entry.path)
    }
  }

  /// Left arrow: collapses an expanded directory, or steps out to the parent.
  public func stepOut() {
    guard let selection else { return }
    if expanded.contains(selection) {
      collapse(selection)
      return
    }
    let parent = WorkspacePaths.directory(of: selection)
    if !parent.isEmpty { self.selection = parent }
  }

  /// Return: opens a file or toggles a directory.
  public func activateSelection() async {
    guard let entry = selectedEntry else { return }
    if entry.kind.isDirectory {
      await toggle(entry.path)
    } else {
      onOpen?(entry)
    }
  }

  // MARK: Loading

  private func load(_ directory: String, after cursor: String?) async {
    if cursor == nil {
      listings[directory] = .loading
      rebuild()
    }
    do {
      let page = try await source.listDirectory(directory, after: cursor)
      if cursor == nil {
        children[directory] = page.entries
      } else {
        children[directory, default: []].append(contentsOf: page.entries)
      }
      cursors[directory] = page.nextCursor
      listings[directory] = .loaded
    } catch {
      if cursor == nil {
        children[directory] = nil
        cursors[directory] = nil
      }
      listings[directory] = .failed(error)
    }
    rebuild()
  }

  private func isShown(_ entry: WorkspaceEntry) -> Bool {
    showsHidden || !entry.name.hasPrefix(".")
  }

  /// The entry's name matches, or a loaded entry below it does.
  private func matches(_ entry: WorkspaceEntry, _ query: String) -> Bool {
    entry.name.localizedCaseInsensitiveContains(query) || hasMatch(below: entry, query)
  }

  private func hasMatch(below entry: WorkspaceEntry, _ query: String) -> Bool {
    guard entry.kind.isDirectory, let entries = children[entry.path] else { return false }
    return entries.contains { isShown($0) && matches($0, query) }
  }

  private func rebuild() {
    var result: [Row] = []
    append(directory: "", depth: 0, into: &result)
    rows = result
  }

  private func append(directory: String, depth: Int, into result: inout [Row]) {
    switch listings[directory] {
    case nil, .loading:
      if children[directory] == nil {
        result.append(
          Row(id: directory + "#loading", directory: directory, depth: depth, content: .loading))
        return
      }
    case .failed(let failure):
      result.append(
        Row(
          id: directory + "#failure", directory: directory, depth: depth,
          content: .failure(failure)))
      return
    case .loaded:
      break
    }
    let query = filter.trimmingCharacters(in: .whitespaces)
    let entries = (children[directory] ?? []).filter {
      isShown($0) && (query.isEmpty || matches($0, query))
    }
    if entries.isEmpty, !directory.isEmpty, query.isEmpty {
      result.append(
        Row(id: directory + "#empty", directory: directory, depth: depth, content: .empty))
    }
    for entry in entries {
      // A filter opens the folders that lead to a match.
      let isExpanded =
        entry.kind.isDirectory
        && (expanded.contains(entry.path) || (!query.isEmpty && hasMatch(below: entry, query)))
      result.append(
        Row(
          id: entry.path, directory: directory, depth: depth,
          content: .entry(entry, isExpanded: isExpanded)))
      if isExpanded {
        append(directory: entry.path, depth: depth + 1, into: &result)
      }
    }
    if cursors[directory] != nil, query.isEmpty {
      result.append(
        Row(id: directory + "#more", directory: directory, depth: depth, content: .loadMore))
    }
  }
}
