import Foundation

#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

/// Builds a CLI block's text as the CLI views draw it (``CLIStyledMarkdown``, ``CLISourceText``,
/// ``CLIUserText``, ``CLIFooterLine``): the monospaced font, the CLI palette, the gutter's
/// markers aside. Each SwiftUI `Text` becomes a unit of paragraphs; ``CLITextLayout`` spaces
/// them as SwiftUI's stacks do. Styled blocks are in `CLITextBuilder+Blocks.swift`. It runs
/// off the main actor too.
nonisolated struct CLITextBuilder {
  let style: CLITextStyle
  let metrics: CLITextMetrics
  let output = NSMutableAttributedString()
  var units: [CLITextUnit] = []
  /// A list item's marker, which the next text's first line starts with.
  var pendingMarker: Marker?
  /// What each region reads as, by its id.
  var labels: [String: String] = [:]

  /// A list item's marker and where its column starts.
  struct Marker {
    var text: NSAttributedString
    var start: CGFloat
  }

  /// Where a block sits: its leading edge, its text color, and what its views read from the
  /// environment (``EnvironmentValues/cliQuoteLineGrid``,
  /// ``EnvironmentValues/cliNestedListIndent``).
  struct Context {
    var indent: CGFloat = 0
    var color: SRGB
    var onLineGrid = false
    var nestedListIndent = 0
  }

  /// The look of a run of inline text before its own emphasis.
  struct InlineBase {
    var color: SRGB
    var weight: PlatformFont.Weight = .regular
    var italic = false
    var underline = false
  }

  init(style: CLITextStyle) {
    self.style = style
    metrics = style.metrics
  }

  var palette: CLIPalette { style.palette }

  /// Builds `spec`.
  static func build(_ spec: CLITextSpec, style: CLITextStyle) -> CLITextBuild {
    var builder = Self(style: style)
    let root: CLITextNode
    switch spec {
    case .styled(let markdown):
      root = builder.blocks(
        MarkdownCache.shared.blocks(for: markdown), in: Context(color: style.palette.body))
    case .plain(let text):
      root = builder.source(text, color: style.palette.body, tintsMarkdown: true, indent: 0)
    case .prompt(let text):
      root = builder.prompt(text)
    case .footer(let text):
      root = builder.unit(builder.plain(text, color: style.palette.dim), indent: 0)
    case .work(let work):
      root = builder.work(work)
    }
    return builder.finish(root)
  }

  /// `lines` lines of `glyph` on the text's pitch: a quote's column of markers, a block's bullet.
  static func glyphs(_ glyph: String, lines: Int, color: SRGB, style: CLITextStyle)
    -> NSAttributedString
  {
    var builder = Self(style: style)
    let column = Array(repeating: glyph, count: max(1, lines)).joined(separator: "\n")
    return builder.finish(builder.unit(builder.plain(column, color: color), indent: 0)).text
  }

  /// The text built so far, without its last line break.
  private func finish(_ root: CLITextNode) -> CLITextBuild {
    if output.string.hasSuffix("\n") {
      let last = NSRange(location: output.length - 1, length: 1)
      // An empty last paragraph keeps a space, so it keeps its line.
      if output.length == 1 || output.string.hasSuffix("\n\n") {
        output.replaceCharacters(in: last, with: " ")
      } else {
        output.deleteCharacters(in: last)
      }
    }
    var units = units
    if var last = units.last {
      last.range.length = min(last.range.length, output.length - last.range.location)
      units[units.count - 1] = last
    }
    return CLITextBuild(
      text: NSAttributedString(attributedString: output), units: units, root: root,
      labels: labels)
  }

  // MARK: Texts

  /// Appends one text: `content`, which may hold several paragraphs, at `indent`, its cells on
  /// `tabs` when it has any.
  @discardableResult
  mutating func unit(
    _ content: NSAttributedString, indent: CGFloat, tabs: [NSTextTab] = [],
    lineBreak: NSLineBreakMode = .byWordWrapping, padTop: CGFloat = 0, padBottom: CGFloat = 0
  ) -> CLITextNode {
    let start = output.length
    let paragraph = NSMutableAttributedString()
    let marker = pendingMarker
    pendingMarker = nil
    if let marker {
      paragraph.append(marker.text)
      paragraph.append(NSAttributedString(string: "\t", attributes: [.font: metrics.font()]))
    }
    let markerLength = paragraph.length
    paragraph.append(content)
    paragraph.append(NSAttributedString(string: "\n", attributes: [.font: metrics.font()]))
    output.append(paragraph)
    let range = NSRange(location: start, length: paragraph.length)
    output.addAttribute(
      .paragraphStyle, value: paragraphStyle(indent: indent, tabs: tabs, lineBreak: lineBreak),
      range: range)
    if let marker {
      // The marker hangs in its column on the first line only; a copy leaves it out, as the
      // CLI's marker is a view of its own.
      let stops = ([NSTextTab(textAlignment: .left, location: indent)] + tabs)
        .sorted { $0.location < $1.location }
      let hung = paragraphStyle(indent: indent, tabs: stops, lineBreak: lineBreak)
      hung.firstLineHeadIndent = marker.start
      output.addAttribute(.paragraphStyle, value: hung, range: output.paragraph(startingAt: start))
      output.addAttribute(
        .messageCopy, value: MessageCopyText.omitted,
        range: NSRange(location: start, length: markerLength))
    }
    units.append(CLITextUnit(range: range, padTop: padTop, padBottom: padBottom))
    return .text(units.count - 1)
  }

  /// A paragraph style on SwiftUI's line pitch: TextKit's own line height, and the spacing that
  /// makes up SwiftUI's taller line.
  private func paragraphStyle(indent: CGFloat, tabs: [NSTextTab], lineBreak: NSLineBreakMode)
    -> NSMutableParagraphStyle
  {
    let style = NSMutableParagraphStyle()
    style.minimumLineHeight = metrics.textKitLineHeight
    style.maximumLineHeight = metrics.textKitLineHeight
    style.lineSpacing = metrics.textKitSpacing
    style.firstLineHeadIndent = indent
    style.headIndent = indent
    if !tabs.isEmpty { style.tabStops = tabs }
    style.lineBreakMode = lineBreak
    return style
  }

  /// `text` in the CLI font and `color`.
  func plain(_ text: String, color: SRGB, weight: PlatformFont.Weight = .regular)
    -> NSAttributedString
  {
    NSAttributedString(
      string: text,
      attributes: [.font: metrics.font(weight: weight), .foregroundColor: color.platformColor])
  }

  // MARK: Inline text

  /// The attributes of inline text with no emphasis of its own.
  func attributes(_ base: InlineBase) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [
      .font: metrics.font(weight: base.weight, italic: base.italic),
      .foregroundColor: base.color.platformColor,
    ]
    if base.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    return attributes
  }

  /// Inline markdown restyled with CLI colors, as ``CLIInline`` styles it: code green, bold and
  /// italic in the emphasis colors, links blue and underlined with their URL after them.
  func inline(_ text: AttributedString, base: InlineBase) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let runs = Array(text.runs)
    for (index, run) in runs.enumerated() {
      let intent = run.inlinePresentationIntent ?? []
      let strong = intent.contains(.stronglyEmphasized)
      var styled = attributes(base)
      styled[.font] = metrics.font(
        weight: strong ? .bold : base.weight,
        italic: base.italic || intent.contains(.emphasized))
      if intent.contains(.strikethrough) {
        styled[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      if intent.contains(.code) {
        styled[.foregroundColor] = palette.code.platformColor
      } else if strong {
        styled[.foregroundColor] = palette.bold.platformColor
      } else if intent.contains(.emphasized) {
        styled[.foregroundColor] = palette.italic.platformColor
      }
      let label = String(text[run.range].characters)
      guard let link = run.link else {
        result.append(NSAttributedString(string: label, attributes: styled))
        continue
      }
      styled[.foregroundColor] = palette.link.platformColor
      styled[.underlineStyle] = NSUnderlineStyle.single.rawValue
      styled[.link] = link
      result.append(NSAttributedString(string: label, attributes: styled))
      let next = index + 1 < runs.count ? runs[index + 1].link : nil
      // The URL follows the link text, as a terminal shows it, unless the text is the URL.
      guard next != link, label != link.absoluteString else { continue }
      let around = attributes(base)
      var url = around
      url[.foregroundColor] = palette.link.platformColor
      url[.underlineStyle] = NSUnderlineStyle.single.rawValue
      url[.link] = link
      result.append(NSAttributedString(string: " (", attributes: around))
      result.append(NSAttributedString(string: link.absoluteString, attributes: url))
      result.append(NSAttributedString(string: ")", attributes: around))
    }
    return result
  }

  // MARK: Plain

  /// Source text exactly as written (``CLISourceText``): markdown syntax tinted when
  /// `tintsMarkdown`, web addresses and markdown links linked and underlined.
  mutating func source(_ text: String, color: SRGB, tintsMarkdown: Bool, indent: CGFloat)
    -> CLITextNode
  {
    let spans = tintsMarkdown ? SourceTinting.spans(in: text) : []
    return unit(tinted(text, spans: spans, color: color), indent: indent)
  }

  /// `text` colored by `spans`, as ``SourceTinting/attributed(_:spans:palette:cursor:)`` colors
  /// it: later (inner) spans win over the ones around them.
  private func tinted(_ text: String, spans: [SourceTinting.Span], color: SRGB)
    -> NSAttributedString
  {
    let utf8 = text.utf8
    var tints = [SourceTint](repeating: .none, count: utf8.count)
    var links = SourceLinks(text)
    for span in spans {
      for index in span.range where index < tints.count { tints[index] = span.tint }
      if let link = span.link { links.claim(span.range, for: link) }
    }
    let result = NSMutableAttributedString()
    let font = metrics.font()
    var start = 0
    var startIndex = utf8.startIndex
    while start < tints.count {
      var end = start + 1
      while end < tints.count, tints[end] == tints[start], links.isSame(end, start) { end += 1 }
      // Span edges come from the parser, so they fall on character boundaries.
      let endIndex = utf8.index(startIndex, offsetBy: end - start)
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: (tint(tints[start]) ?? color).platformColor,
      ]
      if let link = links.url(at: start) {
        attributes[.link] = link
        if tints[start] == .none { attributes[.foregroundColor] = palette.link.platformColor }
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
      } else if tints[start] == .link {
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
      }
      result.append(
        NSAttributedString(string: String(text[startIndex..<endIndex]), attributes: attributes))
      start = end
      startIndex = endIndex
    }
    return result
  }

  private func tint(_ tint: SourceTint) -> SRGB? {
    switch tint {
    case .none: nil
    case .heading: palette.heading
    case .bold: palette.bold
    case .italic: palette.italic
    case .code, .fence: palette.code
    case .link: palette.link
    }
  }

  // MARK: Prompts

  /// A user's prompt as ``CLIUserText`` draws it: the text as typed, quoted runs in the quote
  /// color beside a bar, an answered question's quoted line and a design subject dim, a small
  /// gap apart.
  private mutating func prompt(_ text: String) -> CLITextNode {
    let runs = UserPrompt.runs(text)
    if runs.count == 1, let only = runs.first, !only.isQuote, !only.isNote {
      return source(only.text, color: palette.userText, tintsMarkdown: false, indent: 0)
    }
    let gap = MessageTextMetrics.small
    var items: [CLITextStackItem] = []
    for (index, run) in runs.enumerated() {
      let node: CLITextNode
      if run.isQuestion || run.isNote {
        node = source(run.text, color: palette.dim, tintsMarkdown: false, indent: 0)
      } else if run.isQuote {
        node = .bar(
          source(run.text, color: palette.quote, tintsMarkdown: false, indent: gap), leading: 0,
          color: palette.quote)
      } else {
        node = source(run.text, color: palette.userText, tintsMarkdown: false, indent: 0)
      }
      items.append(CLITextStackItem(gap: index == 0 ? 0 : gap, node: node))
    }
    return .stack(items)
  }
}
