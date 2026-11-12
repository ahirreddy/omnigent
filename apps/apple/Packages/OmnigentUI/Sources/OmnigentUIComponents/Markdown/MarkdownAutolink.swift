import SwiftUI

/// Web addresses written out in prose become links, as GitHub's Markdown makes them, and every
/// link is underlined so it reads as one beside tinted text.
nonisolated enum MarkdownAutolink {
  /// `text` with each `http` or `https` address in it linked.
  static func linking(_ text: String) -> AttributedString {
    guard text.contains("http") else { return AttributedString(text) }
    let address = /https?:\/\/[^\s<>]+/
    var result = AttributedString()
    var rest = text[...]
    while let match = rest.firstMatch(of: address) {
      let written = trimmed(match.output)
      result.append(AttributedString(String(rest[..<written.startIndex])))
      var span = AttributedString(String(written))
      if let url = MarkdownParser.safeURL(String(written)) { span = link(span, to: url) }
      result.append(span)
      rest = rest[written.endIndex...]
    }
    result.append(AttributedString(String(rest)))
    return result
  }

  /// `text` as a link to `url`, underlined.
  static func link(_ text: AttributedString, to url: URL) -> AttributedString {
    var text = text
    text.link = url
    text.underlineStyle = .single
    return text
  }

  /// `address` without the sentence punctuation and unmatched closing brackets that follow it.
  static func trimmed(_ address: Substring) -> Substring {
    var address = address
    while let last = address.last {
      let closesNothing =
        (last == ")" && count("(", in: address) < count(")", in: address))
        || (last == "]" && count("[", in: address) < count("]", in: address))
      guard ".,;:!?'\"*_".contains(last) || closesNothing else { break }
      address = address.dropLast()
    }
    return address
  }

  private static func count(_ character: Character, in text: Substring) -> Int {
    text.count { $0 == character }
  }
}
