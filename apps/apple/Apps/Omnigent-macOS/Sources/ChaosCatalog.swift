#if DEBUG
  import AppKit

  /// What ``ChaosDriver`` can invoke: the main menu's enabled items and the app's shortcuts.
  @MainActor
  enum ChaosMenu {
    struct Item {
      let path: String
      let menu: NSMenu
      let index: Int
    }

    struct Shortcut {
      let name: String
      let key: ChaosKey
      let modifiers: NSEvent.ModifierFlags

      init(name: String, key: ChaosKey, modifiers: NSEvent.ModifierFlags) {
        self.name = name
        self.key = key
        self.modifiers = modifiers
      }

      init(_ name: String, _ character: Character, _ modifiers: NSEvent.ModifierFlags) {
        self.init(name: name, key: .shortcut(character), modifiers: modifiers)
      }
    }

    /// Items that leave the app, end the run, wait on a person (permission prompts, file panels)
    /// or reach outside the VM.
    private static let blocked = [
      "Quit", "Hide", "Services", "Check for Updates", "Sign Out", "Log Out", "Dictation",
      "Emoji", "Print", "Help", "Debug", "Open…", "Open...", "Export", "Import", "Save As",
      "Reveal", "Finder", "Share", "AutoFill", "Install", "Local Server", "Speech", "Writing Tools",
      "Open in", "Choose", "Attach", "Upload",
    ]

    /// Every enabled leaf item of the main menu, after the menus validate their items.
    static func items() -> [Item] {
      guard let main = NSApp.mainMenu else { return [] }
      var found: [Item] = []
      for top in main.items {
        guard let menu = top.submenu else { continue }
        collect(menu, path: top.title.isEmpty ? "App" : top.title, depth: 1, into: &found)
      }
      return found
    }

    private static func collect(_ menu: NSMenu, path: String, depth: Int, into found: inout [Item])
    {
      menu.update()
      for (index, item) in menu.items.enumerated()
      where !item.isSeparatorItem && !item.isHidden && !item.title.isEmpty {
        let itemPath = "\(path) > \(item.title)"
        guard !blocked.contains(where: { itemPath.localizedCaseInsensitiveContains($0) }) else {
          continue
        }
        if let submenu = item.submenu {
          if depth < 3 { collect(submenu, path: itemPath, depth: depth + 1, into: &found) }
        } else if item.isEnabled {
          found.append(Item(path: itemPath, menu: menu, index: index))
        }
      }
    }

    /// The app's shortcuts (`AppShortcuts`) and the standard editing ones, without the ones that
    /// quit, hide, dictate or print.
    static let shortcuts: [Shortcut] = {
      let command: NSEvent.ModifierFlags = .command
      let option: NSEvent.ModifierFlags = [.command, .option]
      let shift: NSEvent.ModifierFlags = [.command, .shift]
      let control: NSEvent.ModifierFlags = .control
      var list: [Shortcut] = [
        Shortcut("palette", "k", command), Shortcut("find session", "s", option),
        Shortcut("shortcuts", "/", command),
        Shortcut("previous session", "[", command), Shortcut("next session", "]", command),
        Shortcut("stop", ".", command), Shortcut("rename", "r", option),
        Shortcut("view mode", "\\", option),
        Shortcut("inspector", "i", option), Shortcut("right panel", "]", option),
        Shortcut("sidebar", "s", [.command, .control]),
        Shortcut("sidebar alias", "[", option), Shortcut("search workspace", "f", shift),
        Shortcut("expand editor", "e", shift), Shortcut("choose model", "m", [.control, .shift]),
        Shortcut("cycle model", "m", [.control, .option]),
        Shortcut("cycle effort", "e", [.control, .option]),
        Shortcut("focus composer", "l", [.control, .shift]), Shortcut("new tab", "t", command),
        Shortcut("close tab", "w", command), Shortcut("reopen tab", "t", shift),
        Shortcut("all tabs", "\\", shift),
        Shortcut("terminal", "`", control), Shortcut("new shell", "t", option),
        Shortcut("browser", "b", option),
        Shortcut("split", "\\", command),
        Shortcut("previous pane", "[", [.command, .option, .shift]),
        Shortcut("next pane", "]", [.command, .option, .shift]),
        Shortcut("new session", "n", command),
        Shortcut("new window", "n", shift), Shortcut("settings", ",", command),
        Shortcut("reconnect", "r", [.command, .option, .shift]), Shortcut("find", "f", command),
        Shortcut("find next", "g", command), Shortcut("find previous", "g", shift),
        Shortcut("selection for find", "e", command), Shortcut("zoom in", "=", command),
        Shortcut("zoom out", "-", command), Shortcut("actual size", "0", command),
        Shortcut("undo", "z", command),
        Shortcut("redo", "z", shift), Shortcut("select all", "a", command),
        Shortcut("copy", "c", command),
        Shortcut("cut", "x", command), Shortcut("paste", "v", command),
        Shortcut("close window", "w", shift),
      ]
      for digit in 1...9 {
        let character = Character("\(digit)")
        list.append(Shortcut("tab \(digit)", character, command))
        list.append(Shortcut("right panel tab \(digit)", character, option))
        list.append(Shortcut("pinned \(digit)", character, [.command, .control]))
      }
      var shortcuts = list
      shortcuts += [
        Shortcut(name: "send", key: .returnKey, modifiers: command),
        Shortcut(name: "send alternative", key: .returnKey, modifiers: option),
        Shortcut(name: "jump to latest", key: .downArrow, modifiers: command),
        Shortcut(name: "jump to first", key: .upArrow, modifiers: command),
        Shortcut(name: "previous message", key: .upArrow, modifiers: option),
        Shortcut(name: "next message", key: .downArrow, modifiers: option),
        Shortcut(name: "left pane", key: .leftArrow, modifiers: option),
        Shortcut(name: "right pane", key: .rightArrow, modifiers: option),
        Shortcut(name: "next tab", key: .tab, modifiers: control),
        Shortcut(name: "previous tab", key: .tab, modifiers: [.control, .shift]),
      ]
      return shortcuts
    }()
  }

  /// Text for ``ChaosDriver`` to type and paste: prose, markdown, commands, mentions and text off
  /// the US layout.
  enum ChaosText {
    static let snippets = [
      "hello", "Summarize the notes", "/", "/help", "@", "@notes", "**bold** and `code`",
      "```swift\nlet x = 1\n```", "# Heading", "- [ ] task", "| a | b |\n|---|---|", "é",
      "naïve café", "漢字かな", "🙂👍🏽", "مرحبا", " ", "    ", "a\tb", "x",
      "ls -la", "echo chaos", "https://example.com", String(repeating: "long ", count: 60),
    ]

    /// `lines` lines mixing prose, markdown and code, different per `seed`.
    static func paste(lines: Int, seed: UInt64) -> String {
      var generator = SplitMix(seed: seed)
      let pieces = snippets + ["", "> quote", "1. first", "    indented code", "<b>html</b>"]
      return (0..<max(1, lines)).map { line in
        "\(line) \(pieces[generator.int(below: pieces.count)])"
      }.joined(separator: "\n")
    }
  }
#endif
