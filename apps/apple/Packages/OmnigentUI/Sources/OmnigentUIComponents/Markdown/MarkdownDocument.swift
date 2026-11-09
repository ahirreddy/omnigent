import Foundation
import Markdown
import OmnigentPlatform
import SwiftUI

/// Column alignment of a markdown table.
nonisolated enum MarkdownAlignment: Hashable, Sendable {
  case leading
  case center
  case trailing
}

/// A GFM table, cells already rendered to inline text.
nonisolated struct MarkdownTable: Hashable, Sendable {
  var header: [AttributedString]
  var rows: [[AttributedString]]
  var alignments: [MarkdownAlignment]
}

/// A list item's task checkbox.
nonisolated enum MarkdownTask: Hashable, Sendable {
  case none
  case checked
  case unchecked
}

/// One list item: its blocks and an optional task checkbox.
nonisolated struct MarkdownListItem: Hashable, Sendable {
  var blocks: [MarkdownBlock]
  var task: MarkdownTask
}

/// A block of rendered markdown. Built once per text and cached (``MarkdownCache``).
nonisolated indirect enum MarkdownBlock: Hashable, Sendable {
  case paragraph(AttributedString)
  case heading(level: Int, text: AttributedString)
  case code(language: String?, code: String)
  case quote([Self])
  case list(ordered: Bool, start: Int, items: [MarkdownListItem])
  case table(MarkdownTable)
  case rule
  /// Raw HTML, shown as written and never interpreted.
  case html(String)
  /// An image alone in its paragraph whose source is a workspace path or a `data:` URL.
  case image(source: String, alt: String)
  /// Display math, as TeX.
  case math(String)
}

