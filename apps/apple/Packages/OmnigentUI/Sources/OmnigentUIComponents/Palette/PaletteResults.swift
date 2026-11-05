import Foundation

/// What the palette searches: everything, sessions by name (Option-Command-S), or servers.
nonisolated enum PaletteScope: String, CaseIterable, Identifiable, Sendable {
  case all = "All"
  case sessions = "Sessions"
  case servers = "Servers"

  var id: Self { self }
}

/// A titled group of palette results.
nonisolated struct PaletteSection: Hashable, Sendable, Identifiable {
  let title: String
  let entries: [PaletteEntry]

  var id: String { title }
}

/// The palette's result groups in the web's order: sessions (up to five recent ones before the
/// user types), then "In messages", then actions.
nonisolated enum PaletteResults {
  /// Recent sessions shown before typing, so the actions stay in view.
  static let idleSessionLimit = 5
  /// Server matches asked for at a time, of each kind; Show more asks for this many more.
  static let searchPageSize = 10

  /// The groups for a scope and query.
  /// - Parameters:
  ///   - scope: What is searched.
  ///   - query: The typed text.
  ///   - commands: The actions.
  ///   - state: Loaded sessions and servers.
  ///   - found: Server matches for the query.
  /// - Returns: Non-empty groups, in display order.
  static func sections(
    scope: PaletteScope, query: String, commands: [PaletteEntry], state: PaletteViewState,
    found: PaletteSearchResults
  ) -> [PaletteSection] {
    let typing = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let sections: [PaletteSection]
    switch scope {
    case .servers:
      sections = [PaletteSection(title: "Servers", entries: search(state.servers, query))]
    case .sessions:
      sections = [
        PaletteSection(
          title: "Sessions", entries: sessions(state, query, found, titlesOnly: true))
      ]
    case .all where !typing:
      sections = [
        PaletteSection(
          title: "Sessions", entries: Array(state.sessions.prefix(idleSessionLimit))),
        PaletteSection(title: "Actions", entries: commands),
      ]
    case .all:
      let titles = sessions(state, query, found)
      var shown = Set(titles.map(\.target))
      sections = [
        PaletteSection(title: "Sessions", entries: titles),
        PaletteSection(
          title: "In messages", entries: found.messages.filter { shown.insert($0.target).inserted }
        ),
        PaletteSection(title: "Actions", entries: search(commands, query)),
      ]
    }
    return sections.filter { !$0.entries.isEmpty }
  }

  /// Loaded sessions that match, then the server's title matches not already listed.
  private static func sessions(
    _ state: PaletteViewState, _ query: String, _ found: PaletteSearchResults,
    titlesOnly: Bool = false
  ) -> [PaletteEntry] {
    let local = PaletteSearch.results(state.sessions, query: query, titlesOnly: titlesOnly)
    var shown = Set(local.map(\.target))
    return local + found.titles.filter { shown.insert($0.target).inserted }
  }

  private static func search(_ entries: [PaletteEntry], _ query: String) -> [PaletteEntry] {
    PaletteSearch.results(entries, query: query)
  }
}
