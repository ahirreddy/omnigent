import SwiftUI

/// The Changes tab without the app's workspace: the files the transcript reports changed.
struct ChangedFilesFallback: View {
  let state: ConversationViewState

  var body: some View {
    let files = state.sections.filter { $0.id.hasPrefix("files-") }.flatMap(
      SectionReading.changedFiles)
    if files.isEmpty {
      ContentUnavailableView("No changes", systemImage: "plus.forwardslash.minus")
    } else {
      List(files) { file in
        HStack(spacing: Theme.Spacing.small) {
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
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
        .help(file.path)
      }
      .listStyle(.plain)
    }
  }
}

/// The Pull Requests tab: the session's linked PRs, each opening its page.
struct PullRequestsPanel: View {
  let state: PullRequestsPanelState
  let open: (@MainActor (URL) -> Void)?
  let refresh: (@MainActor () -> Void)?

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView("Loading pull requests\u{2026}")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .unsupported:
        ContentUnavailableView(
          "Pull Requests", systemImage: "arrow.triangle.pull",
          description: Text("This server doesn't track pull requests."))
      case .failed(let message):
        ContentUnavailableView {
          Label("Couldn't Load Pull Requests", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          if let refresh { Button("Try Again", action: refresh) }
        }
      case .loaded(let pullRequests, let synced):
        if pullRequests.isEmpty {
          ContentUnavailableView(
            synced ? "No pull requests" : "Looking for pull requests",
            systemImage: "arrow.triangle.pull",
            description: Text(
              synced
                ? "Pull requests created or worked on in this session appear here."
                : "The server hasn't read this session's pull requests from its host yet."))
        } else {
          PullRequestList(pullRequests: pullRequests, open: open)
        }
      }
    }
    .task { refresh?() }
  }
}

/// Linked pull requests, newest first as the server orders them.
struct PullRequestList: View {
  let pullRequests: [PullRequestSummary]
  let open: (@MainActor (URL) -> Void)?

  var body: some View {
    if pullRequests.isEmpty {
      ContentUnavailableView(
        "No pull requests", systemImage: "arrow.triangle.pull",
        description: Text("Pull requests created or worked on in this session appear here."))
    } else {
      List(pullRequests) { request in
        Button {
          if let url = URL(string: request.url) { open?(url) }
        } label: {
          VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
            Text(request.title).lineLimit(2)
            HStack(spacing: Theme.Spacing.small) {
              Label(request.status.title, systemImage: Self.symbol(request.status))
                .foregroundStyle(Self.color(request.status))
              Text("\(request.repo) #\(request.number)").foregroundStyle(.secondary)
            }
            .font(.caption)
            if let detail = request.detail {
              Text(detail).font(.caption).foregroundStyle(.secondary)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(request.url)
        .accessibilityIdentifier("pr-\(request.id)")
      }
      .listStyle(.plain)
    }
  }

  static func symbol(_ status: PullRequestSummary.Status) -> String {
    switch status {
    case .merged: "arrow.triangle.merge"
    case .closed: "xmark.circle"
    case .conflicts, .failing: "exclamationmark.triangle"
    case .running: "clock"
    case .draft: "circle.dashed"
    case .ready, .open: "arrow.triangle.pull"
    case .unknown: "questionmark.circle"
    }
  }

  static func color(_ status: PullRequestSummary.Status) -> ThemeColor {
    switch status {
    case .ready, .open: .prGreen
    case .conflicts, .failing, .closed: .prRed
    case .running: .prAmber
    case .merged: .prPurple
    case .draft, .unknown: .secondary
    }
  }
}

/// The Agents tab: the session (or its parent) first, then each sub-agent with where it
/// stands and its latest activity. Choosing one opens its chat as a tab.
struct AgentsPanel: View {
  let state: ConversationViewState
  let open: (@MainActor (String) -> Void)?

  var body: some View {
    let children = SubagentGroup(state: state)?.children ?? []
    List {
      mainRow
      ForEach(children) { child in
        Button {
          open?(child.id)
        } label: {
          AgentRow(child: child)
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
        .help("Open \(child.title)")
        .accessibilityIdentifier("agents.child-\(child.id)")
      }
      if children.isEmpty {
        Text("Sub-agents this session starts appear here.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .listStyle(.plain)
  }

  /// A sub-agent's chat links back to its parent; otherwise the row is this session.
  @ViewBuilder private var mainRow: some View {
    if let parentID = state.header.settings?.parentId, parentID != state.header.id {
      Button {
        open?(parentID)
      } label: {
        Label("Parent session", systemImage: "arrow.turn.left.up")
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(open == nil)
      .accessibilityIdentifier("agents.parent")
    } else {
      Label(state.agentInfo?.name ?? "main", systemImage: "cpu")
        .font(.callout.weight(.semibold))
        .accessibilityIdentifier("agents.main")
    }
  }
}

private struct AgentRow: View {
  let child: SubagentChild

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.small) {
      status
        .frame(width: 18, height: 18)
        .help(child.status.title)
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        HStack(spacing: Theme.Spacing.extraSmall) {
          Text(child.title).lineLimit(1)
          if let agent = child.agent {
            Text(agent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        if let line = child.error ?? child.activity ?? child.goal {
          Text(line)
            .font(.caption)
            .foregroundStyle(child.error == nil ? ThemeColor.secondary : Theme.failure)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.leading, Theme.Spacing.medium)
    .contentShape(Rectangle())
    .opacity(child.status == .ready ? 0.75 : 1)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(child.title), \(child.status.title)")
  }

  /// The row's label carries the status, so the symbol is decoration.
  @ViewBuilder private var status: some View {
    switch child.status {
    case .running, .starting:
      ProgressView().controlSize(.mini)
    case .needsYou:
      Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.warning)
        .accessibilityHidden(true)
    case .failed:
      Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.failure)
        .accessibilityHidden(true)
    case .ready:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        .accessibilityHidden(true)
    }
  }
}
