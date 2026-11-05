import SwiftUI

/// `/` command and `@` mention completions for the current draft.
///
/// `/` (or `$`) opens commands at the start of the draft and skills after other text, under
/// "Commands" and "Skills" headers. `@` browses the workspace like the web: `@src/` lists `src`,
/// `@src/ma` filters it, and a folder row opens the folder (Return) or attaches it whole (Tab).
struct ComposerCompletions {
  struct Item: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let replacement: String
    let systemImage: String
    /// The workspace path of an `@` row.
    var mentionPath: String?
    /// The header this row starts ("Commands", "Skills"), if any.
    var section: String?

    /// An `@` folder row: Return opens it, Tab or its button attaches it whole.
    var isFolder: Bool { mentionPath?.hasSuffix("/") == true }
  }

  /// The most `@` rows listed for one folder, as on the web.
  static let mentionLimit = 50

  let items: [Item]
  /// The folder an `@` mention is browsing (`""` for the workspace root); `nil` for commands.
  let mentionFolder: String?
  private let prefixRange: Range<String.Index>?
  private let draft: String

  init(draft: String, commands: [SlashCommand], mentions: [String]) {
    self.draft = draft
    if let token = Self.commandToken(in: draft), !commands.isEmpty {
      let isInline = !draft[..<token.lowerBound].allSatisfy(\.isWhitespace)
      items = Self.commandItems(
        token: String(draft[token]), commands: isInline ? commands.filter(\.isSkill) : commands)
      prefixRange = token
      mentionFolder = nil
      return
    }
    if let mentionStart = Self.mentionStart(in: draft), !mentions.isEmpty {
      let query = String(draft[draft.index(after: mentionStart)...])
      items = Self.mentionItems(query: query, candidates: mentions)
      prefixRange = mentionStart..<draft.endIndex
      mentionFolder = query.lastIndex(of: "/").map { String(query[..<$0]) } ?? ""
      return
    }
    items = []
    prefixRange = nil
    mentionFolder = nil
  }

  /// The `/` or `$` token being typed at the end of the draft: at the start or after
  /// whitespace, made of letters, digits, `_`, `:` and `-`.
  static func commandToken(in draft: String) -> Range<String.Index>? {
    let start = draft.lastIndex(where: \.isWhitespace).map { draft.index(after: $0) }
    let tokenStart = start ?? draft.startIndex
    guard tokenStart < draft.endIndex, let typed = draft[tokenStart...].first,
      typed == "/" || typed == "$"
    else { return nil }
    let name = draft[draft.index(after: tokenStart)...]
    let allowed = name.allSatisfy { $0.isLetter || $0.isNumber || "_:-".contains($0) }
    return allowed ? tokenStart..<draft.endIndex : nil
  }

  /// Commands for the typed token, names that start with the query first; built-ins, then
  /// skills. `/` lists every command; `$` lists the ones typed with `$`. A token that already
  /// names its only match offers nothing, so Return sends it.
  private static func commandItems(token: String, commands: [SlashCommand]) -> [Item] {
    let typed = String(token.prefix(1))
    let query = token.dropFirst().lowercased()
    let offered = commands.filter { typed == "/" || $0.prefix == typed }
    func ranked(_ group: [SlashCommand]) -> [SlashCommand] {
      let leading = group.filter { query.isEmpty || $0.name.lowercased().hasPrefix(query) }
      let inner = group.filter {
        !query.isEmpty && !$0.name.lowercased().hasPrefix(query)
          && $0.name.lowercased().contains(query)
      }
      return leading + inner
    }
    let builtins = ranked(offered.filter { !$0.isSkill })
    let skills = ranked(offered.filter(\.isSkill))
    let matches = builtins + skills
    if matches.count == 1, matches[0].id == token || token == "/\(matches[0].name)" { return [] }
    func items(_ group: [SlashCommand], section: String) -> [Item] {
      group.enumerated().map { index, command in
        Item(
          id: command.id, title: command.id, detail: command.description,
          replacement: "\(command.id) ",
          systemImage: command.isSkill ? "wand.and.sparkles" : "command",
          section: index == 0 && !builtins.isEmpty && !skills.isEmpty ? section : nil)
      }
    }
    return items(builtins, section: "Commands") + items(skills, section: "Skills")
  }

  /// Rows for an `@` query: the candidates under the browsed folder whose path contains the
  /// typed filter, as the store listed them (folders first).
  private static func mentionItems(query: String, candidates: [String]) -> [Item] {
    let lowered = query.lowercased()
    let folder = lowered.lastIndex(of: "/").map { String(lowered[...$0]) } ?? ""
    let filter =
      lowered.lastIndex(of: "/").map { String(lowered[lowered.index(after: $0)...]) }
      ?? lowered
    return candidates.filter { candidate in
      let path = candidate.lowercased()
      guard path.hasPrefix(folder), path != folder else { return false }
      return filter.isEmpty || path.dropFirst(folder.count).contains(filter)
    }
    .prefix(mentionLimit)
    .map { path in
      let isFolder = path.hasSuffix("/")
      return Item(
        id: "@\(path)", title: path, detail: "",
        replacement: isFolder ? "@\(path)" : "@\(path) ",
        systemImage: isFolder ? "folder" : "doc", mentionPath: path)
    }
  }

  /// Where the `@` mention being typed at the end of `draft` starts.
  private static func mentionStart(in draft: String) -> String.Index? {
    guard let sign = draft.lastIndex(of: "@") else { return nil }
    let follows = sign == draft.startIndex || draft[draft.index(before: sign)].isWhitespace
    return follows && !draft[sign...].contains(where: \.isWhitespace) ? sign : nil
  }

  /// Whether `draft` ends in an `@` mention being typed.
  static func isTypingMention(_ draft: String) -> Bool {
    mentionStart(in: draft) != nil
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
