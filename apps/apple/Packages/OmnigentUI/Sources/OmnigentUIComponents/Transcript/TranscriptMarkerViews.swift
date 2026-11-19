import SwiftUI

/// What a marker row says, shared by the chat and CLI styles.
nonisolated enum TranscriptMarker {
  /// The symbol a `[System: …]` notice shows for its kind (the web's `SystemMessageView`).
  static func noticeSymbol(_ kind: String?) -> String {
    switch kind {
    case "task_completed": "checkmark.circle"
    case "task_failed": "exclamationmark.circle"
    case "task_cancelled", "interrupted": "nosign"
    case "timer_fired": "bell"
    case "terminal_idle": "apple.terminal"
    default: "info.circle"
    }
  }

  /// A notice's body, when it has one worth opening.
  static func noticeBody(_ activity: Activity) -> String? {
    guard let body = activity.detail("body"),
      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return body
  }

  /// The session a sub-agent marker opens.
  static func childSession(_ activity: Activity) -> String? {
    guard activity.kind == .subagentMarker else { return nil }
    return activity.detail("session")
  }

  /// A task marker that waits for the reader ("Waiting for you on …").
  static func waitsForReader(_ activity: Activity) -> Bool {
    activity.kind == .taskMarker && activity.status == "needs_input"
  }

  /// A plan line ("Made a plan: …"), which opens the Tasks tab.
  static func isPlanLine(_ activity: Activity) -> Bool {
    activity.kind == .taskMarker && activity.status == "plan"
  }

  /// The task a task marker is about.
  static func task(_ activity: Activity) -> String? {
    guard activity.kind == .taskMarker, !isPlanLine(activity) else { return nil }
    return activity.detail("task")
  }

  /// The CLI style's Show in Tasks for a plan line or a task the tab still lists.
  @MainActor
  static func tasksAction(_ activity: Activity, rowID: String, links: TaskMarkerLinks?)
    -> CLIAction?
  {
    guard let links else { return nil }
    let listed = links.listed()
    guard listed.isShown else { return nil }
    let task = Self.task(activity)
    guard isPlanLine(activity) || task.map(listed.contains) == true else { return nil }
    return CLIAction(
      title: "Show in Tasks", systemImage: "checklist",
      identifier: "task-marker-open-\(rowID)", perform: { links.open(task) })
  }

  /// Why a task marker links nowhere: its plan, or the agent's list, dropped the task.
  static func droppedNote(_ activity: Activity) -> String {
    let list = activity.detail("list") == "The agent's tasks" ? "task list" : "plan"
    let note = activity.detail("text").map { "\($0) \u{00B7} " } ?? ""
    return "\(note)No longer in the \(list)"
  }
}

/// A runtime `[System: …]` notice, as the web's `SystemMessageView` shows it: centered and
/// muted, its kind's symbol and "System: <label>", its body opening under it.
struct SystemNoticeRowView: View {
  let row: Row
  let activity: Activity
  @RowDisclosure private var disclosure

  private var disclosureKey: String { "notice-\(row.id)" }
  private var isExpanded: Bool { disclosure.choice(disclosureKey) ?? false }

