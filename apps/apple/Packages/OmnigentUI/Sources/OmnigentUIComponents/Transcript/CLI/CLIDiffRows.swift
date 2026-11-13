import SwiftUI

/// One file's change as the Codex CLI lists it under an edit: its lines numbered, each added,
/// removed or unchanged, with a gap between two hunks.
nonisolated struct CLIDiffFile: Hashable, Sendable {
  enum Change: Hashable, Sendable {
    case added
    case deleted
    case edited
  }

  struct Row: Hashable, Sendable {
    /// `nil` for the gap between two hunks.
    var kind: DiffLineKind?
    var number: Int?
    var text: String
  }

  var path: String
  var change: Change
  var added = 0
  var removed = 0
  /// A hunk header placed the lines, so they are a change inside the file.
  var hasHunks = false
  var rows: [Row] = []

  /// "Added", "Deleted" or "Edited".
  var verb: String {
    switch change {
    case .added: "Added"
    case .deleted: "Deleted"
    case .edited: "Edited"
    }
  }

  /// The files of `diff`, in order. A change with no file header is one unnamed file.
  static func files(in diff: DiffSummary) -> [Self] {
    // A write's unchanged content is listed as it is, with no column before each line.
    var reader = Reader(hasGutter: diff.added + diff.removed > 0)
    for line in diff.lines { reader.read(line) }
    return reader.files.map(\.settled)
  }

  /// A file whose every line was added and has no hunk to place it is a new file.
  private var settled: Self {
    var file = self
    while file.rows.last?.kind == .context, file.rows.last?.text.isEmpty == true {
      file.rows.removeLast()
    }
    let isAllAdded = !file.rows.isEmpty && file.rows.allSatisfy { $0.kind == .added }
    guard isAllAdded, !file.hasHunks, file.change == .edited else { return file }
    file.change = .added
    for index in file.rows.indices { file.rows[index].number = index + 1 }
    return file
  }

  private struct Reader {
    let hasGutter: Bool
    var files: [CLIDiffFile] = []
    var old: Int?
    var new: Int?
    /// Past a patch's end: what follows is not part of any file.
    var isClosed = true

    mutating func read(_ line: DiffSummary.Line) {
      switch line.kind {
      case .header: header(line.text)
      case .added, .removed: row(line.kind, String(line.text.dropFirst()))
      case .context:
        guard !line.text.hasPrefix("\\") else { return }
        let hasColumn = hasGutter && line.text.hasPrefix(" ")
        row(.context, hasColumn ? String(line.text.dropFirst()) : line.text)
      }
    }

    private mutating func header(_ text: String) {
      if let path = DiffSummary.filePath(text) {
        let change: Change =
          text.hasPrefix("*** Add") ? .added : text.hasPrefix("*** Delete") ? .deleted : .edited
        files.append(CLIDiffFile(path: path, change: change))
        // A whole file's lines count from one; an edit's from its hunk headers.
        (old, new) = change == .edited ? (nil, nil) : (1, 1)
        isClosed = false
      } else if text.hasPrefix("@@") {
        if isClosed { files.append(CLIDiffFile(path: "", change: .edited)) }
        isClosed = false
        let last = files.count - 1
        if !files[last].rows.isEmpty {
          files[last].rows.append(Row(kind: nil, number: nil, text: "\u{22EE}"))
        }
        files[last].hasHunks = true
        let starts = text.firstMatch(of: /^@@ -(?<old>\d+)(?:,\d+)? \+(?<new>\d+)/)
        (old, new) = (starts.flatMap { Int($0.old) }, starts.flatMap { Int($0.new) })
      } else if text.hasPrefix("*** End Patch") {
        isClosed = true
      }
    }

    /// Adds a line to the open file and steps the counters it moves; lines outside any file
    /// are dropped.
    private mutating func row(_ kind: DiffLineKind, _ text: String) {
      guard !isClosed else { return }
      let last = files.count - 1
      files[last].rows.append(Row(kind: kind, number: kind == .removed ? old : new, text: text))
      if kind == .added { files[last].added += 1 }
      if kind == .removed { files[last].removed += 1 }
      if kind != .added { old = old.map { $0 + 1 } }
      if kind != .removed { new = new.map { $0 + 1 } }
    }
  }
}

/// A file's changed lines under an edit: numbers dim, added lines green and removed lines red
/// on a faint band, as the Codex CLI draws a patch.
struct CLIDiffRows: View {
  let rows: [CLIDiffFile.Row]
  @Environment(\.cliPalette) private var palette
  private(set) var size = CLIFontSize()

  var body: some View {
    let digits = rows.compactMap(\.number).max().map { "\($0)".count } ?? 0
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          if digits > 0 {
            Text(verbatim: row.number.map(String.init) ?? "")
              .foregroundStyle(palette.dim.color)
              .frame(width: size.character * CGFloat(digits), alignment: .trailing)
              .padding(.trailing, size.character)
          }
          Text(verbatim: Self.sign(row.kind)).frame(width: size.character, alignment: .leading)
          Text(verbatim: row.text.isEmpty ? " " : row.text)
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color(row.kind).color)
        .padding(.vertical, size.lineSpacing / 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(band(row.kind))
      }
    }
    .cliFont()
    .textSelection(.enabled)
  }

  static func sign(_ kind: DiffLineKind?) -> String {
    switch kind {
    case .added: "+"
    case .removed: "-"
    default: " "
    }
  }

  private func color(_ kind: DiffLineKind?) -> SRGB {
    switch kind {
    case .added: palette.added
    case .removed: palette.failure
    case .context: palette.body
    default: palette.dim
    }
  }

  private func band(_ kind: DiffLineKind?) -> Color {
    switch kind {
    case .added: palette.added.color.opacity(0.12)
    case .removed: palette.failure.color.opacity(0.12)
    default: .clear
    }
  }
}
