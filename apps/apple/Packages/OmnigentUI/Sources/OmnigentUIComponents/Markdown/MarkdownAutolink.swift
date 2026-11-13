import SwiftUI

/// Web addresses written out in prose become links, as GitHub's Markdown makes them, and every
/// link is underlined so it reads as one beside tinted text.
nonisolated enum MarkdownAutolink {
  /// A web address written out in text, and where.
  struct Address {
    let range: Range<String.Index>
    let url: URL
  }

  /// Each `http` or `https` address written out in `text`, in order.
  static func addresses(in text: String) -> [Address] {
    guard text.contains("http") else { return [] }
    let address = /https?:\/\/[^\s<>]+/
    var found: [Address] = []
    var rest = text[...]
    while let match = rest.firstMatch(of: address) {
      let written = trimmed(match.output)
      if let url = MarkdownParser.safeURL(String(written)) {
        found.append(Address(range: written.startIndex..<written.endIndex, url: url))
      }
      rest = rest[written.endIndex...]
    }
    return found
  }

  /// `text` with each `http` or `https` address in it linked.
  static func linking(_ text: String) -> AttributedString {
    var result = AttributedString()
    var rest = text.startIndex
    for address in addresses(in: text) {
      result.append(AttributedString(String(text[rest..<address.range.lowerBound])))
      result.append(link(AttributedString(String(text[address.range])), to: address.url))
      rest = address.range.upperBound
    }
    result.append(AttributedString(String(text[rest...])))
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
