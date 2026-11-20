import Foundation

/// A design-tool message read back from the `[Design Mode — …]` block the web's Browser tools
/// (design mode, Annotate, Draw) append, so the transcript shows it as a compact card instead
/// of raw Markdown. What the agent received is unchanged.
nonisolated struct DesignRequest: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    /// A picked element and what should change about it.
    case element
    /// A marked-up screenshot of the page and a note.
    case drawing
  }

  var kind: Kind
  /// What the user typed.
  var request: String
  /// The picked element, as `p#blurb`; element requests only.
  var element: String?
  /// The component the picker named, as `CheckoutButton`; element requests only.
  var component: String?
  /// The element's text; element requests only.
  var elementText: String?
  /// The element's accessible label and role; element requests only.
  var ariaLabel: String?
  var role: String?
  /// The page's host, as `localhost:5173`.
  var page: String?
  /// The block says no screenshot was attached; element requests only.
  var noScreenshot = false

  /// A card's note when the agent got the request without its screenshot.
  static let noScreenshotNote = "Sent without a screenshot (it couldn't be taken)."

  private static let opening = "\n\n---\n[Design Mode \u{2014} "
  private static let closing = "\n---"
  private static let elementHeader = "modify this element in the browser preview"
  private static let drawingHeader = "marked-up screenshot of the browser preview"

  /// The request `text` carries, or `nil` for an ordinary message. Only the block a tool
  /// appends at the very end counts, so one the user quoted above stays words.
  static func parse(_ text: String) -> Self? {
    let message = text.trimmingSuffix(while: \.isWhitespace)
    guard message.hasSuffix(closing),
      let start = message.range(of: opening, options: .backwards)
    else { return nil }
    let blockEnd = message.index(message.endIndex, offsetBy: -closing.count)
    guard start.upperBound <= blockEnd else { return nil }
    let block = message[start.upperBound..<blockEnd]
    guard let headerEnd = block.range(of: "]\n") else { return nil }
    let header = block[..<headerEnd.lowerBound]
    let lines = block[headerEnd.upperBound...].split(
      separator: "\n", omittingEmptySubsequences: false)
    let request = message[..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    switch header {
    case elementHeader: return elementRequest(request, Fields(lines: lines))
    case drawingHeader: return drawingRequest(request, Fields(lines: lines))
    default: return nil
    }
  }

  /// What the request was about, as one line: the element and its text, or the page.
  var subject: String {
    guard kind == .element else { return page.map { "Drawing on \($0)" } ?? "Drawing" }
    var parts = [component.map { "<\($0)>" }, element ?? "element"].compactMap(\.self)
    if let elementText { parts.append("\"\(elementText)\"") }
    // An icon-only control is told apart by its accessible name.
    if let ariaLabel, ariaLabel != elementText { parts.append("aria-label \"\(ariaLabel)\"") }
    if let role { parts.append("role \(role)") }
    if let page { parts.append("on \(page)") }
    return parts.joined(separator: " ")
  }

  /// The request as a collapsed prompt shows it: at most `limit` characters of its words and
  /// element text in all, so the card's size is bounded however much the message carries.
  func clipped(to limit: Int) -> Self {
    var clipped = self
    clipped.request = String(request.prefix(limit))
    let left = max(limit - clipped.request.count, 0)
    guard let elementText, elementText.count > left else { return clipped }
    // A cut text ends in "…"; a label matching the whole text stays hidden, as unclipped.
    clipped.elementText = String(elementText.prefix(max(left - 1, 0))) + "\u{2026}"
    if ariaLabel == elementText { clipped.ariaLabel = nil }
    return clipped
  }

  /// A block's `Name: value` lines.
  private struct Fields {
    let lines: [Substring]

    subscript(_ name: String) -> String? {
      let prefix = "\(name): "
      return lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
  }

  private static func elementRequest(_ request: String, _ fields: Fields) -> Self? {
    guard let selector = fields["CSS selector"], let name = fields["Element"] else { return nil }
    // `<element>` is the prompt's stand-in for an element whose tag wasn't known.
    let bare = name == "<element>" ? "" : name.replacing(/^<|>$/, with: "")
    // An HTML tag as the picker reports it (lowercase); anything else is a component's name.
    let tag = bare.wholeMatch(of: /[a-z][a-z0-9-]*/) != nil ? bare : ""
    // `p` and `#blurb` read as `p#blurb`; a component's name stays apart from the selector.
    let element = !selector.isEmpty && !selector.hasPrefix(tag) ? tag + selector : selector
    var parsed = Self(kind: .element, request: request)
    parsed.element = (element.isEmpty ? tag : element).nonEmpty
    parsed.component = tag.isEmpty ? bare.nonEmpty : nil
    parsed.elementText = unquoted(fields["Text"])
    parsed.ariaLabel = unquoted(fields["Aria-label"])
    parsed.role = fields["Role"]?.nonEmpty
    parsed.page = shownPage(fields["Page"])
    parsed.noScreenshot = fields["Screenshot"]?.hasPrefix("none") ?? false
    return parsed
  }

  private static func drawingRequest(_ request: String, _ fields: Fields) -> Self? {
    guard let page = fields["Page"] else { return nil }
    var parsed = Self(kind: .drawing, request: request)
    parsed.page = shownPage(page)
    return parsed
  }

  private static func unquoted(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    guard value.count > 1, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
    return String(value.dropFirst().dropLast())
  }

  /// A block's `Page` as a card shows it: its host only, whatever an older message saved.
  private static func shownPage(_ page: String?) -> String? {
    guard let page, let url = URL(string: page), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty
    else { return nil }
    return url.port.map { "\(host):\($0)" } ?? host
  }
}

nonisolated extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }

  fileprivate func trimmingSuffix(while drops: (Character) -> Bool) -> String {
    var end = endIndex
    while end > startIndex, drops(self[index(before: end)]) { end = index(before: end) }
    return String(self[..<end])
  }
}
