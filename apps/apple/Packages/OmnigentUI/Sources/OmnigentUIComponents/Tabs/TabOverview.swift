public import SwiftUI

/// The strip's overview menu: every tab (the selected one checked), Show All Tabs, and the
/// recently closed tabs.
struct TabOverviewMenu: View {
  let state: TabsState
  let actions: TabActions
  let showAll: () -> Void

  var body: some View {
    Menu {
      Section {
        ForEach(state.tabs) { tab in
          Toggle(
            isOn: Binding(get: { tab.id == state.selectedID }, set: { _ in actions.select(tab.id) })
          ) {
            Label(tab.displayTitle, systemImage: tab.kind.systemImage)
          }
        }
      }
      Section {
        Button("Show All Tabs", systemImage: "square.grid.2x2", action: showAll)
        if let reopen = actions.reopenClosed {
          Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward", action: reopen)
        }
      }
      if actions.newRemoteBrowser != nil {
        Section { NewTabMenu(actions: actions) }
      }
      if !state.recentlyClosed.isEmpty {
        Section("Recently Closed") {
          ForEach(state.recentlyClosed.prefix(8)) { tab in
            Label(tab.displayTitle, systemImage: tab.kind.systemImage)
          }
        }
      }
    } label: {
      Image(systemName: "chevron.down")
        .accessibilityHidden(true)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 22, height: 26)
        .contentShape(Rectangle())
        .touchTarget(width: 22, height: 26)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .foregroundStyle(.secondary)
    .fixedSize()
    .help("Search and switch tabs")
    .accessibilityLabel("Tab overview, \(state.tabs.count) tabs")
    .accessibilityIdentifier("tab-overview")
  }
}

/// Every tab as a list: select, close (swipe or the close button), reorder, and open a new tab.
/// The Mac shows it from Show All Tabs; iPhone and iPad show ``TabGridOverview`` instead.
public struct TabOverviewSheet: View {
  private let state: TabsState
  private let actions: TabActions
  private let dismiss: @MainActor () -> Void

  @State private var query = ""

  /// Creates the sheet.
  /// - Parameters:
  ///   - state: The window's tabs.
  ///   - actions: What the tabs do.
  ///   - dismiss: Closes the sheet.
  public init(
    state: TabsState, actions: TabActions, dismiss: @escaping @MainActor () -> Void
  ) {
    self.state = state
    self.actions = actions
    self.dismiss = dismiss
  }

  private var matches: [TabItemState] {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return state.tabs }
    return state.tabs.filter {
      $0.displayTitle.localizedCaseInsensitiveContains(text)
        || ($0.subtitle?.localizedCaseInsensitiveContains(text) ?? false)
    }
  }

  /// The sheet.
  public var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(matches) { tab in row(tab) }
            .onMove { from, to in move(from: from, to: to) }
        }
        if let reopen = actions.reopenClosed, !state.recentlyClosed.isEmpty {
          Section("Recently Closed") {
            ForEach(state.recentlyClosed.prefix(10)) { tab in
              Label(tab.displayTitle, systemImage: tab.kind.systemImage)
                .foregroundStyle(.secondary)
            }
            Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") {
              reopen()
              dismiss()
            }
          }
        }
      }
      .overlay {
        if state.tabs.isEmpty {
          ContentUnavailableView(
            "No Tabs", systemImage: "square.on.square",
            description: Text("Open a session from the sidebar, or start a new tab."))
        }
      }
      .searchable(text: $query, prompt: "Search tabs")
      .navigationTitle("Tabs")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: dismiss)
            .accessibilityIdentifier("tab-overview-done")
        }
        ToolbarItem(placement: .primaryAction) {
          Button("New Tab", systemImage: "plus") {
            actions.newTab()
            dismiss()
          }
          .accessibilityIdentifier("tab-overview-new")
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 420, minHeight: 420)
    #endif
    .accessibilityIdentifier("tab-overview-sheet")
  }

  private func row(_ tab: TabItemState) -> some View {
    Button {
      actions.select(tab.id)
      dismiss()
    } label: {
      HStack(spacing: Theme.Spacing.medium) {
        TabIcon(tab: tab, isSelected: tab.id == state.selectedID)
        VStack(alignment: .leading, spacing: 2) {
          Text(tab.displayTitle).lineLimit(1)
          Text(Self.detail(tab))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        if tab.isPinned {
          Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
            .accessibilityLabel("Pinned")
        }
        TabStatusMark(status: tab.status)
        if tab.id == state.selectedID {
          Image(systemName: "checkmark").foregroundStyle(.primary)
            .accessibilityLabel("Selected")
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .swipeActions {
      if tab.isClosable {
        Button("Close", systemImage: "xmark", role: .destructive) { actions.close(tab.id) }
      }
    }
    .contextMenu {
      TabContextMenu(
        tab: tab, actions: actions, canCloseToRight: state.unpinned.last?.id != tab.id,
        isSplit: state.split != nil)
    }
    .accessibilityIdentifier("tab-overview-row-\(tab.id)")
  }

  /// The row's second line: the pane in a split window, the live state ("Needs you",
  /// "Running"), then the subtitle (the agent and project) or the kind.
  static func detail(_ tab: TabItemState) -> String {
    [tab.pane.map { "\($0.label) pane" }, tab.status.label, tab.subtitle ?? tab.kind.label]
      .compactMap(\.self)
      .joined(separator: " \u{00B7} ")
  }

  private func move(from source: IndexSet, to destination: Int) {
    let visible = matches
    guard let first = source.first, visible.indices.contains(first) else { return }
    let moved = visible[first]
    // `destination` inserts before a row of the (filtered) list; find that row in the whole
    // strip without the moved tab, which is the index the tab ends up at.
    let others = state.tabs.map(\.id).filter { $0 != moved.id }
    let index: Int
    if destination < visible.count {
      guard visible[destination].id != moved.id else { return }
      index = others.firstIndex(of: visible[destination].id) ?? others.count
    } else if let last = visible.last(where: { $0.id != moved.id }),
      let position = others.firstIndex(of: last.id)
    {
      index = position + 1
    } else {
      index = others.count
    }
    actions.move(moved.id, index)
  }
}

/// A toolbar button that opens the tab overview (``View/tabOverview(isPresented:state:actions:)``),
/// with the tab count, for widths without a strip.
public struct TabSwitcherButton: View {
  private let state: TabsState
  private let actions: TabActions
  /// Shown by the button itself where no window presenter is set (the gallery).
  @State private var isPresented = false
  @Environment(\.tabOverviewPresenter) private var presenter

  /// Creates the button.
  /// - Parameters:
  ///   - state: The window's tabs.
  ///   - actions: What the tabs do.
  public init(state: TabsState, actions: TabActions) {
    self.state = state
    self.actions = actions
  }

  /// The button.
  public var body: some View {
    Button {
      if let open = presenter?.open { open() } else { isPresented = true }
    } label: {
      // The count in the symbol, so the bar keeps it visible instead of folding it away.
      Label("Tabs (\(state.tabs.count))", systemImage: Self.symbol(count: state.tabs.count))
        .labelStyle(.iconOnly)
    }
    .help("Show all tabs")
    .accessibilityIdentifier("tab-switcher")
    .tabOverview(isPresented: $isPresented, state: state, actions: actions)
  }

  /// `3.square` for 1 to 50 tabs, else the generic tabs symbol.
  static func symbol(count: Int) -> String {
    (1...50).contains(count) ? "\(count).square" : "square.on.square"
  }
}
