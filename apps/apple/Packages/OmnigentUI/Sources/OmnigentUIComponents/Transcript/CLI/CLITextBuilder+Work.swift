import Foundation

#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

// MARK: Tool work

nonisolated extension CLITextBuilder {
  /// A turn's tool work: its cells a block gap apart, each in a region the reader acts on.
  mutating func work(_ spec: CLIWorkSpec) -> CLITextNode {
    var items: [CLITextStackItem] = []
    for cell in spec.cells {
      items.append(
        CLITextStackItem(gap: items.isEmpty ? 0 : CLIMetrics.blockGap, node: self.cell(cell)))
    }
    return .stack(items)
  }

  /// A cell: its `•` line, the marker hanging in the gutter, then its details.
  private mutating func cell(_ cell: CLIWorkCell) -> CLITextNode {
    let line = unit(text(cell.line), indent: 0)
    var items = [
      CLITextStackItem(
        gap: 0, node: .marked(line, glyph: cell.glyph, color: cell.marker ?? palette.bullet))
    ]
    let gap =
      switch cell.gap {
      case .lineSpacing: metrics.lineSpacing
      case .small: MessageTextMetrics.extraSmall
      }
    for detail in cell.details {
      items.append(CLITextStackItem(gap: gap, node: self.detail(detail)))
    }
    return .region(.stack(items), id: cell.id)
  }

  private mutating func detail(_ detail: CLIWorkDetail) -> CLITextNode {
    switch detail {
    case .tree(let tree):
      return self.tree(tree)
    case .commandLines(let lines, let limit, let showsAll, let action):
      return commandLines(lines, limit: limit, showsAll: showsAll, action: action)
    case .diff(let files, let limit, let action):
      return diff(files, limit: limit, action: action)
    case .plan(let note, let steps):
      return plan(note: note, steps: steps)
    case .branch(let text, let isFirst, let id, let trees):
      var items = [
        CLITextStackItem(gap: 0, node: branch(isFirst ? "\u{2514} " : "  ", self.text(text)))
      ]
      for tree in trees {
        items.append(CLITextStackItem(gap: metrics.lineSpacing, node: self.tree(tree)))
      }
      return .region(.stack(items), id: id)
    }
  }

  /// A terminal line from its parts: bold where it says, its shell command highlighted.
  func text(_ line: CLILineText) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for part in line.parts {
      if part.isShell {
        result.append(highlighted(part.text, language: "bash", color: palette.body))
      } else {
        result.append(
          plain(part.text, color: part.color ?? palette.body, weight: part.bold ? .bold : .regular))
      }
    }
    return result
  }

  /// The width of a branch's `└ ` and the text after it, as a line beside it starts there.
  private var branchWidth: CGFloat {
    metrics.ceiled(Self.width(of: plain("\u{2514} ", color: palette.dim)))
  }

  /// `prefix` in the gutter of a line, `content` beside it.
  private mutating func branch(
    _ prefix: String, _ content: NSAttributedString, indent: CGFloat = 0
  ) -> CLITextNode {
    pendingMarker = Marker(text: plain(prefix, color: palette.dim), start: indent)
    return unit(content, indent: indent + branchWidth)
  }

  /// "… +N lines", which opens `action`.
  private mutating func more(_ hidden: Int, indent: CGFloat, action: String) -> CLITextNode {
    .region(
      unit(plain(CLIOutputTree.more(hidden), color: palette.dim), indent: indent),
      id: CLITextDecoration.morePrefix + action)
  }

  /// Text on the `└` branch, as ``CLIOutputTree`` shows it.
  private mutating func tree(_ tree: CLIWorkTree) -> CLITextNode {
    let lines = tree.text.split(separator: "\n", omittingEmptySubsequences: false)
    let isCut = !tree.showsAll && lines.count > tree.limit
    let shown = isCut ? lines.prefix(tree.limit).joined(separator: "\n") : tree.text
    let indent = metrics.character * CGFloat(tree.indent)
    pendingMarker = Marker(text: plain("\u{2514} ", color: palette.dim), start: indent)
    let content = source(
      shown, color: tree.color, tintsMarkdown: false, indent: indent + branchWidth)
    guard isCut else { return content }
    return .stack([
      CLITextStackItem(gap: 0, node: content),
      CLITextStackItem(
        gap: metrics.lineSpacing,
        node: more(
          lines.count - tree.limit, indent: indent + metrics.character * 2,
          action: tree.action)),
    ])
  }

  /// A command's lines after its first, as ``CLICommandLines`` draws them.
  private mutating func commandLines(
    _ lines: [String], limit: Int, showsAll: Bool, action: String
  ) -> CLITextNode {
    let isCut = !showsAll && lines.count > limit
    let shown = isCut ? Array(lines.prefix(limit)) : lines
    var items: [CLITextStackItem] = []
    for line in shown {
      let node = branch(
        "\u{2502} ", highlighted(line, language: "bash", color: palette.body))
      items.append(CLITextStackItem(gap: items.isEmpty ? 0 : metrics.lineSpacing, node: node))
    }
    if isCut {
      pendingMarker = Marker(text: plain("\u{2502} ", color: palette.dim), start: 0)
      items.append(
        CLITextStackItem(
          gap: items.isEmpty ? 0 : metrics.lineSpacing,
          node: more(lines.count - shown.count, indent: branchWidth, action: action)))
    }
    return .stack(items)
  }

  /// A plan update's steps, as ``CLIPlanSteps`` draws them.
  private mutating func plan(note: String?, steps: [CLIPlanStep]) -> CLITextNode {
    var rows: [NSAttributedString] = []
    if let note {
      rows.append(
        NSAttributedString(
          string: note,
          attributes: [
            .font: metrics.font(italic: true), .foregroundColor: palette.dim.platformColor,
          ]))
    }
    for step in steps {
      var attributes: [NSAttributedString.Key: Any] = [
        .font: metrics.font(), .foregroundColor: palette.dim.platformColor,
      ]
      switch step.status {
      case .completed: attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      case .inProgress:
        attributes[.foregroundColor] = palette.marker.platformColor
        attributes[.font] = metrics.font(weight: .bold)
      case .pending: break
      }
      let box = step.status == .completed ? "\u{2714} " : "\u{25A1} "
      rows.append(NSAttributedString(string: box + step.text, attributes: attributes))
    }
    var items: [CLITextStackItem] = []
    for (index, row) in rows.enumerated() {
      items.append(
        CLITextStackItem(
          gap: index == 0 ? 0 : metrics.lineSpacing,
          node: branch(index == 0 ? "\u{2514} " : "  ", row)))
    }
    return .stack(items)
  }

  // MARK: Diffs

  /// An edit's files, as ``CLIDiffFiles`` draws them: each file's line when there are several,
  /// its changed lines two characters in, the first `limit` across them all.
  private mutating func diff(_ files: [CLIDiffFile], limit: Int, action: String) -> CLITextNode {
    let shown = CLIDiffFiles.rows(of: files, limit: limit)
    let hidden = files.reduce(0) { $0 + $1.rows.count } - shown.reduce(0) { $0 + $1.count }
    var items: [CLITextStackItem] = []
    let spacing = metrics.lineSpacing
    for (index, pair) in zip(files, shown).enumerated() {
      if files.count > 1 {
        items.append(
          CLITextStackItem(
            gap: items.isEmpty ? 0 : spacing + (index == 0 ? 0 : metrics.line),
            node: unit(fileLine(pair.0), indent: 0)))
      }
      items.append(
        CLITextStackItem(gap: items.isEmpty ? 0 : spacing, node: diffRows(pair.1)))
    }
    if hidden > 0 {
      items.append(
        CLITextStackItem(
          gap: items.isEmpty ? 0 : spacing,
          node: more(hidden, indent: metrics.character * 2, action: action)))
    }
    return .stack(items)
  }

  /// "└ path (+1 -1)".
  private func fileLine(_ file: CLIDiffFile) -> NSAttributedString {
    var line = CLILineText()
    line.append("\u{2514} ", palette.dim)
    line.append(file.path)
    CLIDiffCounts.append(to: &line, added: file.added, removed: file.removed, palette)
    return text(line)
  }

  /// A file's changed lines, as ``CLIDiffRows`` draws them: numbers dim, added and removed
  /// lines in their colors on a faint band.
  private mutating func diffRows(_ rows: [CLIDiffFile.Row]) -> CLITextNode {
    let character = metrics.character
    let leading = character * 2
    let digits = rows.compactMap(\.number).max().map { "\($0)".count } ?? 0
    let signX = leading + (digits > 0 ? character * CGFloat(digits + 1) : 0)
    var items: [CLITextStackItem] = []
    for row in rows {
      let color = rowColor(row.kind)
      let marker = NSMutableAttributedString()
      var tabs = [NSTextTab(textAlignment: .left, location: signX)]
      if digits > 0 {
        tabs.insert(
          NSTextTab(textAlignment: .right, location: leading + character * CGFloat(digits)),
          at: 0)
        marker.append(plain("\t" + (row.number.map(String.init) ?? ""), color: palette.dim))
        marker.append(plain("\t", color: color))
      }
      marker.append(plain(CLIDiffRows.sign(row.kind), color: color))
      pendingMarker = Marker(text: marker, start: leading)
      let node = unit(
        plain(row.text.isEmpty ? " " : row.text, color: color), indent: signX + character,
        tabs: tabs, padTop: metrics.lineSpacing / 2, padBottom: metrics.lineSpacing / 2)
      let band: SRGB? =
        switch row.kind {
        case .added: palette.added
        case .removed: palette.failure
        default: nil
        }
      items.append(
        CLITextStackItem(
          gap: 0,
          node: band.map { .background(node, leading: leading, color: $0, opacity: 0.12) }
            ?? node))
    }
    return .stack(items)
  }

  private func rowColor(_ kind: DiffLineKind?) -> SRGB {
    switch kind {
    case .added: palette.added
    case .removed: palette.failure
    case .context: palette.body
    default: palette.dim
    }
  }
}
