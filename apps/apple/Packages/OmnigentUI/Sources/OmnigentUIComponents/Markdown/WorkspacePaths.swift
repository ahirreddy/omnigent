public import Foundation

/// A workspace file a message cites, with the position it names (`src/app.ts:12:5`), or a
/// folder an explicit link names.
nonisolated public struct WorkspaceFileTarget: Hashable, Sendable {
  /// Workspace-relative path.
  public var path: String
  /// 1-based line, when cited.
  public var line: Int?
  /// 1-based column, when cited.
  public var column: Int?
  /// The path is a folder, to show in the Files tree.
  public var isFolder: Bool

  /// A target.
  /// - Parameters:
  ///   - path: Workspace-relative path.
  ///   - line: 1-based line.
  ///   - column: 1-based column.
  ///   - isFolder: The path is a folder.
  public init(path: String, line: Int? = nil, column: Int? = nil, isFolder: Bool = false) {
    self.path = path
    self.line = line
    self.column = column
    self.isFolder = isFolder
  }

  static let scheme = "omnigent-file"

  /// The in-app link a markdown span carries to open this file.
  var url: URL? {
    var components = URLComponents()
    components.scheme = Self.scheme
    components.path = "open"
    components.queryItems =
      [URLQueryItem(name: "path", value: path)]
      + [line.map { URLQueryItem(name: "line", value: String($0)) }].compactMap(\.self)
      + [column.map { URLQueryItem(name: "column", value: String($0)) }].compactMap(\.self)
      + (isFolder ? [URLQueryItem(name: "folder", value: "1")] : [])
    return components.url
  }

  /// The target an in-app file link names, or `nil` for any other URL.
  init?(url: URL) {
    guard url.scheme == Self.scheme,
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      let path = items.first(where: { $0.name == "path" })?.value, !path.isEmpty
    else { return nil }
    self.path = path
    line = items.first(where: { $0.name == "line" })?.value.flatMap { Int($0) }
    column = items.first(where: { $0.name == "column" })?.value.flatMap { Int($0) }
    isFolder = items.contains { $0.name == "folder" && $0.value == "1" }
  }
}

