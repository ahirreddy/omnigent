import Foundation

/// Where a Settings search result leads.
nonisolated public enum SettingsSearchTarget: Hashable, Sendable {
  /// A category of the page (the Mac sidebar's, or an iPhone and iPad page), by title.
  case category(String)
  /// A pane of a server's settings.
  case serverPane(ServerSettingsPane)
  /// A row of the Keyboard Shortcuts sheet.
  case shortcut
}

/// One Settings search result: a row, a pane or a keyboard shortcut.
nonisolated public struct SettingsSearchEntry: Hashable, Sendable, Identifiable {
  /// Stable identity.
  public let id: String
  /// The row's name, as its page shows it.
  public let title: String
  /// Where it is, for the result's second line ("Appearance › Transcript").
  public let location: String
  /// Other words it is found by.
  public let keywords: [String]
  /// A shortcut's keys, as the menu bar writes them.
  public let keys: String?
  /// Where picking it goes.
  public let target: SettingsSearchTarget
  /// The row's accessibility identifier, which the page scrolls to and marks; `nil` for a pane.
  public let anchor: String?

  /// Creates an entry.
  /// - Parameters:
  ///   - id: Identity.
  ///   - title: The row's name.
  ///   - location: Where it is.
  ///   - keywords: Other words.
  ///   - keys: A shortcut's keys.
  ///   - target: Where it goes.
  ///   - anchor: The row's accessibility identifier.
  public init(
    id: String, title: String, location: String, keywords: [String] = [], keys: String? = nil,
    target: SettingsSearchTarget, anchor: String? = nil
  ) {
    self.id = id
    self.title = title
    self.location = location
    self.keywords = keywords
    self.keys = keys
    self.target = target
    self.anchor = anchor
  }
}

/// What this build, server and account show, so search offers only results that land on a row.
nonisolated public struct SettingsSearchScope: Hashable, Sendable {
  /// The categories shown, by title, in order.
  public var categories: [String]
  /// The panes the server's settings offer.
  public var serverPanes: [ServerSettingsPane]
  /// The Servers category's title, when the panes sit under one (the Mac).
  public var serversCategory: String?
  /// The Mac, whose rows differ in places.
  public var isMac: Bool

  /// Creates a scope.
  /// - Parameters:
  ///   - categories: The categories shown.
  ///   - serverPanes: The server panes offered.
  ///   - serversCategory: The category the panes sit under.
  ///   - isMac: The Mac.
  public init(
    categories: [String], serverPanes: [ServerSettingsPane], serversCategory: String? = nil,
    isMac: Bool
  ) {
    self.categories = categories
    self.serverPanes = serverPanes
    self.serversCategory = serversCategory
    self.isMac = isMac
  }
}

/// The Settings search index: every category and server pane shown, the rows inside them that
/// always show, and the keyboard shortcuts, as the web's Settings search finds them.
public enum SettingsSearchIndex {
  /// A row the catalog knows: its category, section and accessibility identifier.
  struct Row {
    let category: String
    let section: String
    let title: String
    let anchor: String
    var keywords: [String] = []
    var macOnly = false
  }

