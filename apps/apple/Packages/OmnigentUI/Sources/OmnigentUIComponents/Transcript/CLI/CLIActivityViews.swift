import OmnigentPlatform
import SwiftUI

/// A non-tool activity row as a terminal line. Side questions and unsupported items keep their
/// native rows: they carry controls or a visible placeholder.
struct CLIActivityLine: View, Equatable {
  let row: Row
  @RowDisclosure private var disclosure
  private var disclosureKey: String { "cli-activity-\(row.id)" }
  private var isExpanded: Bool {
    get { disclosure.choice(disclosureKey) ?? false }
    nonmutating set { disclosure.choose(newValue, for: disclosureKey) }
  }
  @Environment(\.cliPalette) private var palette
  @Environment(\.transcriptAppearance) private var appearance
  @Environment(\.conversationActions) private var conversationActions
  @Environment(\.taskMarkerLinks) private var taskLinks
  private(set) var size = CLIFontSize()

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row }

  /// Retry or Resume for a failed turn, as the chat's error row offers it.
  private func recovery(_ activity: Activity) -> CLIAction? {
    guard let recovery = activity.recovery, let retry = conversationActions.retryFailedTurn else {
      return nil
    }
    let row = row
    return CLIAction(
      title: recovery.title, systemImage: "arrow.clockwise",
      identifier: "error-retry-\(row.id)", perform: { retry(row) })
  }

  var body: some View {
    if let activity = row.activity, activity.kind != .sidechat, activity.kind != .unknown {
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        // A shell command's output row has no line of its own: it continues the command's.
        if activity.kind != .terminal || !isOutputOnly(activity) {
          CLIBulletLine(
            line: line(activity), marker: activity.isFailure ? palette.failure : nil,
            isLive: row.isStreaming,
            glyph: activity.kind == .error ? CLIBullet.error : CLIBullet.glyph,
            spokenPrefix: activity.kind == .error ? "Error: " : "")
        }
        if activity.kind == .terminal { terminalOutput(activity) }
        if let recovery = recovery(activity) { recoveryButton(recovery, help: activity) }
        if activity.kind == .error {
          ErrorRecoveryLinks(row: row, activity: activity).padding(.leading, size.character * 2)
        }
        if isExpanded { details(activity) }
      }
      .transcriptColumn()
      .cliActions(actions(activity))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(identifier(activity))
    } else {
      ActivityRowView(row: row).transcriptColumn()
    }
  }

  /// The line a thought, a notice or a marker shows, which CLI text cells draw too; `nil` for
  /// any other activity. A settled thought previews its first line, as in chat.
  nonisolated static func markerLine(
    _ activity: Activity, isStreaming: Bool, palette: CLIPalette
  ) -> CLILineText? {
    var line = CLILineText()
    switch activity.kind {
    case .reasoning:
      if let preview = ReasoningText.preview(activity, isStreaming: isStreaming) {
        line.append("Thinking:", palette.dim, bold: true)
        line.append(" \(preview)", palette.dim)
      } else {
        line.append(isStreaming ? "Thinking\u{2026}" : "Thought", palette.dim)
      }
    case .systemNotice:
      line.append("System:", palette.dim, bold: true)
      line.append(" \(activity.title)", palette.dim)
    case .subagentMarker, .taskMarker:
      let waits = TranscriptMarker.waitsForReader(activity)
      line.append(activity.title, waits ? palette.needsYou : palette.dim)
      if !activity.summary.isEmpty {
        line.append(" ")
        line.append(activity.summary, palette.strong)
      }
    default:
      return nil
    }
    return line
  }

  private func line(_ activity: Activity) -> CLILineText {
    if let line = Self.markerLine(activity, isStreaming: row.isStreaming, palette: palette) {
      return line
    }
    var line = CLILineText()
    switch activity.kind {
    case .terminal:
      line.append("You ran", bold: true)
      line.append(" ")
      line.append(shell: activity.detail("input") ?? activity.summary, palette)
    case .error:
      line.append(activity.summary.isEmpty ? activity.title : activity.summary, palette.failure)
    default:
      line.append(activity.displayTitle, activity.isFailure ? palette.failure : nil, bold: true)
      if !activity.summary.isEmpty {
        line.append(" ")
        line.append(activity.summary, activity.kind == .command ? palette.path : palette.dim)
      }
      if let status = activity.status, !status.isEmpty, !activity.isFailure,
        activity.kind != .reasoning
      {
        line.append(" \u{00B7} \(status.replacingOccurrences(of: "_", with: " "))", palette.dim)
      }
    }
    return line
  }

  /// Always visible, as in chat: it may be the turn's only way to recover.
  private func recoveryButton(_ action: CLIAction, help activity: Activity) -> some View {
    Button(action: action.perform) {
      Text(verbatim: action.title).cliFont().foregroundStyle(palette.strong.color)
    }
    .buttonStyle(.bordered)
    .help(activity.recovery?.help ?? action.title)
    .padding(.leading, size.character * 2)
    .accessibilityIdentifier(action.identifier)
  }

  /// Whether a shell-mode row carries only what the command printed, not the command.
  private func isOutputOnly(_ activity: Activity) -> Bool {
    let printed = ["stdout", "stderr"].contains { activity.detail($0)?.isEmpty == false }
    return printed && activity.detail("input")?.isEmpty != false
  }

  /// What a shell-mode command printed, on the branch under it; its errors in the failure color.
  @ViewBuilder private func terminalOutput(_ activity: Activity) -> some View {
    if let stdout = activity.detail("stdout"), !stdout.isEmpty {
      CLIDetailText(text: stdout)
    }
    if let stderr = activity.detail("stderr"), !stderr.isEmpty {
      CLIDetailText(text: stderr, color: \.failure)
    }
  }

  @ViewBuilder private func details(_ activity: Activity) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      switch activity.kind {
      case .reasoning, .systemNotice:
        CLIDetailText(text: CLIWork.detailText(of: activity) ?? "")
      default:
        if appearance.outputRendering == .rich {
          DetailSectionsView(sections: activity.details, rowID: row.id)
        } else {
          ForEach(activity.details) { section in
            CLIDetailText(text: "\(section.title)\n\(section.text)")
          }
        }
      }
    }
    .padding(.leading, appearance.outputRendering == .rich ? 0 : size.character * 2)
  }

  private var hasDetails: Bool {
    guard let activity = row.activity else { return false }
    switch activity.kind {
    case .reasoning, .systemNotice: return CLIWork.detailText(of: activity) != nil
    // A shell command's output always shows under it; a marker has nothing to open.
    case .terminal, .subagentMarker, .taskMarker: return false
    default: return !activity.details.isEmpty
    }
  }

  private func identifier(_ activity: Activity) -> String {
    switch activity.kind {
    case .reasoning: "reasoning-\(row.id)"
    case .terminal: "terminal-\(row.id)"
    case .error: "error-\(row.id)"
    case .retry: "retry-\(row.id)"
    case .compaction: "compaction-\(row.id)"
    case .systemNotice: "system-notice-\(row.id)"
    case .subagentMarker: "subagent-marker-\(row.id)"
    case .taskMarker: "task-marker-\(row.id)"
    default: "activity-\(row.id)"
    }
  }

  private func toggleIdentifier(_ activity: Activity) -> String {
    switch activity.kind {
    case .reasoning: "reasoning-toggle-\(row.id)"
    case .compaction: "compaction-toggle-\(row.id)"
    case .systemNotice: "system-notice-toggle-\(row.id)"
    default: "activity-toggle-\(row.id)"
    }
  }

  private func actions(_ activity: Activity) -> [CLIAction] {
    var actions: [CLIAction] = []

    if hasDetails {
      actions.append(
        CLIAction(
          title: isExpanded ? "Hide details" : "Show details",
          systemImage: isExpanded ? "chevron.up" : "chevron.down",
          identifier: toggleIdentifier(activity), perform: { isExpanded.toggle() }))
    }
    let routes = conversationActions
    if let session = TranscriptMarker.childSession(activity),
      let open = routes.openChild ?? routes.openSession
    {
      actions.append(
        CLIAction(
          title: "Open \(activity.summary)", systemImage: "arrow.up.forward.square",
          identifier: "subagent-marker-open-\(row.id)", perform: { open(session) }))
    }
    if let tasks = TranscriptMarker.tasksAction(activity, rowID: row.id, links: taskLinks) {
      actions.append(tasks)
    }
    let copyText =
      activity.kind == .terminal
      ? activity.detail("input") ?? activity.summary
      : (row.text.isEmpty ? activity.summary : row.text)
    if !copyText.isEmpty {
      actions.append(
        CLIAction(
          title: activity.kind == .error ? "Copy error" : "Copy", systemImage: "doc.on.doc",
          identifier: "activity-copy-\(row.id)", perform: { Pasteboard.copy(copyText) }))
    }
    return actions
  }
}

