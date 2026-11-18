import SwiftUI

/// One row of a stacked diff. Every row has an id that stays put while the content around it
/// changes, so scrolling and recycling find it.
enum StackedDiffRow {
  case header(StackedDiffFile)
  case notice(path: String, text: String)
  case largeFile(path: String, lines: Int)
  case hunk(path: String, index: Int, header: String)
  case gap(path: String, gap: DiffGap, header: String?, hidden: Int?)
  /// A unified line; `hunk` is `nil` for unchanged lines shown by expanding context.
  case line(path: String, hunk: Int?, line: DiffLine, highlight: Range<Int>?)
  case split(
    path: String, hunk: Int?, left: SplitCell?, right: SplitCell?, highlight: SplitHighlight?)
  case annotation(AnyView)
}

/// The active find match in a side-by-side row.
struct SplitHighlight: Hashable {
  let side: DiffLineAnchor.Side
  let range: Range<Int>
}

/// A row and its id.
struct StackedDiffEntry: Identifiable {
  let id: String
  let row: StackedDiffRow
}

/// The rows of a stacked diff, with each row's id, the line rows' ids by anchor, and the file
/// each row belongs to.
struct StackedDiffLayout {
  var rows: [StackedDiffEntry] = []
  /// The row drawing each numbered line.
  var lineIDs: [DiffLineAnchor: String] = [:]
  /// The file of each row, by row id, in order.
  var paths: [String: (index: Int, path: String)] = [:]

  /// The layout of `content`; `split` draws side by side.
  init(_ content: StackedDiffContent, split: Bool, expands: Bool) {
    for file in content.files {
      var builder = FileRows(file: file, content: content, split: split, expands: expands)
      builder.build()
      for (id, row) in builder.rows {
        paths[id] = (rows.count, file.path)
        rows.append(StackedDiffEntry(id: id, row: row))
      }
      lineIDs.merge(builder.lineIDs) { first, _ in first }
    }
    if let footer = content.footer {
      rows.append(StackedDiffEntry(id: "footer", row: .annotation(footer)))
    }
  }

  /// The id of the row `target` names.
  func id(of target: StackedDiffScroll.Target) -> String? {
    switch target {
    case .file(let path): FileRows.headerID(path)
    case .line(let path, let side, let line):
      lineIDs[DiffLineAnchor(path: path, side: side, line: line)] ?? FileRows.headerID(path)
    }
  }
}

/// Builds one file's rows.
private struct FileRows {
  let file: StackedDiffFile
  let content: StackedDiffContent
  let split: Bool
  let expands: Bool
  var rows: [(String, StackedDiffRow)] = []
  var lineIDs: [DiffLineAnchor: String] = [:]
  private var placed: Set<DiffLineAnchor> = []
  private var sequence = 0

  init(file: StackedDiffFile, content: StackedDiffContent, split: Bool, expands: Bool) {
    self.file = file
    self.content = content
    self.split = split
    self.expands = expands
  }

  static func headerID(_ path: String) -> String { "h\u{1}\(path)" }

  private var path: String { file.path }

  private mutating func append(_ row: StackedDiffRow, kind: String) {
    sequence += 1
    rows.append(("\(kind)\u{1}\(path)\u{1}\(sequence)", row))
  }

  mutating func build() {
    rows.append((Self.headerID(path), .header(file)))
    guard !content.collapsed.contains(path) else { return }
    if let note = content.annotations.files[path] { append(.annotation(note), kind: "f") }
    guard let diff = file.diff else {
      append(.notice(path: path, text: "No text diff available for this file."), kind: "n")
      return
    }
    if diff.binary {
      append(.notice(path: path, text: "Binary file"), kind: "n")
    } else if diff.tooLarge {
      append(.notice(path: path, text: "This change is too large to show."), kind: "n")
    } else if diff.hunks.isEmpty, file.renamedFrom != nil {
      append(.notice(path: path, text: "File renamed without changes."), kind: "n")
    } else if file.unifiedLineCount > StackedDiffContent.largeDiffLines,
      !content.shownLargeFiles.contains(path)
    {
      append(.largeFile(path: path, lines: file.unifiedLineCount), kind: "g")
    } else {
      hunks(diff)
    }
  }

