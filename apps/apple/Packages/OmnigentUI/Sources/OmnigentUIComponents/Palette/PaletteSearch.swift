import Foundation

/// UI-only fuzzy matching: exact and prefix matches lead compact subsequence matches.
nonisolated enum PaletteSearch {
  private struct Match {
    let score: Int
    let index: Int
    let entry: PaletteEntry
  }

  static func results(_ entries: [PaletteEntry], query: String) -> [PaletteEntry] {
    let query = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !query.isEmpty else { return entries }
    return entries.enumerated().compactMap { index, entry -> Match? in
      guard let rank = score(query, in: normalize(entry.title + " " + entry.detail)) else {
        return nil
      }
      return Match(score: rank, index: index, entry: entry)
    }.sorted { lhs, rhs in
      lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
    }.map(\.entry)
  }

  private static func normalize(_ text: String) -> String {
    text.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  private static func score(_ query: String, in text: String) -> Int? {
    if text.hasPrefix(query) { return 10_000 - text.count }
    if text.contains(query) { return 5_000 - text.count }
    let characters = Array(text)
    var cursor = 0
    var score = 0
    var previous = -2
    for character in query where !character.isWhitespace {
      guard let index = characters[cursor...].firstIndex(of: character) else { return nil }
      score += index == previous + 1 ? 20 : 1
      if index == 0 || characters[index - 1].isWhitespace { score += 10 }
      score -= index - cursor
      previous = index
      cursor = index + 1
    }
    return score
  }
}
