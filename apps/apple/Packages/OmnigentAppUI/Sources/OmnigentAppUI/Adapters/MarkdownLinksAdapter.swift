import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

/// Workspace file links for a session's messages, over its workspace browser: folder listings
/// and image reads through the core; a click opens a file in the workspace viewer, or shows a
/// folder in the Files tree.
enum MarkdownLinksAdapter {
  /// Pages read per folder when checking that a cited file exists.
  static let maxListingPages = 20

  /// Links over `workspace`.
  static func links(_ workspace: WorkspaceBrowserModel) -> WorkspaceFileLinks {
    let source = workspace.source
    return WorkspaceFileLinks(
      root: { source.absoluteLocation(of: "") },
      home: { (source as? WorkspaceStore)?.environment?.home },
      listFolder: { folder in try await listing(of: folder, source: source) },
      readImage: { path in
        guard case .image(_, let data) = try await source.readFile(path).preview else {
          throw WorkspaceImageError.notAnImage
        }
        return data
      },
      open: { [weak workspace] target in
        guard let workspace else { return }
        Task { await open(target, in: workspace) }
      })
  }

  /// Opens a file in the viewer, or shows a folder expanded and selected in the Files tree.
  static func open(_ target: WorkspaceFileTarget, in workspace: WorkspaceBrowserModel) async {
    guard target.isFolder else {
      await workspace.open(.file(path: target.path, line: target.line.map { UInt64($0) }))
      return
    }
    workspace.hideDocument()
    if workspace.tab != .files { workspace.tab = .files }
    await workspace.tree.reveal(target.path)
    await workspace.tree.expand(target.path)
  }

  /// The files and subfolders of `folder`, across its pages.
  static func listing(of folder: String, source: any WorkspaceDataSource) async throws
    -> WorkspaceFolderListing
  {
    var listing = WorkspaceFolderListing(files: [])
    var cursor: String?
    var pages = 0
    repeat {
      let page = try await source.listDirectory(folder, after: cursor)
      for entry in page.entries {
        if entry.kind == .directory {
          listing.folders.insert(entry.name)
        } else {
          listing.files.insert(entry.name)
        }
      }
      cursor = page.nextCursor
      pages += 1
    } while cursor != nil && pages < maxListingPages
    return listing
  }
}

/// A conversation's message media: workspace file links and uploaded image previews.
struct MessageMediaEnvironment: ViewModifier {
  let fileLinks: WorkspaceFileLinks?
  let conversation: ConversationStore
  @State private var previews: AttachmentPreviews?

  func body(content: Content) -> some View {
    content
      .environment(\.workspaceFileLinks, fileLinks)
      .environment(\.attachmentPreviews, previews)
      .task(id: conversation.sessionID) {
        previews = AttachmentPreviews { [conversation] reference in
          try await conversation.attachmentPreview(reference: reference)
        }
      }
  }
}