/// Parses markdown (CommonMark plus GFM tables, strikethrough and task lists) with Apple's
/// `swift-markdown` into ``MarkdownBlock``s.
///
/// Safety: links keep only `http`, `https` and `mailto` destinations; a link to a file path and
/// path-shaped inline code are tagged (``WorkspacePathAttribute``) for ``WorkspaceFileLinks`` to
/// link once the file is known to exist; anything else renders as plain text. Remote images are
/// never fetched; they render as their alt text, linked when the source is `http(s)`. An image
/// alone in its paragraph from the workspace or a `data:` URL becomes an ``MarkdownBlock/image``
/// block. Raw HTML is shown verbatim.
nonisolated enum MarkdownParser {
  static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]
  /// Quotes and lists deeper than this draw as text: each level costs layout and width.
  static let maxNesting = 16

  static func parse(_ text: String) -> [MarkdownBlock] {
    let document = Document(parsing: MarkdownMath.delimited(text), options: [.disableSmartOpts])
    return blocks(document.children)
  }

  static func safeURL(_ destination: String?) -> URL? {
    guard let destination, let url = URL(string: destination),
      let scheme = url.scheme?.lowercased(), allowedLinkSchemes.contains(scheme)
    else { return nil }
    if scheme != "mailto", url.host() == nil { return nil }
    return url
  }

  private static func blocks(_ children: MarkupChildren) -> [MarkdownBlock] {
    children.compactMap(block)
  }

  /// Top-level blocks as ``MarkdownStream`` parses them.
  static func blocks(_ markup: [any Markup], source _: Substring, base _: Int) -> [MarkdownBlock] {
    markup.compactMap(block)
  }

  static func block(_ markup: any Markup) -> MarkdownBlock? {
    switch markup {
    case let paragraph as Paragraph:
      return soleImage(paragraph) ?? .paragraph(inline(paragraph.children))
    case let heading as Heading:
      return .heading(level: heading.level, text: inline(heading.children))
    case let code as CodeBlock:
      let language = code.language?.trimmingCharacters(in: .whitespaces)
      var body = code.code
      if body.hasSuffix("\n") { body.removeLast() }
      if language?.lowercased() == "math" { return .math(body) }
      return .code(language: language?.isEmpty == true ? nil : language, code: body)
    case is BlockQuote, is OrderedList, is UnorderedList, is Markdown.Table:
      if nestingDepth(of: markup) >= maxNesting { return plainText(markup) }
      return container(markup)
    case is ThematicBreak:
      return .rule
    case let html as HTMLBlock:
      let raw = html.rawHTML.trimmingCharacters(in: .newlines)
      return raw.isEmpty ? nil : .html(raw)
    default:
      return plainText(markup)
    }
  }

  /// A block drawn as its source, for a doc directive or anything nested past ``maxNesting``.
  private static func plainText(_ markup: any Markup) -> MarkdownBlock? {
    let text = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : .paragraph(AttributedString(text))
  }

  /// How many quotes and lists hold this block.
  private static func nestingDepth(of markup: any Markup) -> Int {
    var depth = 0
    var ancestor = markup.parent
    while let current = ancestor {
      if current is BlockQuote || current is OrderedList || current is UnorderedList { depth += 1 }
      ancestor = current.parent
    }
    return depth
  }

  /// An image block for a paragraph holding only one image from the workspace or a `data:` URL.
  private static func soleImage(_ paragraph: Paragraph) -> MarkdownBlock? {
    guard paragraph.childCount == 1, let image = paragraph.child(at: 0) as? Markdown.Image,
      let source = image.source, MarkdownImageSource(source) != nil
    else { return nil }
    return .image(source: source, alt: String(inline(image.children).characters))
  }

  private static func container(_ markup: any Markup) -> MarkdownBlock? {
    switch markup {
    case let quote as BlockQuote:
      .quote(blocks(quote.children))
    case let list as OrderedList:
      .list(ordered: true, start: Int(list.startIndex), items: items(list.listItems))
    case let list as UnorderedList:
      .list(ordered: false, start: 1, items: items(list.listItems))
    case let table as Markdown.Table:
      .table(self.table(table))
    default:
      nil
    }
  }

  private static func items(_ items: some Sequence<ListItem>) -> [MarkdownListItem] {
    items.map { item in
      let task: MarkdownTask =
        switch item.checkbox {
        case .checked: .checked
        case .unchecked: .unchecked
        case nil: .none
        }
      return MarkdownListItem(blocks: blocks(item.children), task: task)
    }
  }

  private static func table(_ table: Markdown.Table) -> MarkdownTable {
    let alignments = table.columnAlignments.map { alignment -> MarkdownAlignment in
      switch alignment {
      case .center: .center
      case .right: .trailing
      case .left, nil: .leading
      }
    }
    let header: [AttributedString] = table.head.cells.map { inline($0.children) }
    let rows: [[AttributedString]] = table.body.rows.map { row in
      row.cells.map { inline($0.children) }
    }
    let width = max(header.count, rows.map(\.count).max() ?? 0)
    func padded(_ cells: [AttributedString]) -> [AttributedString] {
      cells + Array(repeating: AttributedString(), count: max(0, width - cells.count))
    }
    return MarkdownTable(
      header: padded(header), rows: rows.map(padded),
      alignments: alignments + Array(repeating: .leading, count: max(0, width - alignments.count))
    )
  }

  private static func inline(_ children: MarkupChildren) -> AttributedString {
    var result = AttributedString()
    for child in children {
      result.append(inline(child))
    }
    return result
  }

  private static func inline(_ markup: any Markup) -> AttributedString {
    switch markup {
    case let text as Markdown.Text:
      return AttributedString(text.string)
    case is SoftBreak:
      return AttributedString(" ")
    case is LineBreak:
      return AttributedString("\n")
    case let code as InlineCode:
      if let tex = MarkdownMath.inlineSource(code.code) {
        var span = AttributedString(MathText.unicode(tex))
        span[MathSpanAttribute.self] = tex
        return span
      }
      var span = AttributedString(code.code)
      span.inlinePresentationIntent = .code
      span.backgroundColor = Color.secondary.opacity(0.14)
      if WorkspacePaths.mayCite(code.code) { span[WorkspacePathAttribute.self] = code.code }
      return span
    case is Emphasis, is Strong, is Strikethrough:
      return styled(markup)
    case is Markdown.Link, is Markdown.Image:
      return linked(markup)
    case let html as InlineHTML:
      return AttributedString(html.rawHTML)
    default:
      return AttributedString(markup.format())
    }
  }

  private static func linked(_ markup: any Markup) -> AttributedString {
    switch markup {
    case let link as Markdown.Link:
      var span = inline(link.children)
      if span.characters.isEmpty { span = AttributedString(link.destination ?? "") }
      if let url = safeURL(link.destination) {
        span.link = url
      } else if let path = WorkspacePaths.linkedPath(link.destination) {
        span[WorkspacePathAttribute.self] = path
        span[WorkspacePathIsExplicitAttribute.self] = true
      }
      return span
    case let image as Markdown.Image:
      let alt = String(inline(image.children).characters)
      var span = AttributedString(alt.isEmpty ? "[Image]" : "[Image: \(alt)]")
      if let url = safeURL(image.source) { span.link = url }
      return span
    default:
      return AttributedString(markup.format())
    }
  }

  private static func styled(_ markup: any Markup) -> AttributedString {
    switch markup {
    case let emphasis as Emphasis: adding(.emphasized, to: inline(emphasis.children))
    case let strong as Strong: adding(.stronglyEmphasized, to: inline(strong.children))
    case let strike as Strikethrough: adding(.strikethrough, to: inline(strike.children))
    default: AttributedString(markup.format())
    }
  }

  private static func adding(_ intent: InlinePresentationIntent, to text: AttributedString)
    -> AttributedString
  {
    var text = text
    for run in text.runs {
      let existing = run.inlinePresentationIntent ?? []
      text[run.range].inlinePresentationIntent = existing.union(intent)
    }
    return text
  }
}

