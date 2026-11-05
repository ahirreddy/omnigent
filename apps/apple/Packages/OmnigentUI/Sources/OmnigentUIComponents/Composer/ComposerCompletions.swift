import SwiftUI

/// `/` command and `@` mention completions for the current draft.
struct ComposerCompletions {
  struct Item: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let replacement: String
    let systemImage: String
    /// The workspace path of an `@` row.
    var mentionPath: String?
  }

  let items: [Item]
  private let prefixRange: Range<String.Index>?
  private let draft: String

  init(draft: String, commands: [SlashCommand], mentions: [String]) {
    self.draft = draft
    if let typed = draft.first, typed == "/" || typed == "$",
      !draft.contains(where: \.isWhitespace),
      !commands.isEmpty
    {
      items = Self.commandItems(draft: draft, commands: commands)
      prefixRange = draft.startIndex..<draft.endIndex
      return
    }
    if let mentionStart = draft.lastIndex(of: "@"), !mentions.isEmpty,
      mentionStart == draft.startIndex || draft[draft.index(before: mentionStart)].isWhitespace,
      !draft[mentionStart...].contains(" ")
    {
      let query = draft[draft.index(after: mentionStart)...].lowercased()
      items = mentions.filter { query.isEmpty || $0.lowercased().contains(query) }
        .prefix(8)
        .map {
          Item(
            id: "@\($0)", title: $0, detail: "", replacement: "@\($0) ",
            systemImage: $0.hasSuffix("/") ? "folder" : "doc", mentionPath: $0)
        }
      prefixRange = mentionStart..<draft.endIndex
      return
    }
    items = []
    prefixRange = nil
  }

  /// Commands for the typed token, names that start with the query first. `/` lists every
  /// command; `$` lists the ones typed with `$`. A token that already names its only match
  /// offers nothing, so Return sends it.
  private static func commandItems(draft: String, commands: [SlashCommand]) -> [Item] {
    let typed = String(draft.prefix(1))
    let query = draft.dropFirst().lowercased()
    let offered = commands.filter { typed == "/" || $0.prefix == typed }
    let leading = offered.filter { query.isEmpty || $0.name.lowercased().hasPrefix(query) }
    let inner = offered.filter {
      !query.isEmpty && !$0.name.lowercased().hasPrefix(query)
        && $0.name.lowercased().contains(query)
    }
    let matches = Array((leading + inner).prefix(8))
    if matches.count == 1, matches[0].id == draft || draft == "/\(matches[0].name)" { return [] }
    return matches.map {
      Item(
        id: $0.id, title: $0.id, detail: $0.description, replacement: "\($0.id) ",
        systemImage: $0.isSkill ? "wand.and.sparkles" : "command")
    }
  }

  /// Whether `draft` ends in an `@` mention being typed.
  static func isTypingMention(_ draft: String) -> Bool {
    guard let sign = draft.lastIndex(of: "@") else { return false }
    let follows = sign == draft.startIndex || draft[draft.index(before: sign)].isWhitespace
    return follows && !draft[sign...].contains(where: \.isWhitespace)
  }

  /// The draft without the token being completed (a picked path becomes a chip instead).
  func removingToken() -> String {
    guard let prefixRange else { return draft }
    var copy = draft
    copy.removeSubrange(prefixRange)
    return copy
  }

  /// The row at `index`, clamped to the list; `nil` when the list is empty.
  func item(at index: Int) -> Item? {
    guard !items.isEmpty else { return nil }
    return items[min(max(index, 0), items.count - 1)]
  }

  func applying(_ item: Item) -> String {
    guard let prefixRange else { return draft }
    var copy = draft
    copy.replaceSubrange(prefixRange, with: item.replacement)
    return copy
  }
}

/// Workspace files and folders tagged with `@`, as chips over the editor; they go with the next
/// message as `[Attached: path]` lines.
struct MentionChips: View {
  let paths: [String]
  let remove: (@MainActor (String) -> Void)?

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: Theme.Spacing.small) {
        ForEach(paths, id: \.self) { path in
          HStack(spacing: Theme.Spacing.extraSmall) {
            Image(systemName: path.hasSuffix("/") ? "folder" : "doc")
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            if let remove {
              Button("Remove \(path)", systemImage: "xmark.circle.fill") { remove(path) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove \(path)")
            }
          }
          .frame(maxWidth: 260)
          .padding(.horizontal, Theme.Spacing.small)
          .padding(.vertical, Theme.Spacing.extraSmall)
          .cardSurface(cornerRadius: Theme.Radius.medium)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("composer-mention-\(path)")
        }
      }
      .padding(Theme.Spacing.tiny)
    }
    .scrollIndicators(.never)
  }
}

/// The completions over the composer. Up and Down move the highlighted row; Return and Tab
/// apply it.
struct CompletionList: View {
  let items: [ComposerCompletions.Item]
  /// Why the list may be incomplete.
  var note: String?
  /// The row Return and Tab apply.
  var highlighted: Int?
  let pick: (ComposerCompletions.Item) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        Button {
          pick(item)
        } label: {
          HStack(spacing: Theme.Spacing.small) {
            Image(systemName: item.systemImage)
              .foregroundStyle(.secondary)
              .frame(width: 16)
              .accessibilityHidden(true)
            Text(item.title).font(.callout.monospaced())
            if !item.detail.isEmpty {
              Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, Theme.Spacing.medium)
          .padding(.vertical, Theme.Spacing.extraSmall)
          .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
              .fill(ThemeColor.hover.opacity(index == highlighted ? 1 : 0))
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .accessibilityAddTraits(index == highlighted ? .isSelected : [])
        .accessibilityIdentifier("composer-completion-\(item.id)")
      }
      if let note {
        Label(note, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, Theme.Spacing.medium)
          .padding(.vertical, Theme.Spacing.extraSmall)
          .accessibilityIdentifier("composer-completion-note")
      }
      if !items.isEmpty {
        Text("\u{2191}\u{2193} to choose, Tab or Return to complete, Esc to dismiss")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .padding(.horizontal, Theme.Spacing.medium)
          .padding(.vertical, Theme.Spacing.extraSmall)
      }
    }
    .padding(.vertical, Theme.Spacing.extraSmall)
    .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    .padding(.horizontal, Theme.Spacing.small)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer-completions")
  }
}
