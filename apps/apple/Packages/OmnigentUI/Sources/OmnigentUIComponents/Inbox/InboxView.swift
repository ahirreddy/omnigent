import OmnigentWorkspaceUI
public import SwiftUI

/// A keyboard and touch triage list, with read state separate from pending requests.
public struct InboxView: View {
  private let state: InboxViewState
  private let actions: InboxActions
  @State private var filter = UserDefaults.standard.choice(
    Self.filterKey, default: InboxFilter.all)
  @State private var search = ""
  @State private var selection: String?
  @State private var expanded: Set<String> = []
  @State private var replies: [String: String] = [:]
  @FocusState private var focus: Focus?

  private enum Focus: Hashable { case list, search }

  /// The chosen filter, kept across visits and launches.
  static let filterKey = "omnigent.inbox.filter"

  /// Creates the Inbox from adapter state and supported actions.
  public init(state: InboxViewState, actions: InboxActions) {
    self.state = state
    self.actions = actions
  }

  private var filtered: [InboxItem] {
    InboxTriage.items(state.items, filter: filter, search: search, now: state.now ?? .now)
  }

  /// The triage list and its keyboard hints.
  public var body: some View {
    VStack(spacing: 0) {
      header
      ScrollViewReader { proxy in
        List {
          ForEach(InboxTriage.groups(filtered, now: state.now ?? .now), id: \.title) { group in
            Section(group.title) {
              ForEach(group.items) { item in row(item).id(item.id) }
            }
          }
          if state.isAssembling, !filtered.isEmpty {
            Label {
              Text("Checking remaining sessions\u{2026}")
            } icon: {
              ProgressView().controlSize(.small)
            }
            .font(.callout).foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("inbox-checking")
          }
          if state.hasMoreSessions, let loadMore = actions.loadMoreSessions {
            loadMoreRow(loadMore)
          }
        }
        .accessibilityIdentifier("inbox")
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .focusable()
        .focused($focus, equals: .list)
        .onKeyPress(characters: CharacterSet(charactersIn: "jk/e")) { press in
          guard focus == .list, press.modifiers.isEmpty else { return .ignored }
          switch press.characters {
          case "j": move(1)
          case "k": move(-1)
          case "/": focus = .search
          case "e": performPrimary()
          default: return .ignored
          }
          return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
          guard focus == .list, press.modifiers.isEmpty, let item = selected else {
            return .ignored
          }
          actions.open?(item)
          return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
          guard focus == .list, press.modifiers.isEmpty else { return .ignored }
          move(1)
          return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { press in
          guard focus == .list, press.modifiers.isEmpty else { return .ignored }
          move(-1)
          return .handled
        }
        .onChange(of: selection) { _, id in
          if let id { proxy.scrollTo(id) }
        }
        .overlay {
          if filtered.isEmpty { emptyState }
        }
      }
      #if os(macOS)
        Text(
          "J / K  Move    Return  Open    E or \u{2318}Return  Approve    E  Mark read    /  Search"
        )
        .font(.caption).foregroundStyle(.secondary)
        .padding(Theme.Spacing.small)
        .accessibilityIdentifier("inbox-keyboard-hints")
      #endif
    }
    .frame(maxWidth: Theme.inboxWidth)
    .frame(maxWidth: .infinity)
    .themeCanvas()
    .navigationTitle("Inbox")
    .onAppear { focus = .list }
    .onChange(of: filtered, initial: true) { previous, current in
      selection = InboxTriage.selection(selection, previous: previous, current: current)
      if let selection { expanded.insert(selection) }
    }
    .modifier(StoredPreference($filter, stored: AppStorage(wrappedValue: .all, Self.filterKey)))
    .countsRenders("inbox")
  }

  /// Loading until the items are read; the empty state only once nothing is left to read and
  /// nothing failed, so it never claims "nothing waiting" too early.
  @ViewBuilder private var emptyState: some View {
    if state.isAssembling, search.isEmpty {
      ProgressView("Loading inbox\u{2026}")
        .controlSize(.small)
        .accessibilityIdentifier("inbox-loading")
    } else if state.failedSessionCount == 0 || !search.isEmpty {
      ContentUnavailableView(
        search.isEmpty ? emptyTitle : "No matching items", systemImage: "tray",
        description: Text(emptyDescription))
    }
  }

  private var heading: some View {
    HStack(spacing: Theme.Spacing.small) {
      Text("Inbox").font(.title2)
        .accessibilityAddTraits(.isHeader)
      if !state.items.isEmpty {
        let summary = InboxTriage.summary(state.items)
        Text("\(state.items.count)")
          .font(.callout.weight(.medium)).monospacedDigit()
          .foregroundStyle(.background)
          .padding(.horizontal, Theme.Spacing.small)
          .padding(.vertical, 2)
          .background(.primary, in: Capsule())
          .help(summary)
          .accessibilityLabel(summary)
          .accessibilityIdentifier("inbox-count")
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      heading
      HStack {
        Picker("Filter", selection: $filter) {
          ForEach(InboxFilter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .tint(Theme.secondary)
        .accessibilityIdentifier("inbox-filter")
        // The shared attention model's session count, as the sidebar, Dock and menu bar show.
        if let count = state.needsYouCount {
          Text("\(count) \(count == 1 ? "needs" : "need") you").font(.caption).foregroundStyle(
            Theme.brandAccent
          )
          .accessibilityIdentifier("inbox-needs-you-count")
        }
      }
      TextField("Search Inbox", text: $search)
        .textFieldStyle(.roundedBorder)
        .focused($focus, equals: .search)
        .onSubmit { focus = .list }
        .accessibilityIdentifier("inbox-search")
      if state.failedSessionCount > 0 {
        HStack {
          Label(
            "Couldn\u{2019}t load inbox items from \(state.failedSessionCount) "
              + (state.failedSessionCount == 1 ? "session." : "sessions."),
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.red)
          Spacer()
          if let retry = actions.retry { Button("Retry", action: retry) }
        }
        .font(.callout)
        .accessibilityIdentifier("inbox-load-error")
      }
    }
    .padding(Theme.Spacing.medium)
  }

  /// The web's "Load more sessions": items of older sessions show once they load.
  private func loadMoreRow(_ loadMore: @escaping @MainActor () -> Void) -> some View {
    let title = state.isLoadingMoreSessions ? "Loading\u{2026}" : "Load more sessions"
    return Button(title, action: loadMore)
      .buttonStyle(.bordered)
      .disabled(state.isLoadingMoreSessions)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listRowSeparator(.hidden)
      .accessibilityIdentifier("inbox-load-more")
  }

  private var emptyTitle: String {
    // Older sessions may still hold items, as the web words it.
    if state.hasMoreSessions { return "Nothing waiting in these sessions" }
    return switch filter {
    case .all: "Nothing waiting on you"
    case .unread: "You’re all caught up"
    case .awaiting: "No approvals waiting"
    }
  }

  private var emptyDescription: String {
    switch filter {
    case .all:
      "When an agent replies or needs your input, or someone comments on a file, it will show up here."
    case .unread: "New agent replies and unseen file comments will show up here."
    case .awaiting: "When an agent needs your input, it will show up here."
    }
  }

  private var selected: InboxItem? { filtered.first { $0.id == selection } }

  private func move(_ offset: Int) {
    selection = InboxTriage.move(selection, by: offset, in: filtered)
    if let selection { expanded.insert(selection) }
  }

  private func performPrimary() {
    guard let item = selected else { return }
    if item.approvesDirectly, let card = item.decision {
      actions.respond?(card, .approve)
    } else if !item.isUnresolved, item.isUnread {
      actions.markRead?(item)
    }
  }

  private func row(_ item: InboxItem) -> some View {
    InboxRow(
      item: item, now: state.now, actions: actions,
      isSelected: selection == item.id,
      select: {
        selection = item.id
        focus = .list
      },
      isExpanded: Binding(
        get: { expanded.contains(item.id) },
        set: { if $0 { expanded.insert(item.id) } else { expanded.remove(item.id) } }),
      reply: Binding(get: { replies[item.id, default: ""] }, set: { replies[item.id] = $0 }))
  }
}
