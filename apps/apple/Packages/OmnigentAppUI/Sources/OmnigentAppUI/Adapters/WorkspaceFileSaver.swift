#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentWorkspaceUI

  /// Saves a workspace file where the person picks, as the web's Download does: the save panel
  /// asks where under the file's own name, then the whole file is downloaded there, wherever the
  /// session runs.
  @MainActor
  enum WorkspaceFileSaver {
    /// Asks where to save `path`, then downloads it there.
    /// - Parameters:
    ///   - path: The environment-relative file.
    ///   - source: The session's workspace.
    ///   - report: Shows a failure.
    static func save(
      _ path: String, from source: any WorkspaceDataSource,
      report: @escaping @MainActor (String) -> Void
    ) async {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = WorkspaceFileExport.fileName(of: path)
      panel.canCreateDirectories = true
      panel.allowsOtherFileTypes = true
      guard await choose(panel) == .OK, let destination = panel.url else { return }
      await download(path, from: source, to: destination, report: report)
    }

    /// Downloads `path` to `destination`, replacing what is there.
    /// - Parameters:
    ///   - path: The environment-relative file.
    ///   - source: The session's workspace.
    ///   - destination: The local file.
    ///   - report: Shows a failure.
    static func download(
      _ path: String, from source: any WorkspaceDataSource, to destination: URL,
      report: @MainActor (String) -> Void
    ) async {
      let name = WorkspaceFileExport.fileName(of: path)
      let contents: WorkspaceFileContents
      do {
        contents = try await source.download(path)
      } catch {
        report("\(name) could not be downloaded: \(error.message)")
        return
      }
      do {
        try contents.data.write(to: destination, options: .atomic)
      } catch {
        report("\(name) could not be saved: \(error.localizedDescription)")
      }
    }

    /// Shows `panel` on the key window, or on its own without one.
    private static func choose(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
      await withCheckedContinuation { continuation in
        if let window = NSApplication.shared.keyWindow {
          panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        } else {
          panel.begin { continuation.resume(returning: $0) }
        }
      }
    }
  }
#endif
