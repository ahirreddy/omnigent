import Foundation
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The workspace panel's host hooks: Reveal in Finder and Open in Editor when the session's
/// folder is on this Mac, Share and Quick Look on iPhone and iPad (the file is read through the
/// workspace, wherever the session runs), and the conversation's Markdown for file previews.
enum WorkspaceActionsAdapter {
  #if os(macOS)
    /// Opens a file in its default app, or says it couldn't.
    static func openExternally(
      _ path: String, open: (URL) -> Bool = { NSWorkspace.shared.open($0) },
      report: @MainActor (String) -> Void
    ) {
      if !open(URL(fileURLWithPath: path)) { report("Could not open \(path).") }
    }
  #endif

  /// The hooks for `workspace`.
  /// - Parameters:
  ///   - workspace: The session's workspace.
  ///   - mention: Inserts a path reference into the composer.
  ///   - report: Shows a failure to open a path.
  /// - Returns: The hooks.
  static func actions(
    _ workspace: WorkspaceBrowserModel, mention: ((String) -> Void)?,
    report: @escaping @MainActor (String) -> Void
  ) -> WorkspaceActions {
    var actions = WorkspaceActions(mention: mention)
    #if os(macOS)
      // A remote host's paths mean nothing here; only a folder this Mac can see is offered.
      guard let root = workspace.source.absoluteLocation(of: ""), isLocalFolder(root) else {
        return actions
      }
      actions.reveal = { path in
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      }
      actions.openExternally = { openExternally($0, report: report) }
    #else
      let source = workspace.source
      actions.share = { path in
        Task {
          await WorkspaceFilePresenter.present(path, from: source, as: .share, report: report)
        }
      }
      actions.quickLook = { path in
        Task {
          await WorkspaceFilePresenter.present(path, from: source, as: .quickLook, report: report)
        }
      }
    #endif
    return actions
  }

  /// Whether `path` is a folder on this machine.
  static func isLocalFolder(_ path: String) -> Bool {
    do {
      return try URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey])
        .isDirectory == true
    } catch {
      // No such folder here: the session runs on another machine.
      return false
    }
  }

  /// The file viewer's Markdown preview, in the transcript's Markdown style.
  static let markdownRenderer = WorkspaceMarkdownRenderer(id: "transcript") { text in
    AnyView(MarkdownView(text))
  }
}
