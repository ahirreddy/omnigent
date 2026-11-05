import OmnigentWorkspaceUI

/// The window's unsaved file edits, for the question asked before it closes (Mac) and the save
/// when its scene goes to the background (iOS).
extension ServerSession {
  /// The files with unsaved edits in this window's workspaces, by path.
  public var unsavedFilePaths: [String] {
    workspaces.values.flatMap(\.unsavedPaths).sorted()
  }

  /// Saves every unsaved edit in this window's workspaces.
  /// - Returns: The paths still unsaved: a save failed or waits on a conflict.
  @discardableResult
  public func saveUnsavedFiles() async -> [String] {
    var unsaved: [String] = []
    for workspace in workspaces.values { unsaved += await workspace.saveAll() }
    return unsaved.sorted()
  }

  /// Discards every unsaved edit in this window's workspaces.
  public func discardUnsavedFiles() {
    for workspace in workspaces.values { workspace.discardAll() }
  }
}
