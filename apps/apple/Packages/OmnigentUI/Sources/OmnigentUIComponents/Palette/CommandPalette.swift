public import SwiftUI

/// A native floating search sheet shared by Mac and hardware-keyboard iPad.
public struct CommandPalette: View {
  private let state: PaletteViewState
  private let commands: [PaletteEntry]
  private let perform: (PaletteTarget) -> Void
  private let search: (@MainActor (String, Int) async -> PaletteSearchResults)?
  @State private var query = ""
  /// Server matches for the current query, beyond the loaded sessions.
  @State private var found = PaletteSearchResults()
  /// How many server matches of each kind to ask for; Show more raises it.
  @State private var searchLimit = PaletteResults.searchPageSize
  /// Bumped by Retry, to search again.
  @State private var searchAttempt = 0
  @State private var isSearching = false
  @State private var scope: PaletteScope
  @State private var selection: String?
  @FocusState private var searchFocused: Bool
  @Environment(\.dismiss) private var dismiss

  /// Creates the palette with resolved, window-local actions.
  /// - Parameters:
  ///   - state: Loaded sessions and servers.
  ///   - commands: Commands.
  ///   - findsSessions: Opens scoped to sessions, searching by name (Option-Command-S).
  ///   - search: Server-side session search, debounced as the query changes.
  ///   - perform: Executes a destination.
  public init(
    state: PaletteViewState, commands: [PaletteEntry], findsSessions: Bool = false,
    search: (@MainActor (String, Int) async -> PaletteSearchResults)? = nil,
    perform: @escaping (PaletteTarget) -> Void
  ) {
    self.state = state
    self.commands = commands
    self.search = search
    self.perform = perform
    _scope = State(initialValue: findsSessions ? .sessions : .all)
  }

  private var sections: [PaletteSection] {
    PaletteResults.sections(
      scope: scope, query: query, commands: commands, state: state, found: found)
  }

  private var results: [PaletteEntry] { sections.flatMap(\.entries) }

  private var placeholder: String {
    switch scope {
    case .all: "Search sessions or run a command"
    case .sessions: "Search sessions by name"
    case .servers: "Find a server"
    }
  }

  /// Search, scoped results and keyboard help.
  public var body: some View {
    // One search per update: the list, the empty state and the selection share it.
    let sections = self.sections
    let results = sections.flatMap(\.entries)
    return VStack(spacing: 0) {
      HStack(spacing: Theme.Spacing.small) {
        Image(systemName: "magnifyingglass").accessibilityHidden(true)
        TextField(placeholder, text: $query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($searchFocused)
          .onSubmit { activateSelection() }
          .accessibilityIdentifier("palette-search")
        Button("Close", systemImage: "xmark") { dismiss() }
          .labelStyle(.iconOnly).buttonStyle(.plain)
          .accessibilityIdentifier("palette-close")
      }
      .padding(Theme.Spacing.large)
      HStack {
        Picker("Search scope", selection: $scope) {
          ForEach(PaletteScope.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).tint(Theme.secondary).labelsHidden().fixedSize()
        .accessibilityIdentifier("palette-scope")
        Spacer()
        Text(state.scope).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .padding(.horizontal, Theme.Spacing.large)
      .padding(.bottom, Theme.Spacing.small)
      Divider()
      ScrollViewReader { proxy in
        List {
          ForEach(sections) { section in
            Section(section.title) {
              ForEach(section.entries) { row($0) }
            }
          }
          if scope != .servers, search != nil, isTyping {
            PaletteSearchStatus(
              isSearching: isSearching, found: found, retry: { searchAttempt += 1 },
              showMore: { searchLimit += PaletteResults.searchPageSize })
          }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .overlay {
          if results.isEmpty, !isSearching, found.failure == nil {
            ContentUnavailableView.search(text: query)
          }
        }
        .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
      }
      Divider()
      HStack {
        Text("↑ ↓  Navigate     Return  Open     Esc  Close")
        Spacer()
        Text("⌘K")
      }
      .font(.caption).foregroundStyle(.secondary).padding(Theme.Spacing.medium)
    }
    .frame(idealWidth: 620, maxWidth: 720, minHeight: 360, idealHeight: 480)
    .themeCanvas()
    .presentationDetents([.large])
    .onAppear {
      searchFocused = true
      selection = results.first(where: \.isEnabled)?.id
    }
    .onChange(of: results) {
      if !results.contains(where: { $0.id == selection && $0.isEnabled }) {
        resetSelection(results)
      }
    }
    .onChange(of: query) {
      resetSelection(results)
      searchLimit = PaletteResults.searchPageSize
    }
    .task(id: PaletteSearchRequest(query: query, limit: searchLimit, attempt: searchAttempt)) {
      await searchServer()
    }
    .onChange(of: scope) { resetSelection(results) }
    .onKeyPress(.downArrow) {
      move(1)
      return .handled
    }
    .onKeyPress(.upArrow) {
      move(-1)
      return .handled
    }
    .onKeyPress(.escape) {
      dismiss()
      return .handled
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("command-palette")
  }

  private func row(_ entry: PaletteEntry) -> some View {
    Button {
      activate(entry)
    } label: {
      result(entry)
    }
    .buttonStyle(.plain)
    .disabled(!entry.isEnabled)
    .listRowBackground(
      Rectangle().fill(ThemeColor.selection.opacity(selection == entry.id ? 1 : 0))
    )
    .accessibilityIdentifier("palette-result-\(entry.id)")
    .id(entry.id)
  }

  private func result(_ entry: PaletteEntry) -> some View {
    HStack(spacing: Theme.Spacing.medium) {
      Image(systemName: entry.symbol).frame(width: 24).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        Text(PaletteSearch.highlighted(entry.title, query: query)).font(Theme.Typography.label)
        Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      Text(entry.shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
    }
    .padding(.vertical, Theme.Spacing.small)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  private var isTyping: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// Asks the server once typing pauses; a newer query cancels the wait.
  private func searchServer() async {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let search, !text.isEmpty else {
      found = PaletteSearchResults()
      isSearching = false
      return
    }
    isSearching = true
    do {
      try await Task.sleep(for: .milliseconds(250))
    } catch {
      // A newer query replaced this one.
      return
    }
    let results = await search(text, searchLimit)
    guard !Task.isCancelled else { return }
    found = results
    isSearching = false
  }

  private func resetSelection(_ results: [PaletteEntry]) {
    selection = results.first(where: \.isEnabled)?.id
  }

  private func move(_ offset: Int) {
    let enabled = results.filter(\.isEnabled)
    guard !enabled.isEmpty else {
      selection = nil
      return
    }
    let index = enabled.firstIndex { $0.id == selection } ?? 0
    selection = enabled[min(max(index + offset, 0), enabled.count - 1)].id
  }

  private func activateSelection() {
    if let entry = results.first(where: { $0.id == selection }) { activate(entry) }
  }

  private func activate(_ entry: PaletteEntry) {
    guard entry.isEnabled else { return }
    switch entry.target {
    case .findSession:
      scope = .sessions
      query = ""
    case .switchServer:
      scope = .servers
      query = ""
    default: perform(entry.target)
    }
  }
}
