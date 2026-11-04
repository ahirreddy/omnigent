import Foundation

/// TeX math in agent markdown, as the web renders it: `$$…$$` and `\[…\]` on their own lines
/// are display math, `\(…\)` and `$$…$$` inside a line are inline math, and a single `$` stays
/// prose (currency, shell variables). Code is never touched.
///
/// Before parsing, ``delimited(_:)`` rewrites display math to a ```` ```math ```` fence and inline
/// math to inline code tagged with ``inlineMarker``, so the markdown parser keeps the TeX
/// verbatim. ``unicode(_:)`` then draws the TeX natively with Unicode symbols, superscripts
/// and subscripts; no web view is involved.
nonisolated enum MarkdownMath {
  /// Starts the inline code that holds inline math.
  static let inlineMarker: Character = "\u{E000}"

  /// `text` with its math rewritten for the parser, or `text` itself when it has none.
  static func delimited(_ text: String) -> String {
    guard mayContainMath(text) else { return text }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var output: [String] = []
    var fence: Substring?
    var index = 0
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.drop(while: { $0 == " " })
      if let marker = fenceMarker(trimmed) {
        if fence == nil {
          fence = marker
        } else if let open = fence, marker.first == open.first, marker.count >= open.count {
          fence = nil
        }
      }
      if fence != nil || fenceMarker(trimmed) != nil {
        output.append(String(line))
        index += 1
        continue
      }
      if trimmed.first == "$" || trimmed.first == "\\",
        let (tex, end) = displayMath(lines, from: index)
      {
        let indent = String(line.prefix(while: { $0 == " " }))
        output.append(indent + "```math")
        output += tex.split(separator: "\n", omittingEmptySubsequences: false).map {
          indent + $0
        }
        output.append(indent + "```")
        index = end + 1
        continue
      }
      output.append(mayContainMath(line) ? inlineMath(String(line)) : String(line))
      index += 1
    }
    return output.joined(separator: "\n")
  }

  /// The TeX of inline code that ``delimited(_:)`` made from inline math.
  static func inlineSource(_ code: String) -> String? {
    guard code.first == inlineMarker else { return nil }
    return String(code.dropFirst())
  }

  private static func mayContainMath(_ text: some StringProtocol) -> Bool {
    var previous: UInt8 = 0
    for byte in text.utf8 {
      if previous == UInt8(ascii: "$"), byte == UInt8(ascii: "$") { return true }
      if previous == UInt8(ascii: "\\"), byte == UInt8(ascii: "(") || byte == UInt8(ascii: "[") {
        return true
      }
      previous = byte
    }
    return false
  }

  private static func fenceMarker(_ line: Substring) -> Substring? {
    guard let first = line.first, first == "`" || first == "~" else { return nil }
    let marker = line.prefix(while: { $0 == first })
    return marker.count >= 3 ? marker : nil
  }

  /// Display math starting on line `start`: the TeX and the line it closes on.
  private static func displayMath(_ lines: [Substring], from start: Int) -> (String, Int)? {
    let first = lines[start].trimmingCharacters(in: .whitespaces)
    let (open, close) =
      first.hasPrefix("$$") ? ("$$", "$$") : first.hasPrefix("\\[") ? ("\\[", "\\]") : ("", "")
    guard !open.isEmpty else { return nil }
    let rest = first.dropFirst(open.count)
    if rest.count >= close.count, rest.hasSuffix(close), !rest.dropLast(close.count).isEmpty {
      // `$$x$$` alone on its line.
      let tex = rest.dropLast(close.count)
      return tex.contains(close) ? nil : (tex.trimmingCharacters(in: .whitespaces), start)
    }
    guard rest.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    var body: [String] = []
    for index in lines.indices.dropFirst(start + 1) {
      let line = lines[index].trimmingCharacters(in: .whitespaces)
      if line.hasSuffix(close) {
        body.append(String(line.dropLast(close.count)))
        return (body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), index)
      }
      if line.isEmpty { return nil }
      body.append(line)
    }
    return nil
  }

  /// `line` with `\(…\)`, `\[…\]` and `$$…$$` turned into tagged inline code, outside inline
  /// code.
  private static func inlineMath(_ line: String) -> String {
    let characters = Array(line)
    var output = ""
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "`" {
        // Copy an inline code span whole.
        let run = characters[index...].prefix(while: { $0 == "`" }).count
        let closing = codeSpanEnd(characters, from: index + run, run: run)
        output += String(characters[index..<closing])
        index = closing
        continue
      }
      if character == "\\", index + 1 < characters.count {
        let next = characters[index + 1]
        let closer: Character? = next == "(" ? ")" : next == "[" ? "]" : nil
        if let closer, let end = find(["\\", closer], in: characters, from: index + 2) {
          output += code(String(characters[index + 2..<end]))
          index = end + 2
          continue
        }
        output += String([character, next])
        index += 2
        continue
      }
      if character == "$", index + 1 < characters.count, characters[index + 1] == "$",
        let end = find(["$", "$"], in: characters, from: index + 2), end > index + 2
      {
        output += code(String(characters[index + 2..<end]))
        index = end + 2
        continue
      }
      output.append(character)
      index += 1
    }
    return output
  }

  private static func codeSpanEnd(_ characters: [Character], from start: Int, run: Int) -> Int {
    var index = start
    while index < characters.count {
      guard characters[index] == "`" else {
        index += 1
        continue
      }
      let length = characters[index...].prefix(while: { $0 == "`" }).count
      if length == run { return index + length }
      index += length
    }
    return characters.count
  }

  private static func find(_ pair: [Character], in characters: [Character], from start: Int)
    -> Int?
  {
    var index = start
    while index + 1 < characters.count {
      if characters[index] == pair[0], characters[index + 1] == pair[1] { return index }
      index += 1
    }
    return nil
  }

  /// Inline code holding `tex`, fenced with more backticks than it contains.
  private static func code(_ tex: String) -> String {
    var longest = 0
    var current = 0
    for character in tex {
      current = character == "`" ? current + 1 : 0
      longest = max(longest, current)
    }
    let fence = String(repeating: "`", count: longest + 1)
    let padding = tex.hasSuffix("`") ? " " : ""
    return fence + String(inlineMarker) + tex.trimmingCharacters(in: .whitespaces) + padding
      + fence
  }
}