  var body: some View {
    let body = TranscriptMarker.noticeBody(activity)
    VStack(spacing: Theme.Spacing.extraSmall) {
      if body != nil {
        Button {
          disclosure.choose(!isExpanded, for: disclosureKey)
        } label: {
          header(opens: true)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows details")
        .accessibilityIdentifier("system-notice-toggle-\(row.id)")
      } else {
        header(opens: false)
      }
      if let body, isExpanded {
        Text(verbatim: body)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(24)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, Theme.Spacing.medium)
          .padding(.vertical, Theme.Spacing.small)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("system-notice-\(row.id)")
  }

  private func header(opens: Bool) -> some View {
    HStack(spacing: Theme.Spacing.small) {
      Image(systemName: TranscriptMarker.noticeSymbol(activity.status))
        .accessibilityHidden(true)
      Text("\(Text("System:").fontWeight(.semibold)) \(activity.title)")
        .fixedSize(horizontal: false, vertical: true)
      if opens {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .accessibilityHidden(true)
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .padding(.horizontal, Theme.Spacing.small)
    .padding(.vertical, Theme.Spacing.tiny)
    .contentShape(Rectangle())
  }
}

/// A sub-agent's or a task's start or end, or a plan change, as the web's
/// `SubagentActivityMessage` and `TaskActivityMessage` show them: a pill between dashed rules,
/// its label muted and its subject in the text color. A sub-agent's title opens its session.
struct ActivityMarkerRowView: View {
  let row: Row
  let activity: Activity
  @Environment(\.conversationActions) private var actions
  @Environment(\.taskMarkerLinks) private var taskLinks

  var body: some View {
    let listed = taskLinks?.listed() ?? .hidden
    HStack(spacing: Theme.Spacing.small) {
      DashedRule()
      HStack(spacing: Theme.Spacing.small) {
        Image(systemName: activity.kind.systemImage)
          .accessibilityHidden(true)
        line(listed)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.tiny)
      .layoutPriority(1)
      DashedRule()
    }
    .padding(.vertical, Theme.Spacing.extraSmall)
    // A row with a link keeps the button its own element, which combining would fold away.
    .accessibilityElement(children: hasLink(listed) ? .contain : .combine)
    .accessibilityLabel(row.text)
    .accessibilityIdentifier(
      activity.kind == .subagentMarker ? "subagent-marker-\(row.id)" : "task-marker-\(row.id)")
  }

  /// Whether the line shows a button: the Tasks tab's, or the sub-agent's session.
  private func hasLink(_ listed: ListedTasks) -> Bool {
    if TranscriptMarker.isPlanLine(activity), listed.isShown { return true }
    if let task = TranscriptMarker.task(activity), listed.isShown { return listed.contains(task) }
    return !activity.summary.isEmpty && TranscriptMarker.childSession(activity) != nil
      && (actions.openChild ?? actions.openSession) != nil
  }

  /// The label and subject, linked to the Tasks tab while it lists them.
  @ViewBuilder private func line(_ listed: ListedTasks) -> some View {
    let tint = TranscriptMarker.waitsForReader(activity) ? Theme.brandAccent : Theme.secondary
    let label = Text(activity.title).foregroundStyle(tint)
    if TranscriptMarker.isPlanLine(activity), listed.isShown {
      // A plan line opens the Tasks tab, as on the web.
      Button(activity.title) { taskLinks?.open(nil) }
        .buttonStyle(.plain)
        .help("Show the tasks")
        .accessibilityIdentifier("task-marker-open-\(row.id)")
    } else if let task = TranscriptMarker.task(activity), listed.isShown {
      HStack(spacing: Theme.Spacing.tiny) {
        label
        if listed.contains(task) {
          Button(activity.summary) { taskLinks?.open(task) }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("Show \(activity.summary) in Tasks")
            .accessibilityIdentifier("task-marker-open-\(row.id)")
        } else {
          // Its plan dropped it: the marker stays where it happened but links nowhere.
          Text(activity.summary)
            .foregroundStyle(.primary)
            .help(TranscriptMarker.droppedNote(activity))
        }
      }
    } else if activity.summary.isEmpty {
      label
    } else if let session = TranscriptMarker.childSession(activity),
      let open = actions.openChild ?? actions.openSession
    {
      HStack(spacing: Theme.Spacing.tiny) {
        label
        Button(activity.summary) { open(session) }
          .buttonStyle(.plain)
          .foregroundStyle(.primary)
          .help("Open \(activity.summary)")
          .accessibilityIdentifier("subagent-marker-open-\(row.id)")
      }
    } else {
      Text("\(label) \(Text(activity.summary).foregroundStyle(.primary))")
    }
  }
}

/// A dashed hairline that fills the width it is offered.
private struct DashedRule: View {
  var body: some View {
    DashedLine()
      .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
      .foregroundStyle(.separator)
      .frame(height: 1)
      .frame(minWidth: 0, maxWidth: .infinity)
      .accessibilityHidden(true)
  }
}

nonisolated private struct DashedLine: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    return path
  }
}
