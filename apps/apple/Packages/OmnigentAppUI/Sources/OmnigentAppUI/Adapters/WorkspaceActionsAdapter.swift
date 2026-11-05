import Foundation
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The workspace panel's host hooks: Reveal in Finder and Open in Editor when the session's
/// folder is on this Mac, and the conversation's Markdown for file previews.
enum WorkspaceActionsAdapter {
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
      actions.openExternally = { path in
        if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
          report("Could not open \(path).")
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
