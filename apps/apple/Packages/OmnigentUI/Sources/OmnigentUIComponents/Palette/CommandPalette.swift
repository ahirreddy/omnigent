public import SwiftUI

/// A native floating search sheet shared by Mac and hardware-keyboard iPad.
public struct CommandPalette: View {
  private let state: PaletteViewState
  private let commands: [PaletteEntry]
  private let perform: (PaletteTarget) -> Void
  @State private var query = ""
  @State private var scope: Scope = .all
  @State private var selection: String?
  @FocusState private var searchFocused: Bool
  @Environment(\.dismiss) private var dismiss

  private enum Scope: String, CaseIterable, Identifiable {
    case all = "All"
    case sessions = "Sessions"
    case servers = "Servers"
    var id: Self { self }
  }

  /// Creates the palette with resolved, window-local actions.
  public init(
    state: PaletteViewState, commands: [PaletteEntry], perform: @escaping (PaletteTarget) -> Void
  ) {
    self.state = state
    self.commands = commands
    self.perform = perform
  }

  private var results: [PaletteEntry] {
    let entries: [PaletteEntry]
    switch scope {
    case .all: entries = commands + state.sessions
    case .sessions: entries = state.sessions
    case .servers: entries = state.servers
    }
    return PaletteSearch.results(entries, query: query)
  }

  /// Search, scoped results and keyboard help.
  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: Theme.Spacing.small) {
        Image(systemName: "magnifyingglass").accessibilityHidden(true)
        TextField("Find a session or command", text: $query)
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
          ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
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
        List(results) { entry in
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
        .listStyle(.plain).scrollContentBackground(.hidden)
        .overlay {
          if results.isEmpty {
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
      if !results.contains(where: { $0.id == selection && $0.isEnabled }) { resetSelection() }
    }
    .onChange(of: query) { resetSelection() }
    .onChange(of: scope) { resetSelection() }
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

  private func result(_ entry: PaletteEntry) -> some View {
    HStack(spacing: Theme.Spacing.medium) {
      Image(systemName: entry.symbol).frame(width: 24).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        Text(entry.title).font(Theme.Typography.label)
        Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      Text(entry.shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
    }
    .padding(.vertical, Theme.Spacing.small)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  private func resetSelection() { selection = results.first(where: \.isEnabled)?.id }

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
