import Foundation
import OmnigentWorkspaceUI

/// Copies a workspace file to a local file under its own name, so the share sheet and Quick Look
/// can open it. Each copy replaces the previous one: only one sheet shows at a time.
struct WorkspaceFileExport {
  /// Why a file was not copied.
  enum Failure: Error, Equatable, CustomStringConvertible {
    /// The server returned only part of the file.
    case truncated(name: String)
    /// The local copy could not be written.
    case write(name: String, reason: String)

    var description: String {
      switch self {
      case .truncated(let name):
        "\(name) is larger than the server returns in one read, so it cannot be shared whole."
      case .write(let name, let reason):
        "\(name) could not be saved for sharing: \(reason)"
      }
    }
  }

  /// Where copies go.
  let directory: URL

  /// Copies under the app's temporary directory, which the system clears.
  static let temporary = Self(
    directory: FileManager.default.temporaryDirectory.appending(
      path: "WorkspaceFiles", directoryHint: .isDirectory))

  /// Writes `contents` to `<directory>/<unique folder>/<file name>`, removing earlier copies.
  /// - Parameter contents: The file.
  /// - Returns: The local file.
  /// - Throws: ``Failure``.
  func write(_ contents: WorkspaceFileContents) throws(Failure) -> URL {
    let name = Self.fileName(of: contents.path)
    guard !contents.truncated else { throw .truncated(name: name) }
    let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let file = folder.appending(path: name, directoryHint: .notDirectory)
    do {
      let manager = FileManager.default
      if manager.fileExists(atPath: directory.path(percentEncoded: false)) {
        try manager.removeItem(at: directory)
      }
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
      try contents.data.write(to: file, options: .atomic)
    } catch {
      throw .write(name: name, reason: error.localizedDescription)
    }
    return file
  }

  /// The file's own name, or a stand-in when the path has none a file system accepts.
  /// - Parameter path: An environment-relative path.
  /// - Returns: The name.
  static func fileName(of path: String) -> String {
    let name = WorkspacePaths.name(of: path)
    return name.isEmpty || name == "." || name == ".." ? "file" : name
  }
}