/// A dictionary that forgets its oldest entries past `limit`, in amortized constant time.
nonisolated struct BoundedCache<Key: Hashable, Value> {
  private let limit: Int
  private var entries: [Key: Value] = [:]
  private var order: [Key] = []
  private var head = 0

  init(limit: Int) {
    self.limit = max(limit, 1)
  }

  var count: Int { entries.count }

  /// How many entries it keeps.
  var capacity: Int { limit }

  func cached(_ key: Key) -> Value? { entries[key] }

  mutating func value(for key: Key, make: () -> Value) -> Value {
    if let cached = entries[key] { return cached }
    let value = make()
    store(value, for: key)
    return value
  }

  /// Keeps `value` for `key`, unless `key` has one already.
  mutating func store(_ value: Value, for key: Key) {
    guard entries[key] == nil else { return }
    entries[key] = value
    order.append(key)
    if order.count - head > limit {
      entries[order[head]] = nil
      head += 1
      if head >= limit {
        order.removeFirst(head)
        head = 0
      }
    }
  }
}

/// One view's parse of its text: the same text returns the same blocks without hashing it, a
/// growing stream parses only its open block (``MarkdownStream``), and settled text comes from
/// ``MarkdownCache``.
@MainActor
final class MarkdownRenderMemo {
  private var text: String?
  private var blocks: [MarkdownBlock] = []
  private var stream = MarkdownStream(convert: MarkdownParser.blocks)
  private var citedText: String?
  private var cited: [CitedPath] = []

  func blocks(for text: String, isStreaming: Bool) -> [MarkdownBlock] {
    if text == self.text { return blocks }
    blocks =
      isStreaming
      ? stream.elements(for: MarkdownMath.delimited(text))
      : MarkdownCache.shared.blocks(for: text)
    self.text = text
    return blocks
  }

  /// The workspace paths the blocks of `text` cite, collected once per text.
  func citedPaths(for text: String) -> [CitedPath] {
    if citedText != text {
      cited = MarkdownBlock.citedPaths(in: blocks)
      citedText = text
    }
    return cited
  }
}