  /// The rows that always show in their category, by the title the page gives them.
  static let rows: [Row] = [
    Row(
      category: "General", section: "Composer", title: "Send with Command-Return",
      anchor: "settings.submit-with-command-return",
      keywords: ["return", "enter", "newline", "submit"]),
    Row(
      category: "General", section: "Composer", title: "Always steer",
      anchor: "settings.always-steer", keywords: ["queue", "follow-up"]),
    Row(
      category: "General", section: "Projects", title: "Kanban board views",
      anchor: "settings.project-kanban-board", keywords: ["board", "project"]),
    Row(
      category: "General", section: "Sessions", title: "Automatically name new sessions",
      anchor: "settings.background-session-titles", keywords: ["title", "rename"]),
    Row(
      category: "General", section: "Links and Sub-agents",
      title: "Open links in the in-app browser", anchor: "settings.open-links-in-app",
      keywords: ["browser", "url"]),
    Row(
      category: "General", section: "Links and Sub-agents",
      title: "Open sub-agents in a new window", anchor: "settings.open-subagents-in-panel",
      keywords: ["subagent", "window"]),
    Row(
      category: "General", section: "Browser", title: "Browser engine",
      anchor: "settings.browserEngine", keywords: ["chromium", "webkit"], macOnly: true),
    Row(
      category: "General", section: "Browsing", title: "Search engine",
      anchor: "settings.browser.searchEngine", keywords: ["google"], macOnly: true),
    Row(
      category: "Notifications", section: "Notifications", title: "Play sound",
      anchor: "settings.notifications.play-sound", keywords: ["sound", "alert"],
      macOnly: true),
    Row(
      category: "Local Server", section: "Menu Bar", title: "Show Omnigent in the menu bar",
      anchor: "settings.local-server.menu-bar", keywords: ["status item"], macOnly: true),
    Row(
      category: "Appearance", section: "Theme", title: "Mode", anchor: "settings.appearance",
      keywords: ["dark", "light", "system"]),
    Row(
      category: "Appearance", section: "Theme", title: "Terminal theme",
      anchor: "settings.terminal-theme", keywords: ["dark", "light"]),
    Row(
      category: "Appearance", section: "Theme", title: "Theme palette",
      anchor: "settings.theme", keywords: ["color", "colour"]),
    Row(
      category: "Appearance", section: "Theme", title: "Use system accent",
      anchor: "settings.system-accent", keywords: ["color", "accent"]),
    Row(
      category: "Appearance", section: "Transcript", title: "Transcript style",
      anchor: "settings.transcript-style", keywords: ["chat", "cli"]),
    Row(
      category: "Appearance", section: "Transcript", title: "Output rendering",
      anchor: "settings.output-rendering", keywords: ["markdown"]),
    Row(
      category: "Appearance", section: "Transcript", title: "Content width",
      anchor: "settings.content-width", keywords: ["wide", "narrow"]),
    Row(
      category: "Appearance", section: "Chat defaults", title: "Hide unconfigured harnesses",
      anchor: "settings.hide-unconfigured-harnesses", keywords: ["picker", "agents"]),
    Row(
      category: "Appearance", section: "Chat defaults", title: "Default transcript view",
      anchor: "settings.default-transcript-view", keywords: ["terminal", "chat"]),
    Row(
      category: "Appearance", section: "Session list", title: "Harness icons",
      anchor: "settings.harness-icon", keywords: ["sidebar", "icon"]),
    Row(
      category: "Appearance", section: "Session list",
      title: "Show Pin and Archive buttons on session rows",
      anchor: "settings.session-row-quick-actions", keywords: ["sidebar", "pin", "archive"],
      macOnly: true),
    Row(
      category: "Appearance", section: "Workspace", title: "Workspace panel",
      anchor: "settings.workspace-panel", keywords: ["right panel", "inspector"]),
    Row(
      category: "Appearance", section: "Workspace", title: "Default tab",
      anchor: "settings.workspace-tab", keywords: ["right panel", "files"]),
    Row(
      category: "Appearance", section: "Code typography", title: "Code font size",
      anchor: "settings.code-font-size", keywords: ["monospace", "text size"]),
    Row(
      category: "Appearance", section: "Code typography", title: "Code font family",
      anchor: "settings.code-font-family", keywords: ["monospace", "typeface"]),
    Row(
      category: "Appearance", section: "Code typography", title: "Heavier code font",
      anchor: "settings.code-font-weight", keywords: ["bold", "weight"]),
    Row(
      category: "Appearance", section: "Settings data", title: "Export settings",
      anchor: "settings.data.export", keywords: ["backup", "file"]),
    Row(
      category: "Appearance", section: "Settings data", title: "Import settings",
      anchor: "settings.data.import", keywords: ["restore", "file"]),
    Row(
      category: "Appearance", section: "Settings data", title: "Reset to defaults",
      anchor: "settings.data.reset", keywords: ["restore"]),
    Row(
      category: "Terminal", section: "Font", title: "Terminal font family",
      anchor: "settings.terminal-font-family", keywords: ["monospace", "typeface"]),
    Row(
      category: "Terminal", section: "Behavior", title: "Copying from terminals",
      anchor: "settings.terminal-clipboard", keywords: ["clipboard", "copy"]),
  ]

