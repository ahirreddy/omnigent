public import SwiftUI

/// A keyboard and touch triage list, with read state separate from pending requests.
public struct InboxView: View {
  private let state: InboxViewState
  private let actions: InboxActions
  @State private var filter: InboxFilter = .awaiting
  @State private var search = ""
  @State private var selection: String?
  @State private var expanded: Set<String> = []
  @State private var replies: [String: String] = [:]
  @FocusState private var focus: Focus?

  private enum Focus: Hashable { case list, search }

  /// Creates the Inbox from adapter state and supported actions.
  public init(state: InboxViewState, actions: InboxActions) {
    self.state = state
    self.actions = actions
  }

  private var filtered: [InboxItem] {
    InboxTriage.items(state.items, filter: filter, search: search)
  }

  /// The triage list and its keyboard hints.
  public var body: some View {
    VStack(spacing: 0) {
      header
      ScrollViewReader { proxy in
        List {
          ForEach(InboxTriage.groups(filtered), id: \.title) { group in
            Section(group.title) {
              ForEach(group.items) { item in row(item).id(item.id) }
            }
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
          if filtered.isEmpty {
            ContentUnavailableView(
              search.isEmpty ? emptyTitle : "No matching items", systemImage: "tray",
              description: Text("Unread updates and pending requests are tracked separately."))
          }
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
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
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
    }
    .padding(Theme.Spacing.medium)
  }

  private var emptyTitle: String {
    switch filter {
    case .all: "You’re all caught up"
    case .unread: "Nothing unread"
    case .awaiting: "Nothing waiting on you"
    }
  }

  private var selected: InboxItem? { filtered.first { $0.id == selection } }

  private func move(_ offset: Int) {
    selection = InboxTriage.move(selection, by: offset, in: filtered)
    if let selection { expanded.insert(selection) }
  }

  private func performPrimary() {
    guard let item = selected else { return }
    if item.canApprove, let card = item.decision {
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

/// The Canvas: a board of session cards (one per project plus Main). Cards can be dragged; their
/// positions are local to this device.
public struct CanvasView: View {
  private let sessions: [SessionSummary]
  private let open: (@MainActor (String) -> Void)?
  @State private var offsets: [String: CGSize] = [:]
  @State private var board = "Main"

  /// Creates the canvas.
  /// - Parameters:
  ///   - sessions: Sessions to place.
  ///   - open: Open a session.
  public init(sessions: [SessionSummary], open: (@MainActor (String) -> Void)? = nil) {
    self.sessions = sessions
    self.open = open
  }

  /// The board.
  public var body: some View {
    ScrollView([.horizontal, .vertical]) {
      ZStack(alignment: .topLeading) {
        Canvas { context, size in
          for column in stride(from: 0.0, through: size.width, by: 32) {
            for row in stride(from: 0.0, through: size.height, by: 32) {
              context.fill(
                Path(ellipseIn: CGRect(x: column, y: row, width: 2, height: 2)),
                with: .color(.secondary.opacity(0.3)))
            }
          }
        }
        .frame(width: 1_400, height: 900)
        ForEach(Array(sessions.prefix(12).enumerated()), id: \.element.id) { index, session in
          card(session)
            .offset(
              x: CGFloat(32 + (index % 4) * 320) + (offsets[session.id]?.width ?? 0),
              y: CGFloat(32 + (index / 4) * 164) + (offsets[session.id]?.height ?? 0)
            )
            .gesture(
              DragGesture().onChanged { value in offsets[session.id] = value.translation })
        }
      }
    }
    // On the board, not the screen: the toolbar's picker would otherwise take it too.
    .accessibilityIdentifier("canvas")
    .themeCanvas()
    .navigationTitle("Canvas")
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Board", selection: $board) {
          Text("Main").tag("Main")
        }
        .fixedSize()
        .accessibilityIdentifier("canvas-board")
      }
    }
  }

  private func card(_ session: SessionSummary) -> some View {
    Button {
      open?(session.id)
    } label: {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Text(session.title).font(.headline).lineLimit(2)
        Text(session.preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        Spacer(minLength: 0)
        HStack {
          Text(session.agentName).font(.caption).foregroundStyle(.secondary)
          Spacer()
          if session.status == .running { ProgressView().controlSize(.mini) }
        }
      }
      .padding(Theme.Spacing.medium)
      .frame(width: 280, height: 132, alignment: .topLeading)
      .cardSurface(cornerRadius: Theme.Radius.large)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("canvas-card-\(session.id)")
  }
}
