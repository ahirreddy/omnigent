public import Foundation
public import Observation

/// A bookmark, or a folder of them (`url` nil, `children` set).
nonisolated public struct BrowserBookmark: Codable, Hashable, Identifiable, Sendable {
  /// Identity.
  public let id: UUID
  /// Display title.
  public var title: String
  /// The page; nil for folders.
  public var url: URL?
  /// A folder's contents, in order; nil for bookmarks (the shape `OutlineGroup` expects).
  public var children: [Self]?  // swiftlint:disable:this discouraged_optional_collection

  /// A bookmark.
  public init(id: UUID = UUID(), title: String, url: URL) {
    self.id = id
    self.title = title
    self.url = url
    children = nil
  }

  /// A folder.
  public init(id: UUID = UUID(), folder title: String, children: [Self] = []) {
    self.id = id
    self.title = title
    url = nil
    self.children = children
  }

  /// Whether this is a folder.
  public var isFolder: Bool { children != nil }

  /// This item and everything under it, depth first.
  public var flattened: [Self] {
    [self] + (children ?? []).flatMap(\.flattened)
  }
}

/// One profile's bookmarks: a bookmarks bar and "Other Bookmarks", like Chrome. Persisted to
/// `bookmarks.json` unless in memory.
@Observable
public final class BrowserBookmarkStore {
  /// The file format version.
  public static let fileVersion = 1

  /// The bookmarks bar folder.
  public private(set) var bar: BrowserBookmark
  /// The "Other Bookmarks" folder.
  public private(set) var other: BrowserBookmark
  /// The most recent load or save failure.
  public private(set) var lastError: BrowserError?

  @ObservationIgnored private let file: BrowserPersistentFile<Snapshot>?

  struct Snapshot: Codable {
    var bar: BrowserBookmark
    var other: BrowserBookmark
  }

  /// Loads bookmarks from `fileURL`, or keeps them in memory when nil. A damaged file is moved
  /// aside and reported in `lastError`.
  public init(fileURL: URL?) {
    file = fileURL.map {
      BrowserPersistentFile(url: $0, version: Self.fileVersion, debounce: .zero)
    }
    let (loaded, error) = file?.loadMovingAsideIfDamaged() ?? (nil, nil)
    bar = loaded?.bar ?? BrowserBookmark(folder: "Bookmarks Bar")
    other = loaded?.other ?? BrowserBookmark(folder: "Other Bookmarks")
    lastError = error
  }

  /// Every bookmark (not folders), bar first.
  public var allBookmarks: [BrowserBookmark] {
    (bar.flattened + other.flattened).filter { !$0.isFolder }
  }

  /// Every folder, for "add to" pickers.
  public var allFolders: [BrowserBookmark] {
    (bar.flattened + other.flattened).filter(\.isFolder)
  }

  /// The first bookmark for `url`.
  public func bookmark(for url: URL) -> BrowserBookmark? {
    allBookmarks.first { $0.url == url }
  }

  /// Whether `url` is bookmarked.
  public func isBookmarked(_ url: URL) -> Bool {
    bookmark(for: url) != nil
  }

