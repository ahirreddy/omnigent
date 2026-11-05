import Foundation
import OmnigentCoreFFI

extension ComposerStore {
  /// The query of the `@` mention being typed at the end of `draft`: an `@` at the start or
  /// after whitespace, with no whitespace after it. `nil` when none is being typed.
  /// - Parameter draft: The composer text.
  /// - Returns: The text after the `@`, possibly empty.
  public static func mentionQuery(in draft: String) -> String? {
    guard let sign = draft.lastIndex(of: "@") else { return nil }
    if sign != draft.startIndex, !draft[draft.index(before: sign)].isWhitespace { return nil }
    let query = draft[draft.index(after: sign)...]
    return query.contains(where: \.isWhitespace) ? nil : String(query)
  }

  /// Tags `path` (a workspace file, or a folder ending in `/`) to go with the next message.
  /// - Parameter path: The workspace-relative path.
  public func addMention(_ path: String) {
    guard !path.isEmpty, !mentions.contains(path) else { return }
    mentions.append(path)
  }

  /// Untags `path`.
  /// - Parameter path: The path.
  public func removeMention(_ path: String) {
    mentions.removeAll { $0 == path }
  }

  /// The marker lines the tagged paths put ahead of a message; empty without tags.
  var mentionPreamble: String {
    mentions.isEmpty
      ? "" : OmnigentCoreFFI.mentionPreamble(harness: configuration?.harness, paths: mentions)
  }

  /// Searches the workspace when the typed mention changes, after a short pause, and clears
  /// the results when no mention is being typed.
  func mentionTextChanged() {
    guard let search = searchMentions else { return }
    let query = Self.mentionQuery(in: text)
    guard query != mentionQuery else { return }
    mentionQuery = query
    mentionTask?.cancel()
    guard let query else {
      if !mentionCandidates.isEmpty { mentionCandidates = [] }
      if mentionProblem != nil { mentionProblem = nil }
      return
    }
    mentionTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(150))
      } catch {
        // Superseded by a newer query, which searches for itself.
        return
      }
      await self?.runMentionSearch(query, search: search)
    }
  }

  /// The `@` menu's rows for `query`, as on the web: the browsed folder's entries whose name
  /// contains the typed filter, folders first and then by name, followed by deeper `matches`
  /// under the folder; no repeats, at most `limit`. Folders end in `/`.
  /// - Parameters:
  ///   - query: The text after the `@`: `src/ma` browses `src` for `ma`.
  ///   - listing: The browsed folder's entries.
  ///   - matches: Search results across the workspace, for a non-empty filter.
  ///   - limit: The most rows.
  /// - Returns: Workspace-relative paths.
  public static func mentionRows(
    query: String, listing: [MentionEntry], matches: [MentionEntry] = [], limit: Int = 50
  ) -> [String] {
    let slash = query.lastIndex(of: "/")
    let folder = slash.map { String(query[...$0]) } ?? ""
    let filter = (slash.map { String(query[query.index(after: $0)...]) } ?? query).lowercased()
    let browsed =
      listing
      .filter { filter.isEmpty || $0.name.lowercased().contains(filter) }
      .sorted {
        $0.isDirectory != $1.isDirectory
          ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
    let deeper = filter.isEmpty ? [] : matches.filter { $0.path.hasPrefix(folder) }
    var seen = Set<String>()
    return (browsed + deeper).map(\.row).filter { seen.insert($0).inserted }.prefix(limit)
      .map(\.self)
  }

  private func runMentionSearch(
    _ query: String, search: @MainActor (String) async throws -> [String]
  ) async {
    do {
      let paths = try await search(query)
      guard mentionQuery == query else { return }
      if mentionCandidates != paths { mentionCandidates = paths }
      if mentionProblem != nil { mentionProblem = nil }
    } catch {
      guard mentionQuery == query else { return }
      mentionCandidates = []
      mentionProblem = "Workspace search failed: \(coreError(error).message)"
    }
  }
}

/// A workspace file or folder for the `@` menu.
public struct MentionEntry: Hashable, Sendable {
  /// Workspace-relative path, without a trailing `/`.
  public var path: String
  /// The last path component.
  public var name: String
  /// A folder rather than a file.
  public var isDirectory: Bool

  /// Creates an entry.
  /// - Parameters:
  ///   - path: Workspace-relative path.
  ///   - name: The last path component; derived from `path` when `nil`.
  ///   - isDirectory: A folder.
  public init(path: String, name: String? = nil, isDirectory: Bool) {
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    self.path = trimmed
    self.name = name ?? trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    self.isDirectory = isDirectory
  }

  /// The menu row: the path, with `/` after a folder.
  var row: String { isDirectory ? path + "/" : path }
}
