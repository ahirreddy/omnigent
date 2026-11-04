import Foundation

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

  /// Searches the workspace when the typed mention changes, after a short pause, and clears
  /// the results when no mention is being typed.
  func mentionTextChanged() {
    guard let search = searchMentions else { return }
    let query = Self.mentionQuery(in: text)
    guard query != mentionQuery else { return }
    mentionQuery = query
    mentionTask?.cancel()
    guard let query, !query.isEmpty else {
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