  /// Bookmarks whose title or URL contains every word of `text`.
  public func search(_ text: String, limit: Int = 5) -> [BrowserBookmark] {
    let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return [] }
    return Array(
      allBookmarks.filter { bookmark in
        let haystack = "\(bookmark.title) \(bookmark.url?.absoluteString ?? "")".lowercased()
        return words.allSatisfy(haystack.contains)
      }
      .prefix(limit))
  }

  /// Adds a bookmark to a folder (the bar by default).
  @discardableResult
  public func add(url: URL, title: String, to folderID: UUID? = nil) throws(BrowserError)
    -> BrowserBookmark
  {
    let bookmark = BrowserBookmark(title: title.isEmpty ? url.absoluteString : title, url: url)
    try insert(bookmark, into: folderID ?? bar.id)
    return bookmark
  }

  /// Adds a folder.
  @discardableResult
  public func addFolder(title: String, to folderID: UUID? = nil) throws(BrowserError)
    -> BrowserBookmark
  {
    let folder = BrowserBookmark(folder: title)
    try insert(folder, into: folderID ?? bar.id)
    return folder
  }

  /// Bookmarks `url` in the bar, or removes every bookmark of it. Returns whether it is now
  /// bookmarked.
  @discardableResult
  public func toggle(url: URL, title: String) throws(BrowserError) -> Bool {
    let existing = allBookmarks.filter { $0.url == url }
    if existing.isEmpty {
      try add(url: url, title: title)
      return true
    }
    for bookmark in existing {
      try remove(id: bookmark.id)
    }
    return false
  }

  /// Renames an item or changes a bookmark's URL.
  public func update(id: UUID, title: String, url: URL? = nil) throws(BrowserError) {
    try mutate { root in
      Self.modify(&root, id: id) { item in
        item.title = title
        if let url, !item.isFolder { item.url = url }
      }
    }
  }

  /// Removes an item (a folder with its contents).
  public func remove(id: UUID) throws(BrowserError) {
    guard id != bar.id, id != other.id else {
      throw .notAllowed("The bookmarks bar and Other Bookmarks cannot be removed.")
    }
    try mutate { root in Self.extract(&root, id: id) != nil }
  }

  /// Moves an item into a folder at `index` (the end when nil).
  public func move(id: UUID, to folderID: UUID, index: Int? = nil) throws(BrowserError) {
    guard id != folderID else { throw .notAllowed("A folder cannot contain itself.") }
    var bar = self.bar
    var other = self.other
    guard let item = Self.extract(&bar, id: id) ?? Self.extract(&other, id: id) else {
      throw .notAllowed("No bookmark has that ID.")
    }
    guard !item.flattened.contains(where: { $0.id == folderID }) else {
      throw .notAllowed("A folder cannot move into itself.")
    }
    let inserted =
      Self.modify(&bar, id: folderID) { Self.append(item, to: &$0, at: index) }
      || Self.modify(&other, id: folderID) { Self.append(item, to: &$0, at: index) }
    guard inserted else { throw .notAllowed("No folder has that ID.") }
    try commit(bar: bar, other: other)
  }

  /// Removes every bookmark.
  public func removeAll() throws(BrowserError) {
    try commit(
      bar: BrowserBookmark(id: bar.id, folder: bar.title),
      other: BrowserBookmark(id: other.id, folder: other.title))
  }

  /// Imports a Netscape bookmark file, as Chrome, Safari and Firefox export. The exporter's
  /// toolbar folder goes into the bar; everything else into an "Imported" folder in Other
  /// Bookmarks. Returns the number of bookmarks added.
  @discardableResult
  public func importHTML(_ data: Data) throws(BrowserError) -> Int {
    let parsed = try BrowserBookmarkHTML.parse(data)
    var bar = self.bar
    var other = self.other
    bar.children?.append(contentsOf: parsed.toolbar)
    if !parsed.other.isEmpty {
      other.children?.append(BrowserBookmark(folder: "Imported", children: parsed.other))
    }
    try commit(bar: bar, other: other)
    return (parsed.toolbar + parsed.other).flatMap(\.flattened).filter { !$0.isFolder }.count
  }

  // MARK: Tree editing

  private func insert(_ item: BrowserBookmark, into folderID: UUID) throws(BrowserError) {
    var bar = self.bar
    var other = self.other
    let inserted =
      Self.modify(&bar, id: folderID) { Self.append(item, to: &$0, at: nil) }
      || Self.modify(&other, id: folderID) { Self.append(item, to: &$0, at: nil) }
    guard inserted else { throw .notAllowed("No folder has that ID.") }
    try commit(bar: bar, other: other)
  }

  private func mutate(_ change: (inout BrowserBookmark) -> Bool) throws(BrowserError) {
    var bar = self.bar
    var other = self.other
    guard change(&bar) || change(&other) else { throw .notAllowed("No bookmark has that ID.") }
    try commit(bar: bar, other: other)
  }

  private func commit(bar: BrowserBookmark, other: BrowserBookmark) throws(BrowserError) {
    self.bar = bar
    self.other = other
    do {
      try file?.write(Snapshot(bar: bar, other: other))
      lastError = nil
    } catch {
      lastError = error
      throw error
    }
  }

  private static func append(
    _ item: BrowserBookmark, to folder: inout BrowserBookmark, at index: Int?
  ) {
    guard folder.isFolder else { return }
    let count = folder.children?.count ?? 0
    folder.children?.insert(item, at: min(max(0, index ?? count), count))
  }

  /// Applies `change` to the item with `id` under `root`; false when absent.
  @discardableResult
  private static func modify(
    _ root: inout BrowserBookmark, id: UUID, _ change: (inout BrowserBookmark) -> Void
  ) -> Bool {
    if root.id == id {
      change(&root)
      return true
    }
    guard var children = root.children else { return false }
    for index in children.indices where modify(&children[index], id: id, change) {
      root.children = children
      return true
    }
    return false
  }

  /// Removes and returns the item with `id` under `root`.
  private static func extract(_ root: inout BrowserBookmark, id: UUID) -> BrowserBookmark? {
    guard var children = root.children else { return nil }
    if let index = children.firstIndex(where: { $0.id == id }) {
      let item = children.remove(at: index)
      root.children = children
      return item
    }
    for index in children.indices {
      if let item = extract(&children[index], id: id) {
        root.children = children
        return item
      }
    }
    return nil
  }
}
