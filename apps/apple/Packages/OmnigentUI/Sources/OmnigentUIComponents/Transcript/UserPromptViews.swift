import SwiftUI

/// A user message as the web shows it: the `[Attached: path]` markers an @-mention adds become
/// chips, and a prompt over 12,000 characters starts collapsed.
nonisolated enum UserPrompt {
  /// The length past which a prompt starts collapsed.
  static let collapseThreshold = 12_000

  /// One @-mentioned workspace file or folder.
  struct Mention: Hashable, Sendable {
    let path: String
    let isFolder: Bool
  }

  /// `text` without its attachment markers, and the workspace paths they name. Absolute paths
  /// are uploads, already shown as attachments, so they are dropped without a chip.
  static func parse(_ text: String) -> (text: String, mentions: [Mention]) {
    // Both wordings the native executors emit: "[Attached: …]" and "[Attached file: …]".
    let marker = /\[Attached(?: file)?:\s*([^\]]*)\][ \t]*(?:\r?\n)*/
    var mentions: [Mention] = []
    for match in text.matches(of: marker) {
      let raw = match.1.trimmingCharacters(in: .whitespaces)
      guard !raw.isEmpty, !isAbsolute(raw) else { continue }
      let isFolder = raw.hasSuffix("/")
      mentions.append(Mention(path: isFolder ? String(raw.dropLast()) : raw, isFolder: isFolder))
    }
    guard !mentions.isEmpty || text.contains(marker) else { return (text, []) }
    let stripped = text.replacing(marker, with: "")
    let trimmed = String(stripped.reversed().drop(while: \.isWhitespace).reversed())
    return (trimmed, mentions)
  }

  /// The first `collapseThreshold` characters of `text`, or `nil` when it is short enough.
  static func collapsed(_ text: String) -> String? {
    guard text.count > collapseThreshold else { return nil }
    return String(text.prefix(collapseThreshold))
  }

  /// The web's expand button: "Show full prompt (12,345 chars)".
  static func expandTitle(_ text: String) -> String {
    "Show full prompt (\(text.count.formatted()) chars)"
  }

  private static func isAbsolute(_ path: String) -> Bool {
    path.hasPrefix("/") || path.hasPrefix("\\\\")
      || path.wholeMatch(of: /[A-Za-z]:[\\\/].*/) != nil
  }
}

/// The text of a user bubble: mention chips above Markdown, collapsed with "Show full prompt" when long, as the web.
struct UserPromptBody: View {
  let text: String
  @State private var isExpanded = false

  var body: some View {
    let prompt = UserPrompt.parse(text)
    let collapsed = isExpanded ? nil : UserPrompt.collapsed(prompt.text)
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      if !prompt.mentions.isEmpty {
        AttachedPathChips(mentions: prompt.mentions)
      }
      if !prompt.text.isEmpty {
        MarkdownView(collapsed.map { $0 + "\u{2026}" } ?? prompt.text, isStreaming: false)
          .environment(\.markdownFillsWidth, false)
          .fixedSize(horizontal: false, vertical: true)
      }
      if collapsed != nil {
        Button(UserPrompt.expandTitle(prompt.text)) { isExpanded = true }
          .buttonStyle(.borderless)
          .font(.callout)
          .accessibilityIdentifier("user-prompt-show-more")
      } else if UserPrompt.collapsed(prompt.text) != nil {
        Button("Collapse prompt") { isExpanded = false }
          .buttonStyle(.borderless)
          .font(.callout)
      }
    }
  }
}

private struct AttachedPathChips: View {
  let mentions: [UserPrompt.Mention]

  var body: some View {
    FlowLayout(spacing: Theme.Spacing.extraSmall) {
      ForEach(mentions, id: \.self) { mention in
        Label(mention.path, systemImage: mention.isFolder ? "folder" : "doc")
          .font(.caption)
          .lineLimit(1)
          .truncationMode(.middle)
          .padding(.horizontal, Theme.Spacing.small)
          .padding(.vertical, Theme.Spacing.tiny)
          .background(.quaternary, in: Capsule())
          .help(mention.path)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Attached \(mentions.map(\.path).joined(separator: ", "))")
  }
}