/// A settled turn's tool work. Its lines show, as a terminal shows them; the hover actions
/// collapse them into one summary line ("Ran 3 shell commands, read 2 files").
struct CLIWorkGroup: View, Equatable {
  let id: String
  let items: [TranscriptItem]
  let isLive: Bool
  let decorations: [String: MessageDecoration]
  @RowDisclosure private var disclosure
  private var isCollapsed: Bool {
    get { disclosure.choice("cli-work-\(id)") ?? false }
    nonmutating set { disclosure.choose(newValue, for: "cli-work-\(id)") }
  }
  /// A tool line's cluster at its widest: its first line shares this group's top edge, and the
  /// fold button on top of Copy output would fold the group instead of copying.
  private static let lineClusterWidth =
    3 * Theme.Control.target + 3 * Theme.Spacing.tiny + 2 * Theme.Spacing.extraSmall

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.items == rhs.items && lhs.isLive == rhs.isLive
      && lhs.decorations == rhs.decorations
  }

  var body: some View {
    Group {
      if isCollapsed, !isLive {
        CLIBulletLine(line: summary).transcriptColumn()
      } else {
        VStack(alignment: .leading, spacing: CLIMetrics.blockGap) {
          ForEach(items) { CLIItemView(item: $0, decorations: decorations) }
        }
      }
    }
    .cliActions(isLive ? [] : [toggle], trailingClearance: Self.lineClusterWidth)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("worked-\(items.first?.id ?? "empty")")
  }

  private var summary: CLILineText { Self.summary(of: items) }

  /// "Ran 3 shell commands, read 2 files …": a collapsed group's one line.
  nonisolated static func summary(of items: [TranscriptItem]) -> CLILineText {
    var line = CLILineText()
    let titles = items.flatMap { item -> [String] in
      if case .tools(_, let entries) = item {
        return entries.map { $0.primary?.activity?.title ?? "" }
      }
      return []
    }
    line.append(titles.isEmpty ? "Worked" : ToolRunSummary.text(for: titles))
    line.append(" \u{2026}")
    return line
  }

  private var toggle: CLIAction {
    CLIAction(
      title: isCollapsed ? "Expand work" : "Collapse work",
      systemImage: isCollapsed ? "chevron.down" : "chevron.up",
      identifier: "worked-fold-\(items.first?.id ?? "empty")",
      perform: { isCollapsed.toggle() })
  }
}

