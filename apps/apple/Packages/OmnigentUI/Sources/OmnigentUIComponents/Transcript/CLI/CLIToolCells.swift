import SwiftUI

/// A command as the Codex CLI shows it: colored as shell, its first line beside "Ran".
enum CLIShell {
  nonisolated static func lines(_ script: String) -> [String] {
    script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  static func highlighted(_ text: String, _ palette: CLIPalette) -> AttributedString {
    CodeHighlighting.attributed(text, spans: CodeHighlighting.spans(text, language: "bash")) {
      CLICodeHighlightCache.color($0, palette).color
    }
  }
}

/// "(+3 -1)": added lines green, removed lines red.
nonisolated enum CLIDiffCounts {
  static func append(
    to line: inout CLILineText, added: Int, removed: Int, _ palette: CLIPalette
  ) {
    line.append(" (")
    line.append("+\(added)", palette.added)
    line.append(" ")
    line.append("-\(removed)", palette.failure)
    line.append(")")
  }
}

/// A command's lines after its first, each behind a `│`; past a couple, how many more.
struct CLICommandLines: View {
  let lines: [String]
  @Binding var showsAll: Bool
  @Environment(\.cliPalette) private var palette

  var body: some View {
    let isCut = !showsAll && lines.count > CLIToolLine.commandLines
    let shown = isCut ? Array(lines.prefix(CLIToolLine.commandLines)) : lines
    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
      row(Text(CLIShell.highlighted(line, palette)).foregroundStyle(palette.body.color))
    }
    if isCut {
      row(
        Button(CLIOutputTree.more(lines.count - shown.count)) { showsAll = true }
          .buttonStyle(.plain)
          .foregroundStyle(palette.dim.color))
    }
  }

  private func row(_ content: some View) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(verbatim: "\u{2502} ").foregroundStyle(palette.dim.color).accessibilityHidden(true)
      content.fixedSize(horizontal: false, vertical: true)
    }
    .cliFont()
    .textSelection(.enabled)
  }
}

/// A plan update's steps on the `└` branch: done ones struck through, the one in progress in
/// the accent color, the rest dim.
struct CLIPlanSteps: View {
  let note: String?
  let steps: [CLIPlanStep]
  @Environment(\.cliPalette) private var palette
  private(set) var size = CLIFontSize()

  var body: some View {
    let rows = [note.map(noteRow)].compactMap(\.self) + steps.map(row)
    VStack(alignment: .leading, spacing: size.lineSpacing) {
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          Text(verbatim: index == 0 ? "\u{2514} " : "  ").foregroundStyle(palette.dim.color)
            .accessibilityHidden(true)
          Text(row).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .cliFont()
    .textSelection(.enabled)
  }

  private func noteRow(_ text: String) -> AttributedString {
    var note = AttributedString(text)
    note.foregroundColor = palette.dim.color
    note.inlinePresentationIntent = .emphasized
    return note
  }

  private func row(_ step: CLIPlanStep) -> AttributedString {
    var row = AttributedString((step.status == .completed ? "\u{2714} " : "\u{25A1} ") + step.text)
    switch step.status {
    case .completed:
      row.foregroundColor = palette.dim.color
      row.strikethroughStyle = .single
    case .inProgress:
      row.foregroundColor = palette.marker.color
      row.inlinePresentationIntent = .stronglyEmphasized
    case .pending: row.foregroundColor = palette.dim.color
    }
    return row
  }
}

/// An edit's files: one file's lines straight under the header, several each under its own
/// `└ path (+1 -1)`. Long changes stop after a screenful until asked for the rest.
struct CLIDiffFiles: View {
  /// The changed lines a cell shows before "… +N lines".
  static let previewRows = 12
  /// The most lines an opened cell draws.
  static let maxRows = 400

  let files: [CLIDiffFile]
  @Binding var showsAll: Bool
  @Environment(\.cliPalette) private var palette
  private(set) var size = CLIFontSize()

