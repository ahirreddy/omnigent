import Foundation
import OmnigentUIComponents
import OmnigentWorkspaceUI

/// Workspace file links for a session's messages, over its workspace browser: folder listings
/// and image reads through the core, and a click opens the file in the workspace viewer.
enum MarkdownLinksAdapter {
  /// Pages read per folder when checking that a cited file exists.
  static let maxListingPages = 20

  /// Links over `workspace`.
  static func links(_ workspace: WorkspaceBrowserModel) -> WorkspaceFileLinks {
    let source = workspace.source
    return WorkspaceFileLinks(
      root: { source.absoluteLocation(of: "") }, home: nil,
      listFiles: { folder in try await files(in: folder, source: source) },
      readImage: { path in
        guard case .image(_, let data) = try await source.readFile(path).preview else {
          throw WorkspaceImageError.notAnImage
        }
        return data
      },
      open: { [weak workspace] target in
        Task {
          await workspace?.open(.file(path: target.path, line: target.line.map { UInt64($0) }))
        }
      })
  }

  /// The names of the files in `folder`, across its pages.
  static func files(in folder: String, source: any WorkspaceDataSource) async throws
    -> Set<String>
  {
    var names = Set<String>()
    var cursor: String?
    var pages = 0
    repeat {
      let page = try await source.listDirectory(folder, after: cursor)
      for entry in page.entries where entry.kind != .directory { names.insert(entry.name) }
      cursor = page.nextCursor
      pages += 1
    } while cursor != nil && pages < maxListingPages
    return names
  }
}