  private mutating func hunks(_ diff: FileDiff) {
    let context = content.context[path]
    let gaps = expands ? DiffContext.gaps(diff, lineCount: context?.text?.lines.count) : []
    let byIndex = Dictionary(gaps.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
    let splitRows = split ? Self.splitRows(diff) : [:]
    for (index, hunk) in diff.hunks.enumerated() {
      if let gap = byIndex[index] {
        self.gap(gap, header: hunk.header, context: context)
      } else {
        append(.hunk(path: path, index: index, header: hunk.header), kind: "k")
      }
      if split {
        for (left, right) in splitRows[index] ?? [] {
          lineRow(left: left, right: right, hunk: index)
        }
      } else {
        for line in hunk.lines { lineRow(line, hunk: index) }
      }
    }
    if let trailing = byIndex[diff.hunks.count] {
      gap(trailing, header: nil, context: context)
    }
  }

  /// A gap: the lines shown from its top, its control while lines stay hidden, then the lines
  /// shown from its bottom.
  private mutating func gap(_ gap: DiffGap, header: String?, context: DiffContextState?) {
    let reveal = context?.reveals[gap.index] ?? DiffGapReveal()
    let shown = context?.text.map { DiffContext.revealed(gap, reveal, lines: $0.lines) }
    for line in shown?.top ?? [] { contextRow(line) }
    let hidden = DiffContext.hidden(gap, reveal)
    if hidden != 0 || shown == nil {
      append(.gap(path: path, gap: gap, header: header, hidden: hidden), kind: "p")
    }
    for line in shown?.bottom ?? [] { contextRow(line) }
  }

  private mutating func contextRow(_ line: DiffLine) {
    if split {
      lineRow(
        left: line.oldNumber.map { SplitCell(kind: .context, number: $0, text: line.text) },
        right: line.newNumber.map { SplitCell(kind: .context, number: $0, text: line.text) },
        hunk: nil)
    } else {
      lineRow(line, hunk: nil)
    }
  }

  private mutating func lineRow(_ line: DiffLine, hunk: Int?) {
    let side: DiffLineAnchor.Side = line.kind == .removed ? .old : .new
    let number = side == .old ? line.oldNumber : line.newNumber
    append(
      .line(path: path, hunk: hunk, line: line, highlight: highlight(side, number)), kind: "l")
    record(DiffLineAnchor.all(line, path: path))
  }

  private mutating func lineRow(left: SplitCell?, right: SplitCell?, hunk: Int?) {
    let mark: SplitHighlight? =
      if let range = left.flatMap({ $0.kind == .removed ? highlight(.old, $0.number) : nil }) {
        SplitHighlight(side: .old, range: range)
      } else if let range = right.flatMap({ highlight(.new, $0.number) }) {
        SplitHighlight(side: .new, range: range)
      } else {
        nil
      }
    append(.split(path: path, hunk: hunk, left: left, right: right, highlight: mark), kind: "l")
    var anchors: [DiffLineAnchor] = []
    if let left, left.kind != .added {
      anchors.append(DiffLineAnchor(path: path, side: .old, line: left.number))
    }
    if let right, right.kind != .removed {
      anchors.append(DiffLineAnchor(path: path, side: .new, line: right.number))
    }
    record(anchors)
  }

  /// Notes the row just added as the one drawing `anchors`, and puts their annotations under it.
  private mutating func record(_ anchors: [DiffLineAnchor]) {
    guard let id = rows.last?.0 else { return }
    for anchor in anchors where lineIDs[anchor] == nil { lineIDs[anchor] = id }
    for anchor in anchors where !placed.contains(anchor) {
      guard let view = content.annotations.lines[anchor] else { continue }
      placed.insert(anchor)
      append(.annotation(view), kind: "a")
    }
  }

  private func highlight(_ side: DiffLineAnchor.Side, _ number: UInt64?) -> Range<Int>? {
    guard let match = content.highlight, match.target.kind == .line,
      match.target.path == path, match.target.side == side, match.target.line == number
    else { return nil }
    return match.range
  }

  /// Each hunk's side-by-side pairs, from the core's rows.
  static func splitRows(_ diff: FileDiff) -> [Int: [(SplitCell?, SplitCell?)]] {
    var result: [Int: [(SplitCell?, SplitCell?)]] = [:]
    var current = 0
    for row in diff.splitRows {
      switch row {
      case .hunk(let index, _): current = index
      case .line(let left, let right): result[current, default: []].append((left, right))
      }
    }
    return result
  }
}