  /// A row inside a server pane.
  struct PaneRow {
    let pane: ServerSettingsPane
    let title: String
    let anchor: String
    let keywords: [String]
  }

  /// Rows inside server panes, shown wherever their pane is.
  static let paneRows: [PaneRow] = [
    PaneRow(
      pane: .sessions, title: "Session title instructions",
      anchor: "settings.session-title-instructions", keywords: ["title"]),
    PaneRow(
      pane: .advisor, title: "Omni Advisor", anchor: "settings.advisor-switch",
      keywords: ["proactive", "suggestions"]),
    PaneRow(
      pane: .archived, title: "Mark as expired after", anchor: "settings.archived.retention",
      keywords: ["retention", "delete"]),
    PaneRow(
      pane: .importSessions, title: "Import", anchor: "settings.import.mode",
      keywords: ["claude", "codex", "history"]),
  ]

  /// Every result `scope` shows: categories, server panes, their rows, then shortcuts.
  /// - Parameter scope: What this build, server and account show.
  /// - Returns: The entries, in page order.
  public static func entries(_ scope: SettingsSearchScope) -> [SettingsSearchEntry] {
    let categories = Set(scope.categories)
    var entries = scope.categories.map { category in
      SettingsSearchEntry(
        id: "category:\(category)", title: category, location: "Settings",
        target: .category(category))
    }
    for row in rows where categories.contains(row.category) && (scope.isMac || !row.macOnly) {
      entries.append(
        SettingsSearchEntry(
          id: row.anchor, title: row.title, location: "\(row.category) › \(row.section)",
          keywords: row.keywords, target: .category(row.category), anchor: row.anchor))
    }
    let paneParent = scope.serversCategory.map { "\($0) › " } ?? ""
    for pane in scope.serverPanes {
      entries.append(
        SettingsSearchEntry(
          id: "pane:\(pane.rawValue)", title: pane.title,
          location: scope.serversCategory ?? "Server", target: .serverPane(pane)))
      for row in paneRows where row.pane == pane {
        entries.append(
          SettingsSearchEntry(
            id: row.anchor, title: row.title, location: "\(paneParent)\(pane.title)",
            keywords: row.keywords, target: .serverPane(pane), anchor: row.anchor))
      }
    }
    // Shortcuts' send keys follow the send preference.
    let groups = ShortcutGuide.groups(
      submitWithCommandReturn: ComposerPreferences.commandReturnSends, isMac: scope.isMac)
    for group in groups {
      for row in group.rows {
        entries.append(
          SettingsSearchEntry(
            id: "shortcut:\(group.title):\(row.title)", title: row.title,
            location: "Keyboard Shortcuts › \(group.title)", keywords: ["shortcut", "keys"],
            keys: row.keys, target: .shortcut))
      }
    }
    return entries
  }

  /// The entries `query` finds, best first: a chord ("cmd k", "⌥B") finds the shortcuts bound
  /// to it; words find titles first, then locations and other words.
  /// - Parameters:
  ///   - query: What was typed.
  ///   - entries: The index.
  /// - Returns: The matches; none for a blank query.
  public static func results(_ query: String, in entries: [SettingsSearchEntry])
    -> [SettingsSearchEntry]
  {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    if let chord = SettingsSearchChord(query: trimmed) {
      let bound = entries.filter { entry in
        entry.keys.map(SettingsSearchChord.chords(in:))?.contains(chord) == true
      }
      if !bound.isEmpty { return bound }
    }
    let words = trimmed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    var ranked: [[SettingsSearchEntry]] = Array(repeating: [], count: 4)
    for entry in entries {
      if let rank = rank(entry, words: words, phrase: trimmed.lowercased()) {
        ranked[rank].append(entry)
      }
    }
    // Best rank first; page order within a rank.
    return ranked.flatMap(\.self)
  }

