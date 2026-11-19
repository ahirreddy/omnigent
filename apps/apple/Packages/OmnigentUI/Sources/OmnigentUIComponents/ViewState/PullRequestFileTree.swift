import Foundation

/// The changed files as a folder tree, as the web's Changes sidebar builds it: a chain of
/// single-folder children folds into one row ("omnigent/runner"), folders come before files, and
/// each group keeps the order its first file appeared in.
nonisolated public indirect enum PullRequestFileTree: Hashable, Sendable {
  /// A file leaf; `name` is its last path component.
  case file(name: String, file: PullRequestTreeFile)
  /// A folder: its name, possibly a folded chain, and the full path of its deepest folder.
  case folder(name: String, path: String, children: [Self])

  /// A stable id: the file's or folder's path.
  public var id: String {
    switch self {
    case .file(_, let file): "f:\(file.path)"
    case .folder(_, let path, _): "d:\(path)"
    }
  }

  /// The tree of `files`.
  /// - Parameter files: The files, in list order.
  /// - Returns: The top-level nodes.
  public static func build(_ files: [PullRequestTreeFile]) -> [Self] {
    var root = Folder(name: "", path: "")
    for file in files {
      let parts = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      root.insert(file, parts: parts[...], prefix: [])
    }
    return root.children.map { $0.compacted() }.foldersFirst()
  }

  /// A folder being built.
  private struct Folder {
    var name: String
    var path: String
    var children: [Node] = []

    mutating func insert(_ file: PullRequestTreeFile, parts: ArraySlice<String>, prefix: [String]) {
      guard let first = parts.first else { return }
      if parts.count == 1 {
        children.append(.file(name: first, file: file))
        return
      }
      let path = (prefix + [first]).joined(separator: "/")
      let existing = children.firstIndex {
        if case .folder(let folder) = $0 { folder.name == first } else { false }
      }
      let index: Int
      if let existing {
        index = existing
      } else {
        children.append(.folder(Self(name: first, path: path)))
        index = children.count - 1
      }
      guard case .folder(var folder) = children[index] else { return }
      folder.insert(file, parts: parts.dropFirst(), prefix: prefix + [first])
      children[index] = .folder(folder)
    }
  }

  private enum Node {
    case file(name: String, file: PullRequestTreeFile)
    case folder(Folder)

    /// Folds single-folder chains, children first so one merge per level suffices.
    func compacted() -> PullRequestFileTree {
      switch self {
      case .file(let name, let file): return .file(name: name, file: file)
      case .folder(let folder):
        let children = folder.children.map { $0.compacted() }
        if children.count == 1, case .folder(let name, let path, let grandchildren) = children[0] {
          return .folder(name: "\(folder.name)/\(name)", path: path, children: grandchildren)
        }
        return .folder(name: folder.name, path: folder.path, children: children.foldersFirst())
      }
    }
  }
}

extension [PullRequestFileTree] {
  /// Folders, then files, each in first-seen order.
  nonisolated fileprivate func foldersFirst() -> Self {
    filter { if case .folder = $0 { true } else { false } }
      + filter { if case .file = $0 { true } else { false } }
  }
}
