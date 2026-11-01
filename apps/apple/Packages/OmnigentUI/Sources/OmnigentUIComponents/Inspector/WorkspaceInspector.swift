public import SwiftUI

/// The right panel's tabs: the web's Files, Changes, Pull Requests and Agents, plus the session's
/// terminals and a native Info tab with the session facts.
nonisolated public enum InspectorTab: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// Files.
  case files
  /// Changes.
  case changes
  /// Pull requests.
  case pullRequests
  /// Agents (sub-agents).
  case agents
  /// The session's terminals.
  case terminals
  /// Session facts (native).
  case info

  /// The tab itself.
  public var id: Self { self }

  /// The label.
  public var title: String {
    switch self {
    case .files: "Files"
    case .changes: "Changes"
    case .pullRequests: "Pull Requests"
    case .agents: "Agents"
    case .terminals: "Terminals"
    case .info: "Info"
    }
  }

  /// The SF Symbol.
  public var systemImage: String {
    switch self {
    case .files: "folder"
    case .changes: "plus.forwardslash.minus"
    case .pullRequests: "arrow.triangle.pull"
    case .agents: "cpu"
    case .terminals: "apple.terminal"
    case .info: "info.circle"
    }
  }
}

/// Content the app supplies for the Files, Changes and Terminals tabs (for example
/// `OmnigentWorkspaceUI`'s file tree and changed-files list, and `OmnigentTerminalUI`'s terminal
/// list with the attached surface). `nil` shows the built-in fallback.
public struct WorkspaceSlots {
  /// The Files tab.
  public var files: AnyView?
  /// The Changes tab.
  public var changes: AnyView?
  /// The Terminals tab.
  public var terminals: AnyView?

  /// Creates slots.
  /// - Parameters:
  ///   - files: Files content.
  ///   - changes: Changes content.
  ///   - terminals: Terminals content.
  public init(files: AnyView? = nil, changes: AnyView? = nil, terminals: AnyView? = nil) {
    self.files = files
    self.changes = changes
    self.terminals = terminals
  }
}

/// The right panel: a segmented tab picker with counts, then the tab.
public struct WorkspaceInspector: View {
  private let state: ConversationViewState
  private let actions: ConversationActions
  private let slots: WorkspaceSlots
  @Binding private var tab: InspectorTab

  /// Creates the panel.
  /// - Parameters:
  ///   - state: The conversation.
  ///   - actions: Host actions.
  ///   - slots: Files and Changes content.
  ///   - tab: The selected tab.
  public init(
    state: ConversationViewState, actions: ConversationActions, slots: WorkspaceSlots,
    tab: Binding<InspectorTab>
  ) {
    self.state = state
    self.actions = actions
    self.slots = slots
    _tab = tab
  }

  private var changedCount: Int {
    state.sections.filter { $0.id.hasPrefix("files-") }
      .reduce(0) { $0 + SectionReading.changedFiles($1).count }
  }

  private var children: [EventSection] { state.sections.filter { $0.id.hasPrefix("child-") } }