  /// How well `entry` matches: 0 a title starting with the phrase, 1 a title word starting with
  /// it, 2 a title holding it, 3 every word found anywhere; `nil` for no match.
  private static func rank(_ entry: SettingsSearchEntry, words: [String], phrase: String) -> Int? {
    let title = entry.title.lowercased()
    if title.hasPrefix(phrase) { return 0 }
    if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: {
      $0.hasPrefix(phrase)
    }) {
      return 1
    }
    if title.contains(phrase) { return 2 }
    let haystack = ([entry.title, entry.location, entry.keys ?? ""] + entry.keywords)
      .joined(separator: " ").lowercased()
    return words.allSatisfy(haystack.contains) ? 3 : nil
  }
}

/// A key chord as typed in Settings search ("cmd k", "opt+b", "⌥B") or as the Keyboard
/// Shortcuts sheet writes one ("⌥⌘S").
nonisolated struct SettingsSearchChord: Hashable {
  /// The modifier symbols, in the menu bar's order (⌃⌥⇧⌘).
  let modifiers: String
  /// The key, upper-cased.
  let key: String

  private static let order: [Character] = ["⌃", "⌥", "⇧", "⌘"]
  private static let modifierWords: [String: Character] = [
    "cmd": "⌘", "command": "⌘", "⌘": "⌘", "opt": "⌥", "option": "⌥", "alt": "⌥", "⌥": "⌥",
    "ctrl": "⌃", "control": "⌃", "⌃": "⌃", "shift": "⇧", "⇧": "⇧",
  ]
  private static let keyWords: [String: String] = [
    "return": "RETURN", "enter": "RETURN", "esc": "ESC", "escape": "ESC", "tab": "TAB",
    "space": "SPACE", "up": "↑", "down": "↓", "left": "←", "right": "→",
  ]

  /// Reads a typed chord: at least one modifier and exactly one key.
  init?(query: String) {
    var tokens: [String] = []
    for part in query.lowercased().split(whereSeparator: { $0 == " " || $0 == "+" }) {
      var rest = Substring(part)
      // "⌥b" and "⌘⇧k": peel the leading symbols off as their own tokens.
      while let first = rest.first, Self.order.contains(first) {
        tokens.append(String(first))
        rest = rest.dropFirst()
      }
      if !rest.isEmpty { tokens.append(String(rest)) }
    }
    var modifiers = Set<Character>()
    var keys: [String] = []
    for token in tokens {
      if let modifier = Self.modifierWords[token] {
        modifiers.insert(modifier)
      } else {
        keys.append(token)
      }
    }
    guard !modifiers.isEmpty, keys.count == 1, let key = keys.first,
      let normalized = Self.key(key)
    else { return nil }
    self.modifiers = String(Self.order.filter(modifiers.contains))
    self.key = normalized
  }

  private init(modifiers: String, key: String) {
    self.modifiers = modifiers
    self.key = key
  }

  /// A key word or a single character, upper-cased.
  private static func key(_ token: String) -> String? {
    if let word = keyWords[token] { return word }
    return token.count == 1 ? token.uppercased() : nil
  }

  /// The chords a shortcut row's keys name: "⌥⌘S", "⌃⌘1–9 / ⌃⌘0", "Esc or ⌘.".
  static func chords(in keys: String) -> [Self] {
    let separators = [" / ", " or ", "–"]
    var parts = [keys]
    for separator in separators {
      parts = parts.flatMap { $0.components(separatedBy: separator) }
    }
    return parts.compactMap { part in
      let text = part.trimmingCharacters(in: .whitespaces)
      let modifiers = String(text.prefix { order.contains($0) })
      let key = String(text.dropFirst(modifiers.count))
      guard !modifiers.isEmpty, let normalized = Self.key(key.lowercased()) else { return nil }
      return Self(modifiers: String(order.filter(modifiers.contains)), key: normalized)
    }
  }
}
