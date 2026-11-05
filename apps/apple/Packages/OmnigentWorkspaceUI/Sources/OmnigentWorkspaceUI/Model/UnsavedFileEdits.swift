import Foundation

/// Every live workspace browser's unsaved file edits, for the questions asked before the app
/// quits: which files would lose edits, save them all, or discard them.
public enum UnsavedFileEdits {
  private final class WeakModel {
    weak var model: WorkspaceBrowserModel?
    init(_ model: WorkspaceBrowserModel) { self.model = model }
  }

  private static var models: [WeakModel] = []

  /// Tracks `model` while it lives.
  static func register(_ model: WorkspaceBrowserModel) {
    models.removeAll { $0.model == nil }
    models.append(WeakModel(model))
  }

  private static var live: [WorkspaceBrowserModel] { models.compactMap(\.model) }

  /// The files with unsaved edits in any workspace, by path.
  public static var paths: [String] { live.flatMap(\.unsavedPaths) }

  /// Saves every unsaved edit.
  /// - Returns: The paths still unsaved (a save failed or waits on a conflict).
  public static func saveAll() async -> [String] {
    var unsaved: [String] = []
    for model in live { unsaved += await model.saveAll() }
    return unsaved
  }

  /// Discards every unsaved edit.
  public static func discardAll() {
    for model in live { model.discardAll() }
  }

  /// The question for `paths`: "Save changes to “a.rs”?" for one file, else how many.
  /// - Parameter paths: The unsaved files.
  /// - Returns: The title.
  public static func title(for paths: [String]) -> String {
    if paths.count == 1, let path = paths.first {
      return "Save changes to \u{201C}\(WorkspacePaths.name(of: path))\u{201D}?"
    }
    return "Save changes to \(paths.count) files?"
  }

  /// What the unsaved-edits question explains.
  public static let message = "Your changes will be lost if you don't save them."
}
