import OmnigentPlatform
import SwiftUI

/// A run of tool calls as terminal lines: "Ran `git status`", "Edited `Sources/App.swift`
/// (+3 −1)", "Failed `npm test`". Output folds under each line, opened from the hover actions.
struct CLIToolLines: View, Equatable {
  let entries: [ToolEntry]

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.entries == rhs.entries }

  var body: some View {
    let agents = entries.filter(CLIAgentTool.isAgent)
    VStack(alignment: .leading, spacing: CLIMetrics.blockGap) {
      ForEach(entries.filter { !CLIAgentTool.isAgent($0) }) { CLIToolLine(entry: $0) }
      // Agents run side by side: every start, then each finish, as the CLI logs them.
      ForEach(agents) { CLIAgentLine(entry: $0, phase: .started) }
      ForEach(agents.filter { !$0.isRunning }) { CLIAgentLine(entry: $0, phase: .finished) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(entries.first.map { "tool-group-\($0.id)" } ?? "tool-group")
  }
}

/// Tools that start a sub-agent.
nonisolated enum CLIAgentTool {
  static let names: Set<String> = [
    "spawn_agent", "agent", "task", "subagent", "sub_agent", "delegate", "start_agent",
  ]

  static func isAgent(_ entry: ToolEntry) -> Bool {
    names.contains((entry.primary?.activity?.title ?? "").lowercased())
  }

  static func isAgent(_ row: Row) -> Bool {
    row.activity?.kind == .toolCall && names.contains((row.activity?.title ?? "").lowercased())
  }
}

/// "Started `/root/sample_list`" or "Completed `/root/sample_list`" for a sub-agent tool.
struct CLIAgentLine: View {
  enum Phase {
    case started
    case finished
  }

  let entry: ToolEntry
  let phase: Phase
  @Environment(\.cliPalette) private var palette

  private var subject: String {
    let summary = entry.call?.activity?.summary ?? entry.primary?.activity?.summary ?? ""
    let first = summary.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    return first.isEmpty ? (entry.primary?.activity?.title ?? "agent") : first
  }

  var body: some View {
    var line = CLILineText()
    switch phase {
    case .started: line.append("Started", bold: true)
    case .finished where entry.isFailure: line.append("Failed", palette.failure, bold: true)
    case .finished: line.append("Completed", bold: true)
    }
    line.append(" ")
    line.append("`\(subject)`", palette.path)
    let output = entry.result?.activity?.detail("output") ?? ""
    // Still while running: the turn's working line is its one live marker.
    return CLIBulletLine(
      line: line, marker: entry.isFailure && phase == .finished ? palette.failure : nil
    )
    .transcriptColumn()
    .cliActions(
      output.isEmpty || phase == .started
        ? []
        : [
          CLIAction(
            title: "Copy result", systemImage: "doc.on.clipboard",
            identifier: "tool-copy-output-\(entry.id)", perform: { Pasteboard.copy(output) })
        ]
    )
    .accessibilityIdentifier("tool-\(entry.id)-\(phase == .started ? "started" : "finished")")
  }
}

struct CLIToolLine: View {
  let entry: ToolEntry
  @State private var isExpanded = false
  @Environment(\.cliPalette) private var palette
  @Environment(\.transcriptAppearance) private var appearance
  private let size = CLIFontSize()

  private var activity: Activity? { entry.primary?.activity }

  private var diff: DiffSummary? {
    let texts = [
      entry.call?.activity?.detail("arguments"), entry.result?.activity?.detail("output"),
    ]
    return texts.lazy.compactMap { $0 }.compactMap(DiffSummary.find(in:)).first
  }

  private var subject: String {
    let summary = entry.call?.activity?.summary ?? activity?.summary ?? ""
    let first = summary.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    if let diff, !diff.files.isEmpty { return diff.files.joined(separator: ", ") }
    return first.isEmpty ? (activity?.title ?? "tool") : first
  }

  private var verb: String {
    if entry.isRunning { return "Running" }
    if entry.isFailure { return "Failed" }
    switch ToolRunSummary.category(of: activity?.title ?? "") {
    case .shell: return "Ran"
    case .list: return "Listed"
    case .read: return "Read"
    case .edit: return "Edited"
    case .search: return "Searched"
    case nil: return "Called \(activity?.title ?? "tool")"
    }
  }

  private var output: String? {
    entry.result?.activity?.detail("output") ?? entry.result?.text.nilIfEmpty
  }

  var body: some View {
    let diff = diff
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      CLIBulletLine(line: line(diff), marker: marker)
      if isExpanded { expanded(diff) }
    }
    .transcriptColumn()
    .cliActions(actions)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("tool-\(entry.id)")
  }

  private var marker: SRGB? {
    if entry.isFailure { return palette.failure }
    return entry.isRunning ? palette.marker : nil
  }

  private func line(_ diff: DiffSummary?) -> CLILineText {
    var line = CLILineText()
    line.append(verb, entry.isFailure ? palette.failure : nil, bold: true)
    line.append(" ")
    line.append("`\(subject)`", palette.path)
    if let diff {
      line.append(" (")
      line.append("+\(diff.added)", palette.added)
      line.append(" ")
      line.append("\u{2212}\(diff.removed)", palette.failure)
      line.append(")")
    }
    return line
  }

  @ViewBuilder private func expanded(_ diff: DiffSummary?) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      if appearance.outputRendering == .rich {
        if let diff { DiffView(diff: diff) }
        if let call = entry.call?.activity, !call.details.isEmpty {
          DetailSectionsView(sections: call.details, rowID: entry.call?.id ?? entry.id)
        }
        if let result = entry.result?.activity {
          DetailSectionsView(sections: result.details, rowID: entry.result?.id ?? entry.id)
        }
      } else {
        if let input = entry.call?.activity?.summary, input.contains("\n") {
          CLIDetailText(text: input, color: \.body)
        }
        if let output {
          CLIDetailText(text: output, color: entry.isFailure ? \.failure : \.dim)
        } else if !entry.isRunning {
          CLIDetailText(text: "(no output)")
        }
      }
      AttachmentStrip(
        attachments: (entry.call?.attachments ?? []) + (entry.result?.attachments ?? []))
    }
    .padding(.leading, appearance.outputRendering == .rich ? 0 : size.character * 2)
  }

  private var actions: [CLIAction] {
    var actions = [
      CLIAction(
        title: isExpanded ? "Hide output" : "Show output",
        systemImage: isExpanded ? "chevron.up" : "chevron.down",
        identifier: "tool-toggle-\(entry.id)", perform: { isExpanded.toggle() })
    ]
    if let input = entry.call?.activity?.summary, !input.isEmpty {
      actions.append(
        CLIAction(
          title: "Copy input", systemImage: "doc.on.doc", identifier: "tool-copy-input-\(entry.id)",
          perform: { Pasteboard.copy(input) }))
    }
    if let output {
      actions.append(
        CLIAction(
          title: "Copy output", systemImage: "doc.on.clipboard",
          identifier: "tool-copy-output-\(entry.id)", perform: { Pasteboard.copy(output) }))
    }
    return actions
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
