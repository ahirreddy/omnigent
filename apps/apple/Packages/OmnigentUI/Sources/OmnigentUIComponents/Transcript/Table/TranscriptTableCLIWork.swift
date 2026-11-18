import Foundation

/// What the reader acts on in a turn's tool work: a tool call's or an explored line's steps, an
/// activity, by the id of its region in the text.
nonisolated enum CLIWorkTarget: Sendable {
  case steps([CLIToolStep])
  case activity(Row)
}

/// A turn's tool work as a CLI text cell draws it: what it draws, and what each of its regions
/// acts on.
nonisolated struct CLIWork: Sendable {
  var spec: CLIWorkSpec
  var targets: [String: CLIWorkTarget]

  /// The work `items` show, as ``CLIWorkGroup`` draws it, when a CLI text cell can draw all of
  /// it: settled tool calls (not a sub-agent's) without attachments, and reasoning. `group` is
  /// the Worked group the reader may collapse.
  @MainActor
  static func make(
    _ items: [TranscriptItem], group: String?, palette: CLIPalette,
    expansions: CLIWorkExpansions
  ) -> Self? {
    if let group, expansions.isCollapsed(group) {
      let summary = CLIWorkCell(id: group, line: CLIWorkGroup.summary(of: items), marker: nil)
      return Self(spec: CLIWorkSpec(cells: [summary]), targets: [:])
    }
    var work = Self(spec: CLIWorkSpec(cells: []), targets: [:])
    for item in items {
      switch item {
      case .message:
        return nil
      case .activity(let row):
        guard work.addActivity(row, palette: palette, expansions: expansions) else { return nil }
      case .tools(_, let entries):
        guard work.addTools(entries, palette: palette, expansions: expansions) else {
          return nil
        }
      }
    }
    return work.spec.cells.isEmpty ? nil : work
  }

  /// A reasoning line, a notice or a marker, as ``CLIActivityLine`` draws it; what opens under
  /// it (a thought's text, a notice's body) once opened.
  @MainActor private mutating func addActivity(
    _ row: Row, palette: CLIPalette, expansions: CLIWorkExpansions
  ) -> Bool {
    guard let activity = row.activity, !row.isStreaming, row.attachments.isEmpty,
      let line = CLIActivityLine.markerLine(activity, isStreaming: false, palette: palette)
    else { return false }
    var cell = CLIWorkCell(
      id: row.id, line: line, marker: activity.isFailure ? palette.failure : nil, gap: .small)
    if expansions.isOpen(row.id), let text = Self.detailText(of: activity) {
      let action = row.id + "/details"
      cell.details.append(
        .tree(
          CLIWorkTree(
            text: text, color: palette.dim, limit: 40, showsAll: expansions.isOpen(action),
            action: action, indent: 2)))
    }
    spec.cells.append(cell)
    targets[row.id] = .activity(row)
    return true
  }

  /// What an activity line opens to: a thought's text or a notice's body; `nil` when it has
  /// nothing to open.
  static func detailText(of activity: Activity) -> String? {
    switch activity.kind {
    case .reasoning: ReasoningText.text(activity)
    case .systemNotice: TranscriptMarker.noticeBody(activity)
    default: nil
    }
  }

  /// A run of tool calls' cells, as ``CLIToolLines`` draws them.
  @MainActor private mutating func addTools(
    _ entries: [ToolEntry], palette: CLIPalette, expansions: CLIWorkExpansions
  ) -> Bool {
    let hasAttachments = entries.contains {
      !($0.call?.attachments.isEmpty ?? true) || !($0.result?.attachments.isEmpty ?? true)
    }
    guard !entries.contains(where: \.isRunning), !entries.contains(where: CLIAgentTool.isAgent),
      !hasAttachments
    else { return false }
    for cell in CLIToolCell.cells(for: entries) {
      switch cell {
      case .explored(let steps): addExplored(steps, palette: palette, expansions: expansions)
      case .call(let step): addCall(step, palette: palette, expansions: expansions)
      }
    }
    return true
  }

  /// "Explored", then a line for each search, listing and run of reads, each opening its
  /// calls' output.
  @MainActor private mutating func addExplored(
    _ steps: [CLIToolStep], palette: CLIPalette, expansions: CLIWorkExpansions
  ) {
    var header = CLILineText()
    header.append("Explored", bold: true)
    var cell = CLIWorkCell(id: "explored:\(steps.first?.id ?? "")", line: header, marker: nil)
    for (index, line) in CLIExploredLine.lines(for: steps).enumerated() {
      let trees: [CLIWorkTree] =
        expansions.isOpen(line.id)
        ? line.steps.map { step in
          let action = "\(line.id)/\(step.id)"
          return CLIWorkTree(
            text: step.output ?? "(no output)", color: palette.dim, limit: 40,
            showsAll: expansions.isOpen(action), action: action, indent: 2)
        } : []
      cell.details.append(
        .branch(line.text(palette), isFirst: index == 0, id: line.id, trees: trees))
      targets[line.id] = .steps(line.steps)
    }
    spec.cells.append(cell)
  }

  /// A tool call's cell, as ``CLIToolLine`` draws it: its line, then a command's lines and what
  /// it left on the branch.
  @MainActor private mutating func addCall(
    _ step: CLIToolStep, palette: CLIPalette, expansions: CLIWorkExpansions
  ) {
    let files = step.files
    let isOpen = expansions.isOpen(step.id)
    var cell = CLIWorkCell(
      id: step.id, line: step.line(files, palette: palette), marker: step.marker(palette),
      glyph: step.glyph)
    if case .command(let script) = step.call, !step.isEdit {
      let lines = Array(CLIShell.lines(script).dropFirst())
      if !lines.isEmpty {
        cell.details.append(
          .commandLines(
            lines, limit: CLIToolLine.commandLines, showsAll: isOpen, action: step.id))
      }
    }
    if case .plan(let note, let steps) = step.call {
      cell.details.append(.plan(note: note, steps: steps))
    } else if !files.isEmpty, !step.entry.isFailure {
      cell.details.append(
        .diff(
          files, limit: isOpen ? CLIDiffFiles.maxRows : CLIDiffFiles.previewRows,
          action: step.id))
    } else if let output = step.output {
      cell.details.append(
        .tree(
          CLIWorkTree(
            text: output, color: palette.dim, limit: CLIToolLine.previewLines, showsAll: isOpen,
            action: step.id)))
    } else {
      cell.details.append(
        .tree(
          CLIWorkTree(
            text: "(no output)", color: palette.dim, limit: 1, showsAll: true,
            action: step.id)))
    }
    spec.cells.append(cell)
    targets[step.id] = .steps([step])
  }
}
