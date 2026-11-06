public import Foundation

// Text views count in UTF-16 offsets, as `NSString` does.
// swiftlint:disable legacy_objc_type

/// A formatting action of the Markdown editor's toolbar, as the web's `MarkdownEditorToolbar`.
nonisolated public enum MarkdownFormat: String, CaseIterable, Identifiable, Sendable {
  /// `**bold**`.
  case bold
  /// `*italic*`.
  case italic
  /// `~~strikethrough~~`.
  case strikethrough
  /// `` `inline code` ``.
  case code
  /// `[text](https://)`.
  case link
  /// Plain text: drops heading, quote and list markers.
  case paragraph
  /// `# Heading 1`.
  case heading1
  /// `## Heading 2`.
  case heading2
  /// `### Heading 3`.
  case heading3
  /// `> Quote`.
  case quote
  /// `- Bullet`.
  case bulletList
  /// `1. Numbered`.
  case numberedList
  /// `- [ ] Task`.
  case taskList

  /// The raw value.
  public var id: String { rawValue }

  /// The toolbar's label, as the web's button titles.
  public var title: String {
    switch self {
    case .bold: "Bold"
    case .italic: "Italic"
    case .strikethrough: "Strikethrough"
    case .code: "Inline code"
    case .link: "Link"
    case .paragraph: "Normal"
    case .heading1: "Heading 1"
    case .heading2: "Heading 2"
    case .heading3: "Heading 3"
    case .quote: "Quote"
    case .bulletList: "Bullet list"
    case .numberedList: "Numbered list"
    case .taskList: "Task list"
    }
  }

  /// The toolbar's symbol.
  public var systemImage: String {
    switch self {
    case .bold: "bold"
    case .italic: "italic"
    case .strikethrough: "strikethrough"
    case .code: "chevron.left.forwardslash.chevron.right"
    case .link: "link"
    case .paragraph: "paragraphsign"
    case .heading1: "1.square"
    case .heading2: "2.square"
    case .heading3: "3.square"
    case .quote: "text.quote"
    case .bulletList: "list.bullet"
    case .numberedList: "list.number"
    case .taskList: "checklist"
    }
  }

  /// The marker that wraps a selection, for inline formats.
  var wrapper: String? {
    switch self {
    case .bold: "**"
    case .italic: "*"
    case .strikethrough: "~~"
    case .code: "`"
    default: nil
    }
  }

  /// The marker that starts each line, for block formats (`nil` for Normal and inline ones).
  var linePrefix: String? {
    switch self {
    case .heading1: "# "
    case .heading2: "## "
    case .heading3: "### "
    case .quote: "> "
    case .bulletList: "- "
    case .taskList: "- [ ] "
    case .numberedList: "1. "
    default: nil
    }
  }
}

/// One replacement in a text and the selection after it, in UTF-16 offsets as text views count.
nonisolated public struct TextReplacement: Hashable, Sendable {
  /// The replaced range.
  public var range: NSRange
  /// The new text.
  public var text: String
  /// The selection afterwards.
  public var selection: NSRange
}

