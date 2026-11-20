import Foundation

/// What a draft's tints follow: the session's commands and skills, whether the draft runs as a
/// shell command, and the paths tagged as mentions.
nonisolated public struct ComposerTokenSource: Hashable, Sendable {
  /// The `/` menu's commands and skills.
  public var commands: [SlashCommand]
  /// The draft runs as a shell command, so its `!` is tinted.
  public var isShell: Bool
  /// Workspace paths tagged with `@`.
  public var mentions: [String]

  /// Creates a source.
  /// - Parameters:
  ///   - commands: Commands and skills.
  ///   - isShell: A shell command.
  ///   - mentions: Tagged paths.
  public init(commands: [SlashCommand] = [], isShell: Bool = false, mentions: [String] = []) {
    self.commands = commands
    self.isShell = isShell
    self.mentions = mentions
  }
}

/// What the composer tints in a draft, as the web's `composerHighlight`: a leading command or
/// skill the session knows (an unknown `/word` stays plain, as it won't run), the `!` of a
/// shell command, and `@` paths tagged as mentions. Display only; the draft is never changed.
nonisolated struct ComposerTokens: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case command
    case shell
    case mention
  }

  /// One tinted run, in characters from the start of the draft.
  struct Token: Hashable, Sendable {
    var kind: Kind
    var range: Range<Int>
  }

  /// The tinted runs, in text order.
  let tokens: [Token]

  /// The tokens of `draft`.
  init(draft: String, source: ComposerTokenSource) {
    var tokens: [Token] = []
    if source.isShell, let bang = draft.firstIndex(of: "!") {
      let start = draft.distance(from: draft.startIndex, to: bang)
      tokens.append(Token(kind: .shell, range: start..<start + 1))
    } else if let command = Self.command(in: draft, commands: source.commands) {
      tokens.append(Token(kind: .command, range: command))
    }
    let taken = tokens.map(\.range)
    let mentions = Self.mentions(in: draft, paths: source.mentions).filter { range in
      !taken.contains { $0.overlaps(range) }
    }
    tokens += mentions.map { Token(kind: .mention, range: $0) }
    self.tokens = tokens.sorted { $0.range.lowerBound < $1.range.lowerBound }
  }

  /// The leading known command or skill (the web's `matchSlashCommandInvocation`): the longest
  /// one the trimmed draft starts with, followed by its end or whitespace. Commands run in any
  /// case, as the main chat's built-ins do; a skill matches as written.
  static func command(in draft: String, commands: [SlashCommand]) -> Range<Int>? {
    let leading = draft.prefix { $0.isWhitespace }.count
    let firstWord = draft.dropFirst(leading).prefix { !$0.isWhitespace }
    guard !firstWord.isEmpty else { return nil }
    let word = String(firstWord)
    let known = commands.contains { command in
      command.isSkill ? command.id == word : command.id.lowercased() == word.lowercased()
    }
    return known ? leading..<leading + word.count : nil
  }

  /// Where tagged `@` paths sit (the web's `findMentionTokens`): a token starts a word and ends
  /// at whitespace, punctuation or the end; a longer token wins over one it contains.
  static func mentions(in draft: String, paths: [String]) -> [Range<Int>] {
    guard !paths.isEmpty else { return [] }
    let characters = Array(draft)
    let tokens = Set(paths.map { "@\($0)" }).sorted { $0.count > $1.count }
    var ranges: [Range<Int>] = []
    for token in tokens {
      let needle = Array(token)
      guard needle.count <= characters.count else { continue }
      for start in 0...(characters.count - needle.count)
      where characters[start..<start + needle.count].elementsEqual(needle) {
        let end = start + needle.count
        guard start == 0 || characters[start - 1].isWhitespace else { continue }
        guard end == characters.count || endsToken(characters[end]) else { continue }
        guard !ranges.contains(where: { $0.overlaps(start..<end) }) else { continue }
        ranges.append(start..<end)
      }
    }
    return ranges.sorted { $0.lowerBound < $1.lowerBound }
  }

  private static func endsToken(_ character: Character) -> Bool {
    character.isWhitespace || ".,;:!?)]}'\"".contains(character)
  }
}