/// Recognizes workspace file paths in agent markdown, as the web's chat renderer does
/// (`splitWorkspaceFileCitation`, `looksLikeWorkspaceFilePath`, `resolveChatFilePath`).
nonisolated enum WorkspacePaths {
  /// A cited path and the position after it.
  struct Citation: Hashable {
    var path: String
    var line: Int?
    var column: Int?
  }

  /// Splits a trailing `:12`, `:12:5`, `:12-18` or `#L12C5` position off `text`.
  static func citation(_ text: String) -> Citation {
    if let match = text.firstMatch(of: /:(\d+)(?::(\d+)|-(\d+))?$/) {
      return Citation(
        path: String(text[..<match.range.lowerBound]), line: positive(match.output.1),
        column: match.output.2.flatMap(positive))
    }
    if let match = text.firstMatch(of: /#[Ll](\d+)(?:[Cc](\d+))?(?:-[Ll]?(\d+)(?:[Cc]\d+)?)?$/) {
      return Citation(
        path: String(text[..<match.range.lowerBound]), line: positive(match.output.1),
        column: match.output.2.flatMap(positive))
    }
    return Citation(path: text, line: nil, column: nil)
  }

  private static func positive(_ digits: Substring) -> Int? {
    Int(digits).flatMap { $0 > 0 ? $0 : nil }
  }

  /// Whether inline code reads as a relative file path worth checking: a parent segment, no
  /// whitespace before the first slash (that is a command), no URL, query, fragment or
  /// traversal.
  static func looksLikeRelativePath(_ text: String) -> Bool {
    guard !text.isEmpty, !text.hasPrefix("/"), !text.contains("://"), !text.contains("?"),
      !text.contains("#"), let slash = text.firstIndex(of: "/"), slash > text.startIndex,
      !text[..<slash].contains(where: \.isWhitespace)
    else { return false }
    return isCanonical(text)
  }

  /// `text` as a workspace-relative path: a relative path as is, an absolute or `~` path under
  /// `root` without the root. `nil` for URLs, Windows paths, traversal, the root itself and
  /// anything outside it.
  static func resolve(_ text: String, root: String?, home: String?) -> String? {
    if text.isEmpty || text.contains("://") || text.contains("?") || text.contains("#")
      || text.contains("\\") || text.firstMatch(of: /^[A-Za-z]:/) != nil
    {
      return nil
    }
    var path = text
    if let home, path == "~" || path.hasPrefix("~/") {
      path = trimmingSlashes(home) + path.dropFirst()
    }
    guard path.hasPrefix("/") else {
      return path.hasPrefix("~") || !isCanonical(path) ? nil : path
    }
    guard let root else { return nil }
    let prefix = trimmingSlashes(root) + "/"
    guard path.hasPrefix(prefix) else { return nil }
    let relative = String(path.dropFirst(prefix.count))
    return isCanonical(relative) ? relative : nil
  }

  /// The target `text` cites when it can name a workspace file: inline code must look like a
  /// path; an explicit link may be any relative or absolute path.
  static func target(_ text: String, explicit: Bool, root: String?, home: String?)
    -> WorkspaceFileTarget?
  {
    var cited = citation(text)
    // A link may name a folder with a trailing slash (`[src](src/)`).
    if explicit, cited.path.count > 1, cited.path.hasSuffix("/") { cited.path.removeLast() }
    let isAbsolute = cited.path.hasPrefix("/") || cited.path.hasPrefix("~")
    guard explicit || isAbsolute || looksLikeRelativePath(cited.path),
      let path = resolve(cited.path, root: root, home: home)
    else { return nil }
    return WorkspaceFileTarget(path: path, line: cited.line, column: cited.column)
  }

  /// Whether inline code may name a file: path-shaped relative text, or an absolute or `~/`
  /// path (checked against the workspace root later).
  static func mayCite(_ code: String) -> Bool {
    let path = citation(code).path
    return looksLikeRelativePath(path)
      || ((path.hasPrefix("/") || path.hasPrefix("~/")) && !path.contains(where: \.isWhitespace))
  }

  /// The path a link destination names: a file path (percent-decoded) or a `file://` URL's
  /// path, with any position kept. `nil` for URLs and anchors.
  static func linkedPath(_ destination: String?) -> String? {
    guard let destination, !destination.isEmpty else { return nil }
    if destination.lowercased().hasPrefix("file://") {
      guard let url = URL(string: destination), url.host()?.isEmpty ?? true else {
        return nil
      }
      let position = url.fragment.map { "#" + $0 } ?? ""
      return url.path(percentEncoded: false) + position
    }
    guard isFileDestination(destination) else { return nil }
    return destination.removingPercentEncoding ?? destination
  }

  /// Whether a link destination is a file path rather than a URL or an in-page anchor.
  static func isFileDestination(_ destination: String) -> Bool {
    if destination.hasPrefix("#") || destination.hasPrefix("//") { return false }
    // `name:` is a URL scheme unless it is a position (`notes.md:12`).
    if let scheme = destination.firstMatch(of: /^[A-Za-z][A-Za-z0-9+.-]*:/),
      destination[scheme.range.upperBound...].firstMatch(of: /^\d+(?::\d+|-\d+)?$/) == nil
    {
      return false
    }
    return !destination.isEmpty
  }

  private static func isCanonical(_ relative: String) -> Bool {
    relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }

  private static func trimmingSlashes(_ path: String) -> String {
    var path = path
    while path.hasSuffix("/") { path.removeLast() }
    return path
  }
}

/// The workspace path a markdown span cites, before anyone checked that it exists.
nonisolated enum WorkspacePathAttribute: AttributedStringKey {
  typealias Value = String
  static let name = "omnigent.workspacePath"
}

/// Whether the cited path came from an explicit markdown link (any path) or inline code (only
/// path-shaped text).
nonisolated enum WorkspacePathIsExplicitAttribute: AttributedStringKey {
  typealias Value = Bool
  static let name = "omnigent.workspacePathIsExplicit"
}
