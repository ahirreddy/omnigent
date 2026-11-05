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
    if let old = string(dictionary, oldKeys), let new = string(dictionary, newKeys) {
      guard old != new else { return [] }
      let body = pairLines(old: old, new: new).joined(separator: "\n")
      // Without a path, a hunk marker still marks the text as a diff.
      return [path == nil ? "@@ edit @@\n" + body : headed(body, path: path)]
    }
    return dictionary.keys.sorted().flatMap { key in
      dictionary[key].map { diffTexts(in: $0, path: path) } ?? []
    }
  }

  /// Each harness's key for an edit's old and new text (Claude, Pi, OpenCode).
  private static let oldKeys = ["old_string", "oldText", "oldString"]
  private static let newKeys = ["new_string", "newText", "newString"]
  /// Unchanged lines kept around a change, as the web's edit diff.
  private static let contextLines = 2

  private static func string(_ dictionary: [String: Any], _ keys: [String]) -> String? {
    keys.lazy.compactMap { dictionary[$0] as? String }.first
  }

  /// One replacement as diff lines: lines both sides share at the start and end are context
  /// (the nearest few kept), the rest removed then added.
  static func pairLines(old: String, new: String) -> [String] {
    let before = old.isEmpty ? [] : old.components(separatedBy: "\n")
    let after = new.isEmpty ? [] : new.components(separatedBy: "\n")
    var prefix = 0
    while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < min(before.count, after.count) - prefix,
      before[before.count - 1 - suffix] == after[after.count - 1 - suffix]
    {
      suffix += 1
    }
    let leading = before[max(0, prefix - contextLines)..<prefix].map { " " + $0 }
    let removed = before[prefix..<(before.count - suffix)].map { "-" + $0 }
    let added = after[prefix..<(after.count - suffix)].map { "+" + $0 }
    let trailingEnd = min(before.count, before.count - suffix + contextLines)
    let trailing = before[(before.count - suffix)..<trailingEnd].map { " " + $0 }
    return leading + removed + added + trailing
  }

  private static func headed(_ text: String, path: String?) -> String {
    guard let path else { return text }
    return "--- a/\(path)\n+++ b/\(path)\n" + text
  }
}

/// A gated tool's input on an approval card: its edits as a tinted diff, or its JSON with
/// strings unescaped. Long input starts folded to a few lines, with Show all. On a phone the
/// code is 13 pt and wraps; the full-screen review unfolds it and can scroll lines instead.
struct PreviewBlock: View {
  let text: String
  @State private var isExpanded = false
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.decisionCodeLayout) private var codeLayout

  private var foldedLines: Int { layoutWidth == .compact ? DecisionPayloadSize.compactLines : 12 }
  private var showsAll: Bool { isExpanded || codeLayout.isFullScreen }
  private var wraps: Bool { codeLayout.wraps(layoutWidth) }

  var body: some View {
    if let diff = ToolInputPreview.diff(in: text) {
      DiffView(
        diff: diff, maxLines: showsAll ? 400 : foldedLines,
        showAll: showsAll ? nil : { isExpanded = true }, codeFont: DecisionCode.font(layoutWidth),
        wrapsLines: wraps)
    } else {
      plain(ToolInputPreview.unescaped(text))
    }
  }

  private func plain(_ text: String) -> some View {
    let lines = text.components(separatedBy: "\n")
    let isFolded = !showsAll && lines.count > foldedLines
    let shown = isFolded ? lines.prefix(foldedLines).joined(separator: "\n") : text
    return VStack(alignment: .leading, spacing: 0) {
      BoundedScrollView(maxHeight: isExpanded && !codeLayout.isFullScreen ? 480 : .infinity) {
        // Plain input always wrapped inline; only the review can switch it to scrolling.
        if wraps || !codeLayout.isFullScreen {
          code(shown).frame(maxWidth: .infinity, alignment: .leading)
        } else {
          ScrollView(.horizontal) { code(shown).fixedSize(horizontal: true, vertical: false) }
        }
      }
      if isFolded {
        ShowAllButton(hidden: lines.count - foldedLines) { isExpanded = true }
      }
    }
    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
  }

  private func code(_ text: String) -> some View {
    Text(verbatim: text)
      .font(DecisionCode.font(layoutWidth))
      .textSelection(.enabled)
      .padding(Theme.Spacing.medium)
  }
}

/// How a payload diff lays out: wrapped on a phone and scrolling elsewhere, unless the
/// full-screen review says otherwise.
enum DecisionCodeLayout: Hashable {
  /// Inline: wrap on a phone, scroll elsewhere.
  case automatic
  /// The full-screen review, wrapping or not.
  case fullScreen(wraps: Bool)

  var isFullScreen: Bool {
    if case .fullScreen = self { return true }
    return false
  }

  func wraps(_ width: LayoutWidth) -> Bool {
    switch self {
    case .automatic: width == .compact
    case .fullScreen(let wraps): wraps
    }
  }
}

extension EnvironmentValues {
  @Entry var decisionCodeLayout = DecisionCodeLayout.automatic
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