/// Applies Markdown formats to the source text: inline formats wrap or unwrap the selection,
/// block formats toggle a marker on each selected line.
nonisolated public enum MarkdownFormatting {
  // swiftlint:disable large_tuple
  /// Matches a line's block marker after its indentation: a heading, quote, task, bullet or
  /// number.
  private static var blockMarker: Regex<(Substring, Substring, Substring)> {
    /^(\s*)(#{1,6}\s+|>\s?|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+)/
  }
  // swiftlint:enable large_tuple

  /// The replacement that applies `format` to `selection` of `text`.
  /// - Parameters:
  ///   - format: The format.
  ///   - text: The source.
  ///   - selection: The selected range (empty for the caret).
  /// - Returns: The replacement.
  public static func apply(_ format: MarkdownFormat, to text: String, selection: NSRange)
    -> TextReplacement
  {
    let source = text as NSString
    let location = min(max(selection.location, 0), source.length)
    let selection = NSRange(
      location: location, length: min(max(selection.length, 0), source.length - location))
    if let marker = format.wrapper { return wrap(source, selection, marker) }
    if format == .link { return link(source, selection) }
    return lines(source, selection, format)
  }

  private static func wrap(_ text: NSString, _ selection: NSRange, _ marker: String)
    -> TextReplacement
  {
    let width = (marker as NSString).length
    let selected = text.substring(with: selection)
    let before = NSRange(location: selection.location - width, length: width)
    let after = NSRange(location: NSMaxRange(selection), length: width)
    if before.location >= 0, NSMaxRange(after) <= text.length,
      text.substring(with: before) == marker, text.substring(with: after) == marker
    {
      return TextReplacement(
        range: NSUnionRange(before, after), text: selected,
        selection: NSRange(location: before.location, length: selection.length))
    }
    if selection.length >= 2 * width, selected.hasPrefix(marker), selected.hasSuffix(marker) {
      let inner = (selected as NSString).substring(
        with: NSRange(location: width, length: selection.length - 2 * width))
      return TextReplacement(
        range: selection, text: inner,
        selection: NSRange(location: selection.location, length: selection.length - 2 * width))
    }
    return TextReplacement(
      range: selection, text: marker + selected + marker,
      selection: NSRange(location: selection.location + width, length: selection.length))
  }

  private static func link(_ text: NSString, _ selection: NSRange) -> TextReplacement {
    let label = text.substring(with: selection)
    let url = "https://"
    let replacement = "[\(label)](\(url))"
    let selected =
      label.isEmpty
      ? NSRange(location: selection.location + 1, length: 0)
      : NSRange(
        location: selection.location + (label as NSString).length + 3,
        length: (url as NSString).length)
    return TextReplacement(range: selection, text: replacement, selection: selected)
  }

  private static func lines(_ text: NSString, _ selection: NSRange, _ format: MarkdownFormat)
    -> TextReplacement
  {
    // A selection that ends at the start of a line leaves that line alone.
    var covered = selection
    if covered.length > 0, text.character(at: NSMaxRange(covered) - 1) == 0x0A {
      covered.length -= 1
    }
    var block = text.lineRange(for: covered)
    if block.length > 0, text.character(at: NSMaxRange(block) - 1) == 0x0A { block.length -= 1 }
    let lines = text.substring(with: block).components(separatedBy: "\n")
    let stripped = lines.map(strip)
    let nonEmpty = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
    let alreadyFormatted =
      !nonEmpty.isEmpty
      && nonEmpty.allSatisfy { has(format, lines[$0]) }
    var number = 0
    let rewritten = lines.indices.map { index -> String in
      let (indent, body) = stripped[index]
      guard let prefix = format.linePrefix, !alreadyFormatted,
        nonEmpty.contains(index) || lines.count == 1
      else { return indent + body }
      number += 1
      return indent + (format == .numberedList ? "\(number). " : prefix) + body
    }
    let replacement = rewritten.joined(separator: "\n")
    let newLength = (replacement as NSString).length
    if selection.length == 0, lines.count == 1 {
      // Keep the caret on the same character of the line's text.
      let shift = newLength - block.length
      let caret = max(block.location, min(selection.location + shift, block.location + newLength))
      return TextReplacement(
        range: block, text: replacement, selection: NSRange(location: caret, length: 0))
    }
    return TextReplacement(
      range: block, text: replacement,
      selection: NSRange(location: block.location, length: newLength))
  }

  /// A line's indentation and its text without a block marker.
  private static func strip(_ line: String) -> (String, String) {
    guard let match = line.prefixMatch(of: blockMarker) else {
      let indent = line.prefix { $0 == " " || $0 == "\t" }
      return (String(indent), String(line.dropFirst(indent.count)))
    }
    return (String(match.output.1), String(line[match.range.upperBound...]))
  }

  /// Whether `line` already carries `format`'s marker.
  private static func has(_ format: MarkdownFormat, _ line: String) -> Bool {
    let body = line.drop { $0 == " " || $0 == "\t" }
    switch format {
    case .numberedList:
      return body.prefixMatch(of: /\d+[.)]\s+/) != nil
    case .bulletList:
      return body.prefixMatch(of: /[-*+]\s+/) != nil && body.prefixMatch(of: /[-*+]\s+\[/) == nil
    case .taskList:
      return body.prefixMatch(of: /[-*+]\s+\[[ xX]\]\s+/) != nil
    default:
      guard let prefix = format.linePrefix else { return false }
      return body.hasPrefix(prefix) && !body.dropFirst(prefix.count).hasPrefix("#")
    }
  }
}
// swiftlint:enable legacy_objc_type
