import OmnigentPlatform
import SwiftUI

/// A run of tool calls as the cells the Codex CLI draws: "Ran git status" with its output on
/// the `└` branch, "Explored" over the files read and searched, "Edited App.swift (+3 -1)" over
/// its changed lines. A cell's actions are in its context menu.
struct CLIToolLines: View, Equatable {
  let entries: [ToolEntry]

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.entries == rhs.entries }

  var body: some View {
    let agents = entries.filter(CLIAgentTool.isAgent)
    VStack(alignment: .leading, spacing: CLIMetrics.blockGap) {
      ForEach(CLIToolCell.cells(for: entries.filter { !CLIAgentTool.isAgent($0) })) { cell in
        switch cell {
        case .explored(let steps): CLIExploredCell(steps: steps)
        case .call(let step): CLIToolLine(step: step)
        }
      }
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

extension CLIToolStep {
  /// Show output, Copy input and Copy output for the steps a cell or one of its lines holds.
  @MainActor
  static func actions(
    for steps: [Self], isExpanded: Bool, toggle: @escaping @MainActor () -> Void
  ) -> [CLIAction] {
    let id = steps.first?.id ?? ""
    var actions = [
      CLIAction(
        title: isExpanded ? "Hide output" : "Show output",
        systemImage: isExpanded ? "chevron.up" : "chevron.down",
        identifier: "tool-toggle-\(id)", perform: toggle)
    ]
    let input = steps.map(\.input).filter { !$0.isEmpty }.joined(separator: "\n")
    if !input.isEmpty {
      actions.append(
        CLIAction(
          title: "Copy input", systemImage: "doc.on.doc", identifier: "tool-copy-input-\(id)",
          perform: { Pasteboard.copy(input) }))
    }
    let output = steps.compactMap(\.output).joined(separator: "\n")
    if !output.isEmpty {
      actions.append(
        CLIAction(
          title: "Copy output", systemImage: "doc.on.clipboard",
          identifier: "tool-copy-output-\(id)", perform: { Pasteboard.copy(output) }))
    }
    return actions
  }
}

extension CLIToolStep {
  /// An edit, by its call or the diff it made.
  nonisolated var isEdit: Bool {
    if case .edit = call { return true }
    return diff != nil
  }

  /// The files its diff changes.
  nonisolated var files: [CLIDiffFile] { diff.map(CLIDiffFile.files(in:)) ?? [] }

  /// The line's marker: a failed edit's cross, else the bullet.
  nonisolated var glyph: String { isEdit && entry.isFailure ? CLIBullet.failed : CLIBullet.glyph }

  /// Red for a failure, pulsing while it runs, green for a command or call that worked.
  nonisolated func marker(_ palette: CLIPalette) -> SRGB? {
    if entry.isFailure { return palette.failure }
    if entry.isRunning { return palette.marker }
    if case .plan = call { return nil }
    return isEdit ? nil : palette.added
  }

  /// "Ran git status", "Called server.tool(arguments)", "Updated Plan" or an edit's line.
  func line(_ files: [CLIDiffFile], palette: CLIPalette) -> CLILineText {
    var line = CLILineText()
    if isEdit {
      editLine(&line, files, palette: palette)
    } else if case .command(let script) = call {
      line.append(entry.isRunning ? "Running" : "Ran", bold: true)
      line.append(" ")
      line.append(shell: CLIShell.lines(script).first ?? "", palette)
    } else if case .other(let name, let arguments) = call {
      // A result whose call is not on screen has only its own title to show.
      let verb = entry.isRunning ? "Calling " : "Called "
      line.append(entry.call == nil ? "" : verb, bold: true)
      line.append(name, entry.call == nil ? nil : palette.marker)
      line.append(arguments.isEmpty ? "" : "(")
      line.append(arguments, palette.dim)
      line.append(arguments.isEmpty ? "" : ")")
    } else {
      line.append("Updated Plan", bold: true)
    }
    return line
  }

  /// "Edited App.swift (+3 -1)", "Added notes.md (+2 -0)" or "Edited 2 files (+6 -1)".
  private nonisolated func editLine(
    _ line: inout CLILineText, _ files: [CLIDiffFile], palette: CLIPalette
  ) {
    var subject = files.count > 1 ? "\(files.count) files" : files.first?.path ?? ""
    if case .edit(let path) = call, subject.isEmpty { subject = path ?? "files" }
    if entry.isFailure {
      line.append("Failed to edit \(subject)", palette.failure, bold: true)
      return
    }
    let verb = files.count == 1 ? files[0].verb : "Edited"
    line.append(entry.isRunning ? "Editing" : verb, bold: true)
    line.append(" \(subject)")
    if let diff, diff.added + diff.removed > 0 {
      CLIDiffCounts.append(to: &line, added: diff.added, removed: diff.removed, palette)
    }
  }
}

/// One tool call's cell: its header line, then what it left on the `└` branch: a command's
/// first lines of output, an edit's changed lines, a plan's steps.
struct CLIToolLine: View {
  /// The output lines a cell shows before "… +N lines".
  static let previewLines = 3
  /// The lines of a command after its first that a cell shows.
  static let commandLines = 2

  let step: CLIToolStep
  @State private var isExpanded = false
  @Environment(\.cliPalette) private var palette
  @Environment(\.transcriptAppearance) private var appearance
  private(set) var size = CLIFontSize()

  private var entry: ToolEntry { step.entry }

  var body: some View {
    let files = step.files
    VStack(alignment: .leading, spacing: size.lineSpacing) {
      CLIBulletLine(
        line: step.line(files, palette: palette), marker: step.marker(palette),
        isLive: entry.isRunning, glyph: step.glyph,
        spokenPrefix: entry.isFailure && !step.isEdit ? "Failed: " : "")
      if isExpanded, appearance.outputRendering == .rich {
        rich
      } else {
        detail(files)
      }
      if isExpanded {
        AttachmentStrip(
          attachments: (entry.call?.attachments ?? []) + (entry.result?.attachments ?? []))
      }
    }
    .transcriptColumn()
    .cliActions(
      CLIToolStep.actions(for: [step], isExpanded: isExpanded) { isExpanded.toggle() }
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("tool-\(entry.id)")
  }

  @ViewBuilder
  private func detail(_ files: [CLIDiffFile]) -> some View {
    if case .command(let script) = step.call, !step.isEdit {
      CLICommandLines(lines: Array(CLIShell.lines(script).dropFirst()), showsAll: $isExpanded)
    }
    if case .plan(let note, let steps) = step.call {
      CLIPlanSteps(note: note, steps: steps)
    } else if !files.isEmpty, !entry.isFailure {
      CLIDiffFiles(files: files, showsAll: $isExpanded)
    } else if let output = step.output {
      CLIOutputTree(text: output, limit: Self.previewLines, showsAll: $isExpanded)
    } else if !entry.isRunning {
      CLIOutputTree(text: "(no output)", limit: 1, showsAll: .constant(true))
    }
  }

  /// Rich rendering opens the chat's cards: the diff, then the call's and the result's sections.
  @ViewBuilder private var rich: some View {
    if let diff = step.diff { DiffView(diff: diff) }
    if let call = entry.call?.activity, !call.details.isEmpty {
      DetailSectionsView(sections: call.details, rowID: entry.call?.id ?? entry.id)
    }
    if let result = entry.result?.activity {
      DetailSectionsView(sections: result.details, rowID: entry.result?.id ?? entry.id)
    }
  }
}