  var body: some View {
    let shown = Self.rows(of: files, limit: showsAll ? Self.maxRows : Self.previewRows)
    let hidden = files.reduce(0) { $0 + $1.rows.count } - shown.reduce(0) { $0 + $1.count }
    VStack(alignment: .leading, spacing: size.lineSpacing) {
      ForEach(Array(zip(files, shown).enumerated()), id: \.offset) { index, pair in
        if files.count > 1 { fileLine(pair.0).padding(.top, index == 0 ? 0 : size.line) }
        CLIDiffRows(rows: pair.1).padding(.leading, size.character * 2)
      }
      if hidden > 0 {
        Button(CLIOutputTree.more(hidden)) { showsAll = true }
          .buttonStyle(.plain)
          .foregroundStyle(palette.dim.color)
          .cliFont()
          .padding(.leading, size.character * 2)
      }
    }
  }

  /// Each file's first lines, `limit` across them all.
  nonisolated static func rows(of files: [CLIDiffFile], limit: Int) -> [[CLIDiffFile.Row]] {
    var budget = limit
    return files.map { file in
      let rows = Array(file.rows.prefix(budget))
      budget -= rows.count
      return rows
    }
  }

  private func fileLine(_ file: CLIDiffFile) -> some View {
    var line = CLILineText()
    line.append("\u{2514} ", palette.dim)
    line.append(file.path)
    CLIDiffCounts.append(to: &line, added: file.added, removed: file.removed, palette)
    return Text(line.attributed).foregroundStyle(palette.body.color).cliFont()
      .textSelection(.enabled)
  }
}

/// Calls that only look around, gathered as the Codex CLI gathers them: "Explored", then a
/// line for each search, each listing and each run of files read.
struct CLIExploredCell: View {
  let steps: [CLIToolStep]
  @Environment(\.cliPalette) private var palette
  private(set) var size = CLIFontSize()

  var body: some View {
    let isRunning = steps.contains { $0.entry.isRunning }
    let lines = Array(CLIExploredLine.lines(for: steps).enumerated())
    var header = CLILineText()
    header.append(isRunning ? "Exploring" : "Explored", bold: true)
    return VStack(alignment: .leading, spacing: size.lineSpacing) {
      CLIBulletLine(line: header, marker: isRunning ? palette.marker : nil, isLive: isRunning)
      ForEach(lines, id: \.element.id) { index, line in
        CLIExploredRow(line: line, isFirst: index == 0)
      }
    }
    .transcriptColumn()
    .accessibilityElement(children: .contain)
  }
}

/// One line of an "Explored" cell; its calls' output opens under it from the context menu.
private struct CLIExploredRow: View {
  let line: CLIExploredLine
  let isFirst: Bool
  @RowDisclosure private var disclosure
  private var disclosureKey: String { "cli-explored-\(line.id)" }
  private var isExpanded: Bool {
    get { disclosure.choice(disclosureKey) ?? false }
    nonmutating set { disclosure.choose(newValue, for: disclosureKey) }
  }
  @Environment(\.cliPalette) private var palette
  private(set) var size = CLIFontSize()

  var body: some View {
    VStack(alignment: .leading, spacing: size.lineSpacing) {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text(verbatim: isFirst ? "\u{2514} " : "  ").foregroundStyle(palette.dim.color)
          .accessibilityHidden(true)
        Text(text.attributed).fixedSize(horizontal: false, vertical: true)
      }
      .foregroundStyle(palette.body.color)
      .cliFont()
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      if isExpanded {
        ForEach(line.steps) { step in
          CLIDetailText(text: step.output ?? "(no output)").padding(.leading, size.character * 2)
        }
      }
    }
    .cliActions(
      CLIToolStep.actions(for: line.steps, isExpanded: isExpanded) { isExpanded.toggle() }
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("tool-\(line.id)")
  }

  /// "Read a.swift, b.swift", "Search query in path" or "List path"; a failure says so.
  private var text: CLILineText {
    var text = CLILineText()
    text.append(line.title, palette.marker)
    for (index, target) in line.targets.enumerated() {
      text.append(index == 0 ? " " : ", ", palette.dim)
      text.append(target)
    }
    if let scope = line.scope {
      text.append(" in ", palette.dim)
      text.append(scope)
    }
    if line.steps.contains(where: \.entry.isFailure) { text.append(" (failed)", palette.failure) }
    return text
  }
}
