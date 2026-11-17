import Foundation
import Synchronization

#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

/// What a CLI text draws beside its text, in its own coordinates: table rules and a prompt
/// quote's bar, and columns of markers (a quote's `>`s).
nonisolated enum CLITextDecoration: Equatable, Sendable {
  /// A rectangle filled with a color.
  case fill(CGRect, SRGB, opacity: Double)
  /// `glyph` on each line from the rectangle's top, on the text's pitch, cut off at its bottom.
  case markers(String, CGRect, SRGB)
  /// Where the reader acts on something, by id: a tool call, or "… +N lines" (``morePrefix``).
  case region(CGRect, String)

  /// The start of a region's id that opens what it names.
  static let morePrefix = "more:"
}

/// A CLI block's text laid out at one width as SwiftUI lays its views out, built once and shared
/// by the views that show it: its text as a message document (``MessageTextDocument``, which a
/// raster or a live text view draws), SwiftUI's height for it and what it draws beside its text.
nonisolated final class CLITextDocument: @unchecked Sendable {
  let text: MessageTextDocument
  let width: CGFloat
  let height: CGFloat
  let decorations: [CLITextDecoration]

  init(
    text: MessageTextDocument, width: CGFloat, height: CGFloat,
    decorations: [CLITextDecoration]
  ) {
    self.text = text
    self.width = width
    self.height = height
    self.decorations = decorations
  }

  /// Builds `spec` in `style` and lays it out `width` wide.
  static func make(
    _ spec: CLITextSpec, style: CLITextStyle, width: CGFloat, palette: MessageTextPalette
  ) -> CLITextDocument {
    let laidOut = CLITextLayout.layOut(
      CLITextBuilder.build(spec, style: style), width: width, metrics: style.metrics)
    let document = MessageTextDocument(
      text: laidOut.text, palette: palette, chrome: [:], hasWideBlocks: false,
      topInset: laidOut.topInset)
    return CLITextDocument(
      text: document, width: width, height: laidOut.height, decorations: laidOut.decorations)
  }
}

/// Which CLI text a document lays out, in which style, at which width.
nonisolated struct CLITextKey: Hashable, Sendable {
  var spec: CLITextSpec
  var style: CLITextStyle
  var width: CGFloat
}

/// Built CLI documents, shared by the cells and the prewarm that builds them off the main actor.
nonisolated final class CLITextDocuments: Sendable {
  static let shared = CLITextDocuments(limit: 1024)

  private struct State {
    var entries: BoundedCache<CLITextKey, CLITextDocument>
    /// The style the last document was asked for in.
    var style: CLITextStyle?
  }

  private let state: Mutex<State>

  init(limit: Int) {
    state = Mutex(State(entries: BoundedCache(limit: limit)))
  }

  /// The document built for `key`, if one was.
  func cached(_ key: CLITextKey) -> CLITextDocument? {
    state.withLock { $0.entries.cached(key) }
  }

  /// The document for `key`, built now on a miss. A new style lets the old one's go.
  func document(for key: CLITextKey, palette: MessageTextPalette) -> CLITextDocument {
    if let cached = cached(key) { return cached }
    let built = CLITextDocument.make(key.spec, style: key.style, width: key.width, palette: palette)
    store(built, for: key)
    return cached(key) ?? built
  }

  func store(_ document: CLITextDocument, for key: CLITextKey) {
    state.withLock { state in
      if let style = state.style, style != key.style {
        state.entries.removeAll { kept, _ in kept.style != key.style }
      }
      state.style = key.style
      state.entries.store(document, for: key)
    }
  }

  /// Documents kept, for tests.
  var count: Int { state.withLock { $0.entries.count } }
}