/// One transcript item inside a CLI turn.
struct CLIItemView: View {
  let item: TranscriptItem
  let decorations: [String: MessageDecoration]

  var body: some View {
    switch item {
    case .message(let row):
      if row.role == .user {
        CLIUserBand(row: row, decoration: decorations[row.id] ?? MessageDecoration())
      } else {
        CLIAssistantBlock(row: row, decoration: decorations[row.id] ?? MessageDecoration())
      }
    case .tools(_, let entries): CLIToolLines(entries: entries)
    case .activity(let row): CLIActivityLine(row: row)
    }
  }
}

/// "Worked for 12s • 21:47", dim, under a settled turn.
struct CLIFooterLine: View {
  let text: String
  @Environment(\.cliPalette) private var palette

  var body: some View {
    Text(verbatim: text)
      .foregroundStyle(palette.dim.color)
      .cliFont()
      .frame(maxWidth: .infinity, alignment: .leading)
      .transcriptColumn()
  }
}

/// The live turn's working line, or the blocked state, as the Codex CLI shows it:
/// "• Working (12s • esc to interrupt)".
struct CLIWorkingLine: View {
  let isBlocked: Bool
  /// When the turn started; `nil` leaves the time out.
  var startedAt: Date?
  @Environment(\.cliPalette) private var palette
  @Environment(\.composerLayoutStyle) private var layout

  var body: some View {
    ElapsedTimeline(start: isBlocked ? nil : startedAt) { now in
      CLIBulletLine(
        line: line(now: now), marker: isBlocked ? palette.needsYou : palette.marker,
        isLive: !isBlocked)
    }
    .transcriptColumn()
    .accessibilityIdentifier("transcript-working")
  }

  private func line(now: Date) -> CLILineText {
    var line = CLILineText()
    if isBlocked {
      line.append("Waiting for your response to the request below.", palette.needsYou)
      return line
    }
    line.append("Working", bold: true)
    // Touch has no Esc; Stop sits in the composer.
    let hint = layout == .card ? "esc to interrupt" : nil
    let detail = [startedAt.map { TurnElapsed.elapsed(since: $0, now: now) }, hint]
      .compactMap(\.self)
    if !detail.isEmpty {
      line.append(" (\(detail.joined(separator: " \u{2022} ")))", palette.dim)
    }
    return line
  }
}
