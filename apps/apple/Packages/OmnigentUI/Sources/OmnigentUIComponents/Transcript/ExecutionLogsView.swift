public import SwiftUI

/// One stored item, as raw JSON.
nonisolated public struct ExecutionLogItem: Hashable, Sendable {
  /// Its id, when it has one.
  public var id: String?
  /// The item on one line.
  public var compact: String
  /// The item indented.
  public var pretty: String

  /// Creates an item.
  /// - Parameters:
  ///   - id: Its id.
  ///   - compact: One line.
  ///   - pretty: Indented.
  public init(id: String?, compact: String, pretty: String) {
    self.id = id
    self.compact = compact
    self.pretty = pretty
  }
}

/// A page of items, oldest first.
nonisolated public struct ExecutionLogPage: Hashable, Sendable {
  /// The items.
  public var items: [ExecutionLogItem]
  /// Where the next page starts; `nil` on the last.
  public var next: String?

  /// Creates a page.
  /// - Parameters:
  ///   - items: The items.
  ///   - next: The next page's start.
  public init(items: [ExecutionLogItem], next: String?) {
    self.items = items
    self.next = next
  }
}

/// Where the execution logs come from: the session and its sub-agents, read a page at a time.
public struct ExecutionLogSource {
  /// A session whose items can be read.
  public struct Session: Hashable, Identifiable {
    /// Its id.
    public var id: String
    /// "main", or the sub-agent's title.
    public var title: String
    /// The session itself, not a sub-agent.
    public var isMain: Bool

    /// Creates a session.
    /// - Parameters:
    ///   - id: Its id.
    ///   - title: Its title.
    ///   - isMain: The session itself.
    public init(id: String, title: String, isMain: Bool) {
      self.id = id
      self.title = title
      self.isMain = isMain
    }
  }

  /// The session first, then its sub-agents.
  public var sessions: [Session]
  /// Reads a session's page after a cursor: the page, or why it failed.
  public var read: @MainActor (String, String?) async -> Result<ExecutionLogPage, LogReadFailure>
  /// The session's agent is working, so the items are read again every few seconds.
  public var isRunning: @MainActor () -> Bool
  /// Reads the events a session's live stream delivered after an index; `nil` offers only the
  /// stored items.
  public var stream: (@MainActor (String, UInt64?) -> [ExecutionStreamEvent])?

  /// Creates a source.
  /// - Parameters:
  ///   - sessions: The session and its sub-agents.
  ///   - read: Reads a page.
  ///   - isRunning: The agent is working.
  ///   - stream: Reads the live stream's events.
  public init(
    sessions: [Session],
    read: @escaping @MainActor (String, String?) async -> Result<ExecutionLogPage, LogReadFailure>,
    isRunning: @escaping @MainActor () -> Bool,
    stream: (@MainActor (String, UInt64?) -> [ExecutionStreamEvent])? = nil
  ) {
    self.sessions = sessions
    self.read = read
    self.isRunning = isRunning
    self.stream = stream
  }
}

/// Why items could not be read.
nonisolated public struct LogReadFailure: Error, Hashable, Sendable {
  /// What to show.
  public var message: String

  /// Creates a failure.
  /// - Parameter message: What to show.
  public init(message: String) { self.message = message }
}

/// A session's execution logs (the web's `ExecutionLogsPanel`): every stored item as raw JSON,
/// numbered from the oldest, one line each until opened, for the session or one of its
/// sub-agents. While the agent works the items are read again every three seconds. The SSE view
/// shows the live stream's events instead.
public struct ExecutionLogsView: View {
  private let source: ExecutionLogSource
  private let close: @MainActor () -> Void
  @State private var sessionID: String
  @State private var items: [ExecutionLogItem] = []
  @State private var next: String?
  @State private var pages = 0
  @State private var failure: String?
  @State private var isLoading = true
  @State private var opened: Set<Int> = []
  @State private var mode = ExecutionLogMode.items