/// Lays a CLI build out as SwiftUI lays its texts out: each text's lines on SwiftUI's pitch, its
/// height rounded up to the pixel as SwiftUI rounds a `Text`'s, and the gaps of the stacks
/// around it. TextKit lays the text out once to count each text's lines; the spacing above each
/// text then puts it where SwiftUI's stacks put it.
nonisolated enum CLITextLayout {
  struct LaidOut {
    /// The text with each text's spacing set.
    var text: NSAttributedString
    /// The space above the first text.
    var topInset: CGFloat
    var height: CGFloat
    var decorations: [CLITextDecoration]
    /// Each text's top and its lines, for tests.
    var tops: [CGFloat]
    var lines: [Int]
  }

  static func layOut(_ build: CLITextBuild, width: CGFloat, metrics: CLITextMetrics) -> LaidOut {
    let lines = lineCounts(build, width: width)
    var geometry = Geometry(units: build.units, lines: lines, metrics: metrics, width: width)
    let height = geometry.place(build.root, at: 0)
    let text = NSMutableAttributedString(attributedString: build.text)
    for index in build.units.indices.dropFirst() {
      let unit = build.units[index]
      let previous = geometry.tops[index - 1] + CGFloat(lines[index - 1]) * metrics.pitch
      let spacing = max(0, geometry.tops[index] - previous)
      let paragraph = text.paragraph(startingAt: unit.range.location)
      // Nothing reads the effective range back.
      guard
        let style = unsafe text.attribute(
          .paragraphStyle, at: unit.range.location, effectiveRange: nil) as? NSParagraphStyle,
        let spaced = style.mutableCopy() as? NSMutableParagraphStyle
      else { continue }
      spaced.paragraphSpacingBefore = spacing
      text.addAttribute(.paragraphStyle, value: spaced, range: paragraph)
    }
    return LaidOut(
      text: text, topInset: geometry.tops.first ?? 0, height: height,
      decorations: geometry.decorations, tops: geometry.tops, lines: lines)
  }

  /// How many lines each text takes `width` wide.
  static func lineCounts(_ build: CLITextBuild, width: CGFloat) -> [Int] {
    var lines = [Int](repeating: 0, count: build.units.count)
    guard !build.units.isEmpty else { return lines }
    let storage = NSTextContentStorage()
    let manager = NSTextLayoutManager()
    storage.addTextLayoutManager(manager)
    let container = NSTextContainer(size: CGSize(width: width, height: 10_000_000))
    container.lineFragmentPadding = 0
    manager.textContainer = container
    storage.textStorage?.setAttributedString(build.text)
    let start = manager.documentRange.location
    var unit = 0
    _ = manager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
      let offset = storage.offset(from: start, to: fragment.rangeInElement.location)
      while unit + 1 < build.units.count, build.units[unit + 1].range.location <= offset {
        unit += 1
      }
      lines[unit] += max(1, fragment.textLineFragments.count)
      return true
    }
    return lines
  }

  /// SwiftUI's frames for a build's texts: where each text's first line starts, and what is
  /// drawn beside them.
  private struct Geometry {
    let units: [CLITextUnit]
    let lines: [Int]
    let metrics: CLITextMetrics
    /// The width the text lays out at, which regions and bands span.
    let width: CGFloat
    var tops: [CGFloat]
    var decorations: [CLITextDecoration] = []

    init(units: [CLITextUnit], lines: [Int], metrics: CLITextMetrics, width: CGFloat) {
      self.units = units
      self.lines = lines
      self.metrics = metrics
      self.width = width
      tops = [CGFloat](repeating: 0, count: units.count)
    }

    /// A node's height, as SwiftUI sizes it.
    func height(of node: CLITextNode) -> CGFloat {
      switch node {
      case .text(let index):
        let unit = units[index]
        return unit.padTop + metrics.textHeight(lines: lines[index]) + unit.padBottom
      case .stack(let items):
        return items.reduce(0) { $0 + $1.gap + height(of: $1.node) }
      case .list(let items, let compact, let loose, let threshold):
        let heights = items.map(height(of:))
        let gap = heights.contains { $0 > threshold } ? loose : compact
        return heights.reduce(0, +) + gap * CGFloat(max(0, heights.count - 1))
      case .quote(let content, _, _), .bar(let content, _, _), .marked(let content, _, _),
        .region(let content, _), .background(let content, _, _, _):
        return height(of: content)
      case .table(let rows, _, _, _):
        return rows.reduce(0) { $0 + height(of: .text($1)) }
      }
    }

    /// Places `node` at `top`, recording its texts' tops and its decorations.
    /// - Returns: Its height.
    mutating func place(_ node: CLITextNode, at top: CGFloat) -> CGFloat {
      switch node {
      case .text(let index):
        tops[index] = top + units[index].padTop
        return height(of: node)
      case .stack(let items):
        var bottom = top
        for item in items {
          bottom += item.gap
          bottom += place(item.node, at: bottom)
        }
        return bottom - top
      case .list(let items, let compact, let loose, let threshold):
        let heights = items.map(height(of:))
        let gap = heights.contains { $0 > threshold } ? loose : compact
        var bottom = top
        for (index, item) in items.enumerated() {
          if index > 0 { bottom += gap }
          bottom += place(item, at: bottom)
        }
        return bottom - top
      case .quote(let content, let markerX, let color):
        let height = place(content, at: top)
        decorations.append(
          .markers(
            ">", CGRect(x: markerX, y: top, width: metrics.character * 2, height: height), color))
        return height
      case .bar(let content, let leading, let color):
        let height = place(content, at: top)
        decorations.append(
          .fill(CGRect(x: leading, y: top, width: 2, height: height), color, opacity: 0.6))
        return height
      case .table(let rows, let rules, let columns, let color):
        placeTable(rows: rows, rules: rules, columns: columns, color: color, at: top)
        return height(of: node)
      case .marked, .region, .background:
        return placeMarked(node, at: top)
      }
    }

    /// Places a node with something beside it: a marker in the gutter, a region, a band.
    private mutating func placeMarked(_ node: CLITextNode, at top: CGFloat) -> CGFloat {
      switch node {
      case .marked(let content, let glyph, let color):
        let markers = metrics.character * 2
        decorations.append(
          .markers(
            glyph, CGRect(x: -markers, y: top, width: markers, height: metrics.lineHeight),
            color))
        return place(content, at: top)
      case .region(let content, let id):
        let height = place(content, at: top)
        decorations.append(.region(CGRect(x: 0, y: top, width: width, height: height), id))
        return height
      case .background(let content, let leading, let color, let opacity):
        let height = height(of: content)
        decorations.append(
          .fill(
            CGRect(x: leading, y: top, width: max(0, width - leading), height: height), color,
            opacity: opacity))
        return place(content, at: top)
      default:
        return place(node, at: top)
      }
    }

    /// Places a table's rows and the rules under them. Its scroll view sits on the pixel; what
    /// follows it doesn't move.
    private mutating func placeTable(
      rows: [Int], rules: [CGFloat], columns: [CLITextColumn], color: SRGB, at top: CGFloat
    ) {
      var bottom = metrics.rounded(top)
      for (index, row) in rows.enumerated() {
        bottom += place(.text(row), at: bottom)
        let rule = index < rules.count ? rules[index] : 0
        guard rule > 0 else { continue }
        for column in columns {
          decorations.append(
            .fill(
              CGRect(x: column.leading, y: bottom - rule, width: column.width, height: rule),
              color, opacity: 1))
        }
      }
    }
  }
}
