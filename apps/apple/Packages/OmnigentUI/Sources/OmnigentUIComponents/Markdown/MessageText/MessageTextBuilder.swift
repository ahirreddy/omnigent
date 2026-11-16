#if os(macOS)
  import AppKit
  import SwiftUI

  /// Builds a run of markdown blocks into one attributed string: paragraphs, headings, lists,
  /// quotes, rules, tables that fit and code blocks, spaced and styled as ``MarkdownView`` draws
  /// them. Code blocks and tables leave room for their layers and controls. Lists, code and
  /// tables are in `MessageTextBuilder+Blocks.swift`.
  struct MessageTextBuilder {
    let palette: MessageTextPalette
    let links: WorkspaceFileLinks?

    let output = NSMutableAttributedString()
    /// The gap the next paragraph keeps above it.
    var pendingGap: CGFloat = 0
    /// A list marker the next paragraph starts with.
    var pendingMarker: Marker?
    /// The last block given an id.
    var lastBlock = 0
    var chrome: [Int: MessageTextChrome] = [:]
    var hasWideBlocks = false
    var topInset: CGFloat = 0
    /// The space under the last paragraph's lines.
    var previousExtra: CGFloat = 0

    /// A code block's header band: a control's height and the padding around it, then a rule.
    static let codeHeaderHeight = Theme.Control.target + 2 * Theme.Spacing.extraSmall
    /// Inside a code block, around its code.
    static let codePadding = Theme.Spacing.large
    /// Under a table, its controls' row.
    static let tableControlsHeight = Theme.Control.target
    static let quoteBarWidth: CGFloat = 3

    var ramp: TypeRamp { palette.style.ramp }

    init(palette: MessageTextPalette, links: WorkspaceFileLinks?) {
      self.palette = palette
      self.links = links
    }

    /// Where a block sits: its leading edge, the quotes around it and its text color.
    struct Context {
      var indent: CGFloat = 0
      var quotes: [MessageQuoteBar] = []
      var color: NSColor
    }

    /// A list item's marker and the column it ends in.
    struct Marker {
      var text: NSAttributedString
      var start: CGFloat
      /// The marker's trailing edge.
      var end: CGFloat
    }

    /// One paragraph to append: its text and how it is set.
    struct Paragraph {
      var content: NSAttributedString
      var lineHeight: CGFloat
      /// The font the line's glyph height comes from.
      var font: NSFont
      var indent: CGFloat
      var tailIndent: CGFloat = 0
      var before: CGFloat = 0
      var after: CGFloat = 0
      var tabs: [NSTextTab] = []
      var mark: MessageBlockMark?
      var lineBreak: NSLineBreakMode = .byWordWrapping
      var keepsDefaultTabs = false
      /// Its line's extra height goes under its glyphs, as SwiftUI sets text; a line with no
      /// text (a code block's header, a rule) takes it all as line height.
      var spacesUnderGlyphs = true
    }

    /// The document for `blocks`.
    mutating func document(_ blocks: [MarkdownBlock]) -> MessageTextDocument {
      append(blocks, in: Context(color: palette.text))
      // The last paragraph ends the text; an empty one keeps a space so it keeps its style.
      if output.string.hasSuffix("\n") {
        let last = NSRange(location: output.length - 1, length: 1)
        if output.length == 1 || output.string.hasSuffix("\n\n") {
          output.replaceCharacters(in: last, with: " ")
        } else {
          output.deleteCharacters(in: last)
        }
      }
      return MessageTextDocument(
        text: NSAttributedString(attributedString: output), palette: palette, chrome: chrome,
        hasWideBlocks: hasWideBlocks, topInset: topInset)
    }

    mutating func append(_ blocks: [MarkdownBlock], in context: Context) {
      for (index, block) in blocks.enumerated() {
        pendingGap += TypeRamp.spacing(above: block, after: index > 0 ? blocks[index - 1] : nil)
        append(block, in: context)
      }
    }

    private mutating func append(_ block: MarkdownBlock, in context: Context) {
      switch block {
      case .paragraph(let text):
        prose(text, level: nil, in: context)
      case .heading(let level, let text):
        prose(text, level: level, in: context)
      case .code(let language, let code):
        codeBlock(code, language: language, in: context)
      case .quote(let inner):
        var quoted = context
        lastBlock += 1
        quoted.quotes.append(MessageQuoteBar(id: lastBlock, leading: context.indent))
        quoted.indent += Self.quoteBarWidth + Theme.Spacing.medium
        quoted.color = palette.secondary
        append(inner, in: quoted)
      case .list(let ordered, let start, let items):
        list(ordered: ordered, start: start, items: items, in: context)
      case .table(let table):
        self.table(table, in: context)
      case .rule:
        rule(in: context)
      case .html(let raw):
        lines(
          raw, font: palette.style.code.font(size: ramp.code), color: palette.secondary,
          in: context)
      case .image(_, let alt):
        // An image in a list or quote; a message's own images are blocks beside its text.
        let label = alt.isEmpty ? "[Image]" : "[Image: \(alt)]"
        lines(label, font: palette.font(size: ramp.body), color: palette.secondary, in: context)
      case .math(let tex):
        // Display math in a list or quote, in its Unicode form.
        lines(
          MathText.unicode(tex), font: palette.math(size: ramp.body), color: context.color,
          in: context)
      }
    }

    /// A paragraph, or a heading at `level`.
    private mutating func prose(_ text: AttributedString, level: Int?, in context: Context) {
      guard let level else {
        let content = inline(text, size: ramp.body, codeSize: ramp.code, color: context.color)
        emit(
          Paragraph(
            content: content, lineHeight: ramp.bodyLineHeight, font: palette.font(size: ramp.body),
            indent: context.indent), in: context)
        return
      }
      let size = ramp.heading(level)
      let content = inline(
        text, size: size, weight: .semibold, codeSize: (size * TypeRamp.codeScale).rounded(.down),
        color: context.color)
      emit(
        Paragraph(
          content: content, lineHeight: ramp.headingLineHeight(level),
          font: palette.font(size: size, weight: .semibold), indent: context.indent),
        in: context)
    }

    /// A rule: a line of its own, which the layers draw across.
    private mutating func rule(in context: Context) {
      lastBlock += 1
      let font = palette.font(size: ramp.body)
      emit(
        Paragraph(
          content: space(font), lineHeight: 1 + 2 * Theme.Spacing.extraSmall, font: font,
          indent: context.indent,
          mark: MessageBlockMark(block: lastBlock, role: .rule, indent: context.indent),
          spacesUnderGlyphs: false),
        in: context)
    }

    /// `text` one paragraph per line, with no gap between its lines.
    private mutating func lines(
      _ text: String, font: NSFont, color: NSColor, in context: Context
    ) {
      for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let content = NSAttributedString(
          string: String(line), attributes: [.font: font, .foregroundColor: color])
        emit(
          Paragraph(
            content: content, lineHeight: ramp.bodyLineHeight, font: font, indent: context.indent),
          in: context)
      }
    }

    func space(_ font: NSFont) -> NSAttributedString {
      NSAttributedString(string: " ", attributes: [.font: font])
    }
  }

  // MARK: Paragraphs

  extension MessageTextBuilder {
    /// Appends `paragraph`, with the list marker waiting for it, if any.
    mutating func emit(_ paragraph: Paragraph, in context: Context) {
      let style = NSMutableParagraphStyle()
      // SwiftUI's exact line height puts a line's extra height under its glyphs. TextKit puts
      // a taller line's above them, so the extra is line spacing, which TextKit adds above
      // every line but the text's first: a paragraph's spacing before trades the extra above
      // its first line for the one under the paragraph before.
      let glyphs =
        paragraph.spacesUnderGlyphs
        ? Self.glyphHeight(paragraph.font, lineHeight: paragraph.lineHeight)
        : paragraph.lineHeight
      let extra = paragraph.lineHeight - glyphs
      style.minimumLineHeight = glyphs
      style.maximumLineHeight = glyphs
      style.lineSpacing = extra
      style.firstLineHeadIndent = paragraph.indent
      style.headIndent = paragraph.indent
      style.tailIndent = paragraph.tailIndent
      style.paragraphSpacingBefore = max(
        0, pendingGap + paragraph.before + (output.length == 0 ? 0 : previousExtra - extra))
      previousExtra = extra
      style.paragraphSpacing = paragraph.after
      style.lineBreakMode = paragraph.lineBreak
      if !paragraph.keepsDefaultTabs { style.tabStops = paragraph.tabs }
      pendingGap = 0
      // TextKit drops a first paragraph's spacing before; the view insets the text by it.
      if output.length == 0 {
        topInset = style.paragraphSpacingBefore
        style.paragraphSpacingBefore = 0
      }
      let content = NSMutableAttributedString()
      if let marker = pendingMarker {
        pendingMarker = nil
        let tab = NSAttributedString(string: "\t", attributes: [.font: paragraph.font])
        content.append(tab)
        content.append(marker.text)
        content.append(tab)
        style.firstLineHeadIndent = marker.start
        style.tabStops =
          [
            NSTextTab(textAlignment: .right, location: marker.end),
            NSTextTab(textAlignment: .left, location: paragraph.indent),
          ] + paragraph.tabs
      }
      content.append(paragraph.content)
      let start = output.length
      output.append(content)
      output.append(NSAttributedString(string: "\n", attributes: [.font: paragraph.font]))
      let range = NSRange(location: start, length: output.length - start)
      output.addAttribute(.paragraphStyle, value: style, range: range)
      if let mark = paragraph.mark { output.addAttribute(.messageBlock, value: mark, range: range) }
      if !context.quotes.isEmpty {
        output.addAttribute(.messageQuotes, value: MessageQuoteMarks(context.quotes), range: range)
      }
    }

    /// The height of a line's glyphs in `font`, at most `lineHeight`.
    static func glyphHeight(_ font: NSFont, lineHeight: CGFloat) -> CGFloat {
      min(lineHeight, (font.ascender - font.descender).rounded(.up))
    }

    /// `text` as AppKit attributes: emphasis, strong, strikethrough, inline code and math,
    /// and links (with workspace paths that exist linked).
    func inline(
      _ text: AttributedString, size: CGFloat, weight: NSFont.Weight = .regular,
      codeSize: CGFloat, color: NSColor
    ) -> NSAttributedString {
      let linked = links?.linking(text) ?? text
      let result = NSMutableAttributedString()
      for run in linked.runs {
        let intent = run.inlinePresentationIntent ?? []
        let strong = intent.contains(.stronglyEmphasized)
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        if run[MathSpanAttribute.self] != nil {
          attributes[.font] = palette.math(size: size)
        } else if intent.contains(.code) {
          attributes[.font] = palette.inlineCode(size: codeSize, strong: strong)
          attributes[.backgroundColor] = palette.inlineCodeBackground
        } else {
          attributes[.font] = palette.font(
            size: size, weight: strong ? .bold : weight, italic: intent.contains(.emphasized))
        }
        if intent.contains(.strikethrough) {
          attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let url = run.link { attributes[.link] = url }
        result.append(
          NSAttributedString(string: String(linked[run.range].characters), attributes: attributes))
      }
      return result
    }
  }
#endif
