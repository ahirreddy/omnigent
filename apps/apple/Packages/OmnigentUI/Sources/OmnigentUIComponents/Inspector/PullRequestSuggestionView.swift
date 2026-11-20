import SwiftUI

/// A review comment's body in parts: Markdown, and the ```` ```suggestion ```` blocks that
/// replace the lines the conversation is on.
nonisolated enum PullRequestReviewBodyPart: Hashable, Sendable {
  /// Markdown between suggestions.
  case markdown(String)
  /// A suggested replacement, without its fence.
  case suggestion(String)

  /// An open code fence: its character, its length, and whether it holds a suggestion.
  private struct Fence {
    let fence: Character
    let length: Int
    let suggestion: Bool
  }

  /// `body` split at its top-level suggestion fences (backticks or tildes, up to three spaces
  /// in); other fenced code, suggestions inside it included, stays Markdown.
  static func split(_ body: String) -> [Self] {
    var parts: [Self] = []
    var markdown: [Substring] = []
    var open: Fence?
    var replacement: [Substring] = []
    func flushMarkdown() {
      let text = markdown.joined(separator: "\n")
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        parts.append(.markdown(text))
      }
      markdown = []
    }
    for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
      if let fence = open {
        if closes(line, fence: fence.fence, length: fence.length) {
          open = nil
          if fence.suggestion {
            parts.append(.suggestion(replacement.joined(separator: "\n")))
            replacement = []
          } else {
            markdown.append(raw)
          }
        } else if fence.suggestion {
          replacement.append(line)
        } else {
          markdown.append(raw)
        }
        continue
      }
      guard let opening = opens(line) else {
        markdown.append(raw)
        continue
      }
      open = opening
      if opening.suggestion { flushMarkdown() } else { markdown.append(raw) }
    }
    // An unclosed fence runs to the end, as Markdown has it.
    if open?.suggestion == true { parts.append(.suggestion(replacement.joined(separator: "\n"))) }
    flushMarkdown()
    return parts
  }

  private static func opens(_ line: Substring) -> Fence? {
    let indent = line.prefix { $0 == " " }.count
    guard indent <= 3 else { return nil }
    let rest = line.dropFirst(indent)
    guard let fence = rest.first, fence == "`" || fence == "~" else { return nil }
    let length = rest.prefix { $0 == fence }.count
    guard length >= 3 else { return nil }
    let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
    if fence == "`", info.contains("`") { return nil }
    let language = info.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    return Fence(fence: fence, length: length, suggestion: language == "suggestion")
  }

  private static func closes(_ line: Substring, fence: Character, length: Int) -> Bool {
    let indent = line.prefix { $0 == " " }.count
    guard indent <= 3 else { return false }
    let rest = line.dropFirst(indent)
    let run = rest.prefix { $0 == fence }.count
    return run >= length && rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
  }
}

/// The lines a suggestion replaces: the range shown in the diff, or the comment's own snippet
/// once the code moved on.
nonisolated public struct PullRequestSuggestionSource: Hashable, Sendable {
  /// The first line's number.
  public var line: UInt64
  /// The lines, without newlines.
  public var lines: [String]
  /// From the snippet the comment was written on, not the revision shown.
  public var original: Bool

  /// Creates a source.
  /// - Parameters:
  ///   - line: First line number.
  ///   - lines: The lines.
  ///   - original: From the comment's snippet.
  public init(line: UInt64, lines: [String], original: Bool) {
    self.line = line
    self.lines = lines
    self.original = original
  }
}

/// A suggested change drawn as the lines it removes over the ones it adds, as the web's
/// `ReviewSuggestion`; without the original lines, the replacement alone.
struct PullRequestSuggestionView: View {
  let source: PullRequestSuggestionSource?
  let replacement: String

  private var added: [String] {
    replacement.isEmpty ? [] : replacement.components(separatedBy: "\n")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Spacing.small) {
        Text("Suggested change")
        if source?.original == true {
          Text("Original context").font(.caption2)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, Theme.Spacing.small)
      .padding(.vertical, Theme.Spacing.extraSmall)
      Divider()
      if let source {
        ScrollView([.horizontal, .vertical]) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(source.lines.enumerated()), id: \.offset) { index, line in
              row("-", line, number: source.line + UInt64(index), color: .prRed)
            }
            ForEach(Array(added.enumerated()), id: \.offset) { index, line in
              row("+", line, number: source.line + UInt64(index), color: .prGreen)
            }
          }
          .padding(.vertical, Theme.Spacing.tiny)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("Original lines are unavailable for comparison.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, Theme.Spacing.small)
          .padding(.top, Theme.Spacing.extraSmall)
        Text(replacement.isEmpty ? "(Empty replacement)" : replacement)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .padding(Theme.Spacing.small)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(cornerRadius: Theme.Radius.small)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Suggested change")
  }

  private func row(_ sign: String, _ text: String, number: UInt64, color: ThemeColor)
    -> some View
  {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
      Text(String(number))
        .foregroundStyle(.secondary)
        .frame(minWidth: 28, alignment: .trailing)
      Text(sign).foregroundStyle(color)
      Text(text.isEmpty ? " " : text).textSelection(.enabled)
    }
    .font(.caption.monospaced())
    .fixedSize(horizontal: true, vertical: false)
    .padding(.horizontal, Theme.Spacing.small)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(color.opacity(0.1))
  }
}
