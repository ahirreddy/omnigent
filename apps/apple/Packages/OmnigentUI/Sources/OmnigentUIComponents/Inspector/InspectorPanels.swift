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
