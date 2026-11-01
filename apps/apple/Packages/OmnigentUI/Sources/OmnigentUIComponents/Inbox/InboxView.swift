public import SwiftUI

/// The Inbox, as on the web: a filter (All, Unread, Awaiting response), groups by age, and rows
/// that expand in place to answer an approval or reply. Swipe or the context menu marks read.
public struct InboxView: View {
  private let state: InboxViewState
  private let actions: InboxActions
  @State private var filter: InboxFilter = .all
  @State private var expanded: Set<String> = []
  @State private var replies: [String: String] = [:]

  /// Creates the Inbox.
  /// - Parameters:
  ///   - state: Items.
  ///   - actions: Host actions.
  public init(state: InboxViewState, actions: InboxActions) {
    self.state = state
    self.actions = actions
  }

  private var filtered: [InboxItem] {
    state.items.filter { item in
      switch filter {
      case .all: true
      case .unread: item.isUnread
      case .awaiting: item.decision != nil
      }
    }
  }

  /// The Inbox.
  public var body: some View {
    let groups = InboxGrouping.groups(filtered, now: state.now ?? Date())
    List {
      ForEach(groups, id: \.title) { group in
        Section(group.title) {
          ForEach(group.items) { item in
            row(item)
          }
        }
      }
    }
    .overlay {
      if filtered.isEmpty {
        ContentUnavailableView(
          emptyTitle, systemImage: "tray",
          description: Text(filter == .all ? "You\u{2019}re all caught up" : ""))
      }
    }
    .scrollContentBackground(.hidden)
    .themeCanvas()
    .navigationTitle("Inbox")
    #if os(macOS)
      .navigationSubtitle(state.items.isEmpty ? "" : "\(state.items.count) items")
    #endif
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Filter", selection: $filter) {
          ForEach(InboxFilter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
      }
    }
    .accessibilityIdentifier("inbox")
  }

  private var emptyTitle: String {
    switch filter {
    case .all: "Nothing waiting on you"
    case .unread: "Nothing unread"
    case .awaiting: "No approvals waiting"
    }
  }

  private func row(_ item: InboxItem) -> some View {
    InboxRow(
      item: item, now: state.now ?? Date(), actions: actions,
      isExpanded: Binding(
        get: { expanded.contains(item.id) },
        set: { if $0 { expanded.insert(item.id) } else { expanded.remove(item.id) } }),
      reply: Binding(get: { replies[item.id, default: ""] }, set: { replies[item.id] = $0 }))
  }
}

/// "Just now", "Earlier today", "Yesterday", "This week", "Older".
nonisolated enum InboxGrouping {
  struct Group {
    let title: String
    let items: [InboxItem]
  }

  static func groups(_ items: [InboxItem], now: Date, calendar: Calendar = .current) -> [Group] {
    let titles = ["Just now", "Earlier today", "Yesterday", "This week", "Older"]
    var buckets: [String: [InboxItem]] = [:]
    for item in items {
      let title: String
      if now.timeIntervalSince(item.date) < 3_600 {
        title = "Just now"
      } else if calendar.isDate(item.date, inSameDayAs: now) {
        title = "Earlier today"
      } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
        calendar.isDate(item.date, inSameDayAs: yesterday)
      {
        title = "Yesterday"
      } else if now.timeIntervalSince(item.date) < 7 * 86_400 {
        title = "This week"
      } else {
        title = "Older"
      }
      buckets[title, default: []].append(item)
    }
    return titles.compactMap { title in buckets[title].map { Group(title: title, items: $0) } }
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
    .themeCanvas()
    .navigationTitle("Canvas")
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Board", selection: $board) {
          Text("Main").tag("Main")
        }
        .fixedSize()
      }
    }
    .accessibilityIdentifier("canvas")
  }

  private func card(_ session: SessionSummary) -> some View {
    Button {
      open?(session.id)
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        Text(session.title).font(.headline).lineLimit(2)
        Text(session.preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        Spacer(minLength: 0)
        HStack {
          Text(session.agentName).font(.caption).foregroundStyle(.secondary)
          Spacer()
          if session.status == .running { ProgressView().controlSize(.mini) }
        }
      }
      .padding(12)
      .frame(width: 280, height: 132, alignment: .topLeading)
      .cardSurface(cornerRadius: Theme.Radius.large)
    }
    .buttonStyle(.plain)
  }
}

private struct InboxRow: View {
  let item: InboxItem
  let now: Date
  let actions: InboxActions
  @Binding var isExpanded: Bool
  @Binding var reply: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(alignment: .top, spacing: 8) {
          Circle()
            .fill(item.isUnread ? Theme.brandAccent : ThemeColor.secondary.opacity(0))
            .frame(width: 7, height: 7)
            .padding(.top, 6)
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              Text(item.kind.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.decision != nil ? Theme.brandAccent : Theme.secondary)
              Spacer()
              Text(RelativeTime.short(item.date, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(item.sessionTitle).fontWeight(.medium).lineLimit(1)
            Text(item.preview).font(.callout).foregroundStyle(.secondary).lineLimit(
              isExpanded ? nil : 2)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      if isExpanded {
        if let decision = item.decision {
          DecisionCardView(
            card: decision, respond: actions.respond.map { respond in { respond(decision, $0) } })
        } else if let send = actions.reply {
          HStack {
            TextField("Reply\u{2026}", text: $reply)
              .textFieldStyle(.roundedBorder)
            Button("Send") {
              send(item, reply)
              reply = ""
            }
            .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
        HStack {
          if let open = actions.open { Button("Open session") { open(item) } }
          if let markRead = actions.markRead, item.isUnread {
            Button("Mark as read") { markRead(item) }
          }
        }
        .buttonStyle(.borderless)
      }
    }
    .padding(.vertical, 4)
    .contextMenu {
      if let open = actions.open { Button("Open session") { open(item) } }
      if let markRead = actions.markRead, item.isUnread {
        Button("Mark as read") { markRead(item) }
      }
    }
    #if os(iOS)
      .swipeActions {
        if let markRead = actions.markRead, item.isUnread {
          Button("Mark as Read", systemImage: "envelope.open") { markRead(item) }
        }
      }
    #endif
    .accessibilityIdentifier("inbox-\(item.id)")
  }
}
