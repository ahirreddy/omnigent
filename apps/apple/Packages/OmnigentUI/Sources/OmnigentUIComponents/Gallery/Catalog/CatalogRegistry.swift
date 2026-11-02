import Foundation

/// Every catalog entry, and search over them.
enum GalleryCatalog {
  /// Components, then pages, then flows.
  static let entries: [CatalogEntry] =
    DesignSystemCatalog.entries + TranscriptCatalog.entries + ComposerCatalog.entries
    + DecisionCatalog.entries + InboxCatalog.entries + SessionListCatalog.entries
    + InspectorCatalog.entries + TabsCatalog.entries + TabSplitCatalog.entries
    + SettingsCatalog.entries
    + NewSessionCatalog.entries + PageCatalog.entries + ConversationFlowCatalog.entries
    + NavigationFlowCatalog.entries + SignInCatalog.entries + CLICatalog.entries

  static func entry(_ id: String) -> CatalogEntry? {
    entries.first { $0.id == id }
  }

  /// The entries matching every whitespace-separated term of `query`, case- and
  /// diacritic-insensitively, in title, summary, area, section, id, keywords and state titles.
  static func search(_ entries: [CatalogEntry], query: String) -> [CatalogEntry] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return entries }
    return entries.filter { entry in
      let haystack = searchText(entry)
      return terms.allSatisfy { haystack.localizedStandardContains($0) }
    }
  }

  static func searchText(_ entry: CatalogEntry) -> String {
    ([
      entry.title, entry.summary, entry.area.title, entry.section.title, entry.id,
    ] + entry.keywords + entry.states.map(\.title)).joined(separator: " ")
  }

  /// `entries` of one section, grouped by area in catalog order.
  static func groups(_ entries: [CatalogEntry], section: CatalogSection) -> [(
    area: CatalogArea, entries: [CatalogEntry]
  )] {
    let inSection = entries.filter { $0.section == section }
    return CatalogArea.allCases.compactMap { area in
      let matches = inSection.filter { $0.area == area }
      return matches.isEmpty ? nil : (area, matches)
    }
  }

  /// The entries whose id or title contains any of `filters` (all entries when empty), for the
  /// snapshot export.
  static func filtered(_ entries: [CatalogEntry], by filters: [String]) -> [CatalogEntry] {
    guard !filters.isEmpty else { return entries }
    return entries.filter { entry in
      filters.contains {
        entry.id.localizedStandardContains($0) || entry.title.localizedStandardContains($0)
      }
    }
  }
}