  /// Creates the view.
  /// - Parameters:
  ///   - source: The sessions and their items.
  ///   - close: Closes it.
  public init(source: ExecutionLogSource, close: @escaping @MainActor () -> Void) {
    self.source = source
    self.close = close
    _sessionID = State(initialValue: source.sessions.first?.id ?? "")
  }

  /// The view.
  public var body: some View {
    NavigationStack {
      shown
        .navigationTitle("Execution Logs")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
          if source.sessions.count > 1 {
            ToolbarItem(placement: .principal) { sessionPicker }
          }
          if source.stream != nil {
            ToolbarItem(placement: .primaryAction) { modePicker }
          }
        }
    }
    #if os(macOS)
      .frame(minWidth: 520, minHeight: 420)
    #endif
    .task(id: sessionID) { await follow() }
  }

  @ViewBuilder private var shown: some View {
    if mode == .stream, let stream = source.stream {
      ExecutionStreamLogView(sessionID: sessionID, read: stream)
    } else {
      content
    }
  }

  /// Stored items or the live stream, as the web's Items / SSE switch.
  private var modePicker: some View {
    Picker("View", selection: $mode) {
      ForEach(ExecutionLogMode.allCases, id: \.self) { Text($0.title).tag($0) }
    }
    .pickerStyle(.segmented)
    .fixedSize()
    .accessibilityIdentifier("execution-logs-mode")
  }

  private var sessionPicker: some View {
    Picker("Session", selection: $sessionID) {
      ForEach(source.sessions) { session in
        Label(session.title, systemImage: session.isMain ? "bubble.left" : "cpu").tag(session.id)
      }
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier("execution-logs-session")
  }

  @ViewBuilder private var content: some View {
    if isLoading, items.isEmpty {
      ProgressView("Loading\u{2026}").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let failure, items.isEmpty {
      ContentUnavailableView(
        "Failed to Load Items", systemImage: "exclamationmark.triangle",
        description: Text(failure))
    } else if items.isEmpty {
      ContentUnavailableView("No Items", systemImage: "doc.text")
    } else {
      List {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          row(item, number: index + 1)
        }
        if next != nil {
          Text(isLoading ? "Loading more\u{2026}" : "")
            .frame(maxWidth: .infinity)
            .foregroundStyle(.secondary)
            .onAppear { Task { await loadMore() } }
        }
      }
      .font(.callout.monospaced())
      .accessibilityIdentifier("execution-logs")
    }
  }

  private func row(_ item: ExecutionLogItem, number: Int) -> some View {
    DisclosureGroup(
      isExpanded: Binding(
        get: { opened.contains(number) },
        set: { isOpen in
          if isOpen { opened.insert(number) } else { opened.remove(number) }
        })
    ) {
      Text(item.pretty).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    } label: {
      HStack(spacing: 6) {
        Text("#\(number)").foregroundStyle(.secondary)
        if !opened.contains(number) {
          Text(item.compact).lineLimit(1).truncationMode(.tail)
        }
      }
    }
    .accessibilityIdentifier("execution-log-entry")
  }

  /// Reads the chosen session from its first item, then again every three seconds while its
  /// agent works, keeping the pages already read.
  private func follow() async {
    items = []
    next = nil
    pages = 0
    opened = []
    failure = nil
    await reload(pages: 1)
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      if source.isRunning() { await reload(pages: max(pages, 1)) }
    }
  }

  /// Reads the first `count` pages again.
  private func reload(pages count: Int) async {
    isLoading = true
    defer { isLoading = false }
    var read: [ExecutionLogItem] = []
    var cursor: String?
    var loaded = 0
    repeat {
      switch await source.read(sessionID, cursor) {
      case .success(let page):
        read += page.items
        cursor = page.next
        loaded += 1
      case .failure(let error):
        failure = error.message
        return
      }
    } while loaded < count && cursor != nil
    items = read
    next = cursor
    pages = loaded
    failure = nil
  }

  private func loadMore() async {
    guard let cursor = next, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    switch await source.read(sessionID, cursor) {
    case .success(let page):
      items += page.items
      next = page.next
      pages += 1
    case .failure(let error):
      failure = error.message
    }
  }
}
