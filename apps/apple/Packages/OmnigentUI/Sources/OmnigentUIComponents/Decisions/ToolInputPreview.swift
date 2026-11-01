import Foundation
import SwiftUI

/// Reads the core's tool-input preview (`name({...})`, pretty JSON with escaped strings): the
/// edits it carries as one unified diff, or the JSON with its strings unescaped.
nonisolated enum ToolInputPreview {
  /// The diff the input carries: `apply_patch` changes and patches, unified diffs in any string
  /// value, and `Edit`/`MultiEdit` `old_string`/`new_string` pairs. `nil` when there is none.
  static func diff(in preview: String) -> DiffSummary? {
    guard let object = json(in: preview) else { return DiffSummary.parse(preview) }
    let texts = diffTexts(in: object, path: nil)
    guard !texts.isEmpty else { return nil }
    return DiffSummary.parse(texts.joined(separator: "\n"))
  }

  /// The preview with JSON string escapes (`\n`, `\t`, `\"`, `\\`, `\uXXXX`) turned into the
  /// characters they stand for. Structure, order and indentation are kept.
  static func unescaped(_ preview: String) -> String {
    var output = ""
    var inString = false
    var characters = preview.makeIterator()
    while let character = characters.next() {
      guard inString else {
        if character == "\"" { inString = true }
        output.append(character)
        continue
      }
      switch character {
      case "\"":
        inString = false
        output.append(character)
      case "\\":
        guard let escaped = characters.next() else {
          output.append(character)
          break
        }
        output.append(contentsOf: unescape(escaped, rest: &characters))
      default:
        output.append(character)
      }
    }
    return output
  }

  private static func unescape(_ escaped: Character, rest: inout String.Iterator) -> String {
    switch escaped {
    case "n": return "\n"
    case "t": return "\t"
    case "r": return ""
    case "u":
      let digits = String((0..<4).compactMap { _ in rest.next() })
      guard digits.count == 4, let value = UInt32(digits, radix: 16),
        let scalar = Unicode.Scalar(value)
      else { return "\\u" + digits }
      return String(Character(scalar))
    default: return String(escaped)
    }
  }

  /// The JSON value of a `{...}` or `name({...})` preview, or `nil` when it is not JSON.
  private static func json(in preview: String) -> Any? {
    var body = Substring(preview.trimmingCharacters(in: .whitespacesAndNewlines))
    if let open = body.firstIndex(of: "("), body.first != "{", body.first != "[" {
      body = body[body.index(after: open)...]
      if body.last == ")" { body = body.dropLast() }
    }
    guard body.first == "{" || body.first == "[", let data = String(body).data(using: .utf8)
    else { return nil }
    do {
      return try JSONSerialization.jsonObject(with: data)
    } catch {
      // A truncated or non-JSON preview: shown as text, unescaped.
      return nil
    }
  }

  private static let pathKeys = ["path", "file_path", "filePath", "file", "filename"]

  /// Unified diff texts found in `value`, each with file headers when the path is known.
  private static func diffTexts(in value: Any, path: String?) -> [String] {
    if let array = value as? [Any] {
      return array.flatMap { diffTexts(in: $0, path: path) }
    }
    guard let dictionary = value as? [String: Any] else {
      guard let text = value as? String, let diff = DiffSummary.parse(text) else { return [] }
      return [diff.files.isEmpty ? headed(text, path: path) : text]
    }
    let path = pathKeys.lazy.compactMap { dictionary[$0] as? String }.first ?? path
    if let old = dictionary["old_string"] as? String, let new = dictionary["new_string"] as? String
    {
      let removed = old.isEmpty ? [] : old.components(separatedBy: "\n").map { "-" + $0 }
      let added = new.isEmpty ? [] : new.components(separatedBy: "\n").map { "+" + $0 }
      return [headed((removed + added).joined(separator: "\n"), path: path)]
    }
    return dictionary.keys.sorted().flatMap { key in
      dictionary[key].map { diffTexts(in: $0, path: path) } ?? []
    }
  }

  private static func headed(_ text: String, path: String?) -> String {
    guard let path else { return text }
    return "--- a/\(path)\n+++ b/\(path)\n" + text
  }
}

/// A gated tool's input on an approval card: its edits as a tinted diff, or its JSON with
/// strings unescaped. Long input starts folded to a few lines, with Show all.
struct PreviewBlock: View {
  let text: String
  @State private var isExpanded = false
  @Environment(\.layoutWidth) private var layoutWidth

  private var foldedLines: Int { layoutWidth == .compact ? 6 : 12 }

  var body: some View {
    if let diff = ToolInputPreview.diff(in: text) {
      DiffView(
        diff: diff, maxLines: isExpanded ? 400 : foldedLines,
        showAll: isExpanded ? nil : { isExpanded = true })
    } else {
      plain(ToolInputPreview.unescaped(text))
    }
  }

  private func plain(_ text: String) -> some View {
    let lines = text.components(separatedBy: "\n")
    let isFolded = !isExpanded && lines.count > foldedLines
    return VStack(alignment: .leading, spacing: 0) {
      BoundedScrollView(maxHeight: isExpanded ? 480 : .infinity) {
        Text(verbatim: isFolded ? lines.prefix(foldedLines).joined(separator: "\n") : text)
          .font(Theme.codeFont)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(Theme.Spacing.medium)
      }
      if isFolded {
        ShowAllButton(hidden: lines.count - foldedLines) { isExpanded = true }
      }
    }
    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
  }
}

/// "Show all" under a folded preview, naming how many lines are hidden.
struct ShowAllButton: View {
  let hidden: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text("Show all \u{00B7} \(hidden) more \(hidden == 1 ? "line" : "lines")")
        .font(.caption)
    }
    .buttonStyle(.borderless)
    .tint(.secondary)
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.bottom, Theme.Spacing.small)
    .accessibilityIdentifier("preview-show-all")
  }
}
