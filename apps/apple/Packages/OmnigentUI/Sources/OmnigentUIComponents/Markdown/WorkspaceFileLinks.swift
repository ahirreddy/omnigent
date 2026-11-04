public import Foundation
public import Observation
public import SwiftUI

/// Turns workspace file paths in a session's messages into links that open the file in the app,
/// as the web's chat does. A path links only once a listing of its folder shows the file, and
/// each folder is listed once. The host supplies the listing, the image reads and opening.
@MainActor
@Observable
public final class WorkspaceFileLinks {
  /// What a folder listing found.
  private enum Listing {
    case loading
    case files(Set<String>)
    /// The listing failed; its paths stay plain text (``failures`` keeps why).
    case failed
  }

  @ObservationIgnored private let root: @MainActor () -> String?
  @ObservationIgnored private let home: String?
  @ObservationIgnored private let listFiles: @MainActor (String) async throws -> Set<String>
  @ObservationIgnored private let readImage: (@MainActor (String) async throws -> Data)?
  @ObservationIgnored private let openFile: @MainActor (WorkspaceFileTarget) -> Void
  @ObservationIgnored private var images = BoundedCache<String, Data>(limit: 32)
  private var listings: [String: Listing] = [:]
  /// Folder listings that failed, by folder, for diagnostics.
  public private(set) var failures: [String: String] = [:]

  /// Links over one session workspace.
  /// - Parameters:
  ///   - root: The workspace's absolute root once known, to recognize absolute paths inside it.
  ///   - home: The home directory, to expand `~/`.
  ///   - listFiles: The names of the files (not folders) in a workspace-relative folder, `""`
  ///     for the root.
  ///   - readImage: An image file's bytes; `nil` shows workspace images as their alt text.
  ///   - open: Opens a file in the app.
  public init(
    root: @escaping @MainActor () -> String?, home: String?,
    listFiles: @escaping @MainActor (String) async throws -> Set<String>,
    readImage: (@MainActor (String) async throws -> Data)? = nil,
    open: @escaping @MainActor (WorkspaceFileTarget) -> Void
  ) {
    self.root = root
    self.home = home
    self.listFiles = listFiles
    self.readImage = readImage
    openFile = open
  }

  /// The file a cited path opens, when its folder listing shows it.
  func target(for cited: String, explicit: Bool) -> WorkspaceFileTarget? {
    guard let target = candidate(cited, explicit: explicit),
      case .files(let names)? = listings[Self.folder(of: target.path)],
      names.contains(Self.name(of: target.path))
    else { return nil }
    return target
  }

  /// Lists the folders of `cited` paths not listed yet.
  /// - Parameter cited: Paths as messages cite them, with whether each was an explicit link.
  func check(_ cited: [CitedPath]) async {
    let folders = Set(
      cited.compactMap { candidate($0.text, explicit: $0.explicit) }.map {
        Self.folder(of: $0.path)
      })
    for folder in folders.sorted() where listings[folder] == nil {
      listings[folder] = .loading
      do {
        listings[folder] = .files(try await listFiles(folder))
      } catch is CancellationError {
        // The message scrolled away; the next view that cites the folder lists it again.
        listings[folder] = nil
        return
      } catch {
        // A path whose folder cannot be listed stays plain text, as on the web.
        listings[folder] = .failed
        failures[folder] = String(describing: error)
      }
    }
  }

  /// Opens `target` in the app.
  func open(_ target: WorkspaceFileTarget) {
    openFile(target)
  }

  /// Whether workspace images can be shown.
  var readsImages: Bool { readImage != nil }

  /// An image's bytes, read once per path.
  func image(at cited: String) async throws -> Data {
    guard let readImage, let path = WorkspacePaths.resolve(cited, root: root(), home: home) else {
      throw WorkspaceImageError.notInWorkspace
    }
    if let cached = images.cached(path) { return cached }
    let data = try await readImage(path)
    return images.value(for: path) { data }
  }

  private func candidate(_ cited: String, explicit: Bool) -> WorkspaceFileTarget? {
    WorkspacePaths.target(cited, explicit: explicit, root: root(), home: home)
  }

  private static func folder(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
  }

  private static func name(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
  }
}

/// A path a message cites, as found in the markdown.
nonisolated struct CitedPath: Hashable, Sendable {
  var text: String
  var explicit: Bool
}

/// Why a markdown image could not be shown.
nonisolated public enum WorkspaceImageError: LocalizedError {
  /// The source is not a path inside the session's workspace.
  case notInWorkspace
  /// The file is not an image the platform decodes.
  case notAnImage

  /// What the image's placeholder says.
  public var errorDescription: String? {
    switch self {
    case .notInWorkspace: "The image is not a file in this session's workspace."
    case .notAnImage: "The file is not an image this app can show."
    }
  }
}

extension EnvironmentValues {
  /// The session's workspace file links; `nil` leaves paths as plain text.
  @Entry public var workspaceFileLinks: WorkspaceFileLinks?
}

extension WorkspaceFileLinks {
  /// `text` with each cited path that exists linked to open it.
  func linking(_ text: AttributedString) -> AttributedString {
    var linked = text
    for run in text.runs {
      guard let cited = run[WorkspacePathAttribute.self],
        let target = target(
          for: cited, explicit: run[WorkspacePathIsExplicitAttribute.self] ?? false),
        let url = target.url
      else { continue }
      linked[run.range].link = url
    }
    return linked
  }

  /// Routes in-app file links to ``open(_:)`` and every other link to `fallback`.
  func openURLAction(fallback: OpenURLAction) -> OpenURLAction {
    OpenURLAction { [weak self] url in
      guard let target = WorkspaceFileTarget(url: url) else {
        fallback(url)
        return .handled
      }
      self?.open(target)
      return .handled
    }
  }
}

extension MarkdownBlock {
  /// Every path the blocks cite, in order, without repeats.
  static func citedPaths(in blocks: [MarkdownBlock]) -> [CitedPath] {
    var seen = Set<CitedPath>()
    var result: [CitedPath] = []
    func add(_ text: AttributedString) {
      for run in text.runs {
        guard let cited = run[WorkspacePathAttribute.self] else { continue }
        let path = CitedPath(
          text: cited, explicit: run[WorkspacePathIsExplicitAttribute.self] ?? false)
        if seen.insert(path).inserted { result.append(path) }
      }
    }
    func visit(_ blocks: [MarkdownBlock]) {
      for block in blocks {
        switch block {
        case .paragraph(let text), .heading(_, let text): add(text)
        case .quote(let inner): visit(inner)
        case .list(_, _, let items):
          for item in items { visit(item.blocks) }
        case .table(let table):
          for cell in table.header + table.rows.flatMap(\.self) { add(cell) }
        case .code, .rule, .html, .image, .math: break
        }
      }
    }
    visit(blocks)
    return result
  }
}