  /// The panel.
  public var body: some View {
    VStack(spacing: 0) {
      Picker("Panel", selection: $tab) {
        ForEach(InspectorTab.allCases) { tab in
          Label(label(for: tab), systemImage: tab.systemImage)
            .labelStyle(.iconOnly)
            .help(label(for: tab))
            .tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(8)
      .accessibilityIdentifier("inspector-tabs")
      Text(label(for: tab))
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
      Divider()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environment(\.conversationActions, actions)
  }

  private func label(for tab: InspectorTab) -> String {
    switch tab {
    case .changes where changedCount > 0: "Changes (\(changedCount))"
    case .pullRequests where !state.pullRequests.isEmpty:
      "Pull Requests (\(state.pullRequests.count))"
    case .agents where !children.isEmpty:
      "Agents (\(children.filter { $0.summary.lowercased() == "running" }.count)/\(children.count))"
    default: tab.title
    }
  }

  @ViewBuilder private var content: some View {
    switch tab {
    case .files:
      if let files = slots.files {
        files
      } else {
        ContentUnavailableView(
          "Files", systemImage: "folder",
          description: Text("The session's files appear here when its host is connected."))
      }
    case .changes:
      if let changes = slots.changes {
        changes
      } else {
        ChangedFilesFallback(state: state)
      }
    case .pullRequests:
      PullRequestList(pullRequests: state.pullRequests, open: actions.openURL)
    case .agents:
      AgentsList(children: children, open: actions.openSession)
    case .terminals:
      if let terminals = slots.terminals {
        terminals
      } else {
        ContentUnavailableView(
          "Terminals", systemImage: "apple.terminal",
          description: Text("The session's terminals appear here when its host is connected."))
      }
    case .info:
      SessionInspectorView(state: state, actions: actions)
    }
  }
}

private struct ChangedFilesFallback: View {
  let state: ConversationViewState

  var body: some View {
    let files = state.sections.filter { $0.id.hasPrefix("files-") }.flatMap(
      SectionReading.changedFiles)
    if files.isEmpty {
      ContentUnavailableView("No changes", systemImage: "plus.forwardslash.minus")
    } else {
      List(files) { file in
        HStack(spacing: 8) {
          Text(file.letter)
            .font(.caption.monospaced().weight(.bold))
            .foregroundStyle(
              file.letter == "D"
                ? Theme.failure : (file.letter == "A" ? Theme.success : Theme.warning)
            )
            .frame(width: 14)
          Text(URL(filePath: file.path).lastPathComponent)
          Text(URL(filePath: file.path).deletingLastPathComponent().relativePath)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.head)
        }
        .help(file.path)
      }
      .listStyle(.plain)
    }
  }
}

private struct PullRequestList: View {
  let pullRequests: [PullRequestSummary]
  let open: (@MainActor (URL) -> Void)?

  var body: some View {
    if pullRequests.isEmpty {
      ContentUnavailableView(
        "No pull requests", systemImage: "arrow.triangle.pull",
        description: Text(
          "Pull requests created in this session appear here. You can also link an existing PR."))
    } else {
      List(pullRequests) { request in
        Button {
          if let url = URL(string: request.url) { open?(url) }
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text(request.title).lineLimit(2)
            HStack(spacing: 6) {
              Label(request.status.title, systemImage: symbol(request.status))
                .foregroundStyle(color(request.status))
              Text("\(request.repo) #\(request.number)").foregroundStyle(.secondary)
            }
            .font(.caption)
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pr-\(request.id)")
      }
      .listStyle(.plain)
    }
  }

  private func symbol(_ status: PullRequestSummary.Status) -> String {
    switch status {
    case .merged: "arrow.triangle.merge"
    case .closed: "xmark.circle"
    case .conflicts, .failing: "exclamationmark.triangle"
    case .running: "clock"
    case .draft: "circle.dashed"
    case .ready, .open: "arrow.triangle.pull"
    }
  }

  private func color(_ status: PullRequestSummary.Status) -> ThemeColor {
    switch status {
    case .ready, .open: .prGreen
    case .conflicts, .failing, .closed: .prRed
    case .running: .prAmber
    case .merged: .prPurple
    case .draft: .secondary
    }
  }
}

private struct AgentsList: View {
  let children: [EventSection]
  let open: (@MainActor (String) -> Void)?

  var body: some View {
    if children.isEmpty {
      ContentUnavailableView(
        "No sub-agents", systemImage: "cpu",
        description: Text("Sub-agents this session starts appear here."))
    } else {
      List {
        Label("main", systemImage: "cpu").foregroundStyle(.secondary)
        ForEach(children) { child in
          Button {
            if let id = child.sessionId { open?(id) }
          } label: {
            HStack {
              Label(child.title, systemImage: "arrow.turn.down.right")
              Spacer()
              if child.summary.lowercased() == "running" {
                ProgressView().controlSize(.mini)
              } else {
                Text(child.summary).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          .buttonStyle(.plain)
          .disabled(open == nil)
        }
      }
      .listStyle(.plain)
    }
  }
}
