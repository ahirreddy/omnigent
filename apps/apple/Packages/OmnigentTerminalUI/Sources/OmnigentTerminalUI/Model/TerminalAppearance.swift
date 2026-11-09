import Foundation

/// The terminal's light or dark palette.
public enum TerminalColorScheme: String, Hashable, Sendable, CaseIterable {
  /// Light background.
  case light
  /// Dark background.
  case dark
}

/// How much history each terminal keeps. Ghostty limits scrollback by memory, not lines.
public enum TerminalScrollback: Int, Hashable, Sendable, CaseIterable, Identifiable {
  /// About 2 MB (a few thousand lines of typical output).
  case small = 2_000_000
  /// About 10 MB.
  case standard = 10_000_000
  /// About 50 MB, Ghostty's default.
  case large = 50_000_000

  /// The stable identity.
  public var id: Int { rawValue }

  /// The settings label.
  public var label: String {
    switch self {
    case .small: "2 MB"
    case .standard: "10 MB"
    case .large: "50 MB"
    }
  }
}

/// Font, colors and behavior for every terminal surface. Built from the system appearance by
/// default; the settings screen edits it.
public struct TerminalAppearance: Hashable, Sendable {
  /// A font family name, or `nil` for the system monospaced font.
  public var fontFamily: String?
  /// Points.
  public var fontSize: Double
  /// Light or dark.
  public var colorScheme: TerminalColorScheme
  /// History kept per terminal.
  public var scrollback: TerminalScrollback
  /// macOS: the Option key sends Alt (Meta) instead of composing characters. TUIs and readline
  /// word motions want this; it costs typing characters such as `ø` with Option.
  public var optionAsAlt: Bool
  /// A blinking cursor.
  public var cursorBlink: Bool

  /// An appearance.
  public init(
    fontFamily: String? = nil,
    fontSize: Double = 13,
    colorScheme: TerminalColorScheme = .dark,
    scrollback: TerminalScrollback = .standard,
    optionAsAlt: Bool = true,
    cursorBlink: Bool = true
  ) {
    self.fontFamily = fontFamily
    self.fontSize = fontSize
    self.colorScheme = colorScheme
    self.scrollback = scrollback
    self.optionAsAlt = optionAsAlt
    self.cursorBlink = cursorBlink
  }

  /// The colors for ``colorScheme``.
  public var palette: TerminalPalette {
    colorScheme == .dark ? .dark : .light
  }
}

/// The terminal colors, matched to the web client's (`web/src/lib/terminalPalette.ts` and
/// `terminalTheme` in `TerminalSession.ts`) so a session's terminal reads the same everywhere.
public struct TerminalPalette: Hashable, Sendable {
  /// Background, `#rrggbb`.
  public let background: String
  /// Default text.
  public let foreground: String
  /// Cursor.
  public let cursor: String
  /// Selection background (opaque: Ghostty colors carry no alpha).
  public let selection: String
  /// The 16 ANSI colors, black through bright white.
  public let ansi: [String]

  /// Dark scheme.
  public static let dark = Self(
    background: "#0a0a0a",
    foreground: "#e4e4e7",
    cursor: "#22d3ee",
    selection: "#0f3a42",
    ansi: [
      "#09090b", "#ef4444", "#22c55e", "#eab308", "#3b82f6", "#a855f7", "#06b6d4", "#e4e4e7",
      "#71717a", "#f87171", "#4ade80", "#facc15", "#60a5fa", "#c084fc", "#22d3ee", "#fafafa",
    ]
  )

  /// Light scheme. ANSI white and bright white are dark tones so CLIs that assume a dark
  /// terminal stay readable on white.
  public static let light = Self(
    background: "#ffffff",
    foreground: "#18181b",
    cursor: "#0891b2",
    selection: "#cde9f0",
    ansi: [
      "#18181b", "#dc2626", "#16a34a", "#ca8a04", "#2563eb", "#9333ea", "#0891b2", "#3f3f46",
      "#e4e4e7", "#ef4444", "#22c55e", "#eab308", "#3b82f6", "#a855f7", "#06b6d4", "#18181b",
    ]
  )
}

/// Builds the Ghostty configuration text for an appearance.
///
/// Remote terminals never touch a local shell, so shell integration, close confirmation and
/// OSC 52 clipboard access are off: remote clipboard writes arrive as tmux `clipboard-write`
/// frames and need the user's consent (``TerminalOutput/clipboardWrite(_:)``).
public enum GhosttyConfigText {
  /// The configuration for `appearance`. `systemFontFamily` is the platform's monospaced
  /// family, used when the appearance names none.
  public static func make(_ appearance: TerminalAppearance, systemFontFamily: String?) -> String {
    let palette = appearance.palette
    var lines: [String] = []
    if let family = appearance.fontFamily ?? systemFontFamily, !family.isEmpty {
      lines.append("font-family = \(quoted(family))")
    }
    if appearance.fontSize.isFinite {
      lines.append("font-size = \(formatted(appearance.fontSize))")
    }
    lines.append("background = \(palette.background)")
    lines.append("foreground = \(palette.foreground)")
    lines.append("cursor-color = \(palette.cursor)")
    lines.append("selection-background = \(palette.selection)")
    for (index, color) in palette.ansi.enumerated() {
      lines.append("palette = \(index)=\(color)")
    }
    lines += [
      "scrollback-limit = \(appearance.scrollback.rawValue)",
      "macos-option-as-alt = \(appearance.optionAsAlt)",
      "cursor-style-blink = \(appearance.cursorBlink)",
      "window-padding-x = 8",
      "window-padding-y = 6",
      "window-padding-balance = true",
      "mouse-hide-while-typing = true",
      "copy-on-select = false",
      "clipboard-read = deny",
      "clipboard-write = deny",
      "clipboard-paste-protection = true",
      "confirm-close-surface = false",
      "shell-integration = none",
      "link-url = true",
    ]
    lines += keybindings.map { "keybind = \($0)" }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Only chords the terminal itself acts on. Ghostty's defaults also bind quit, new tab, close,
  /// splits and more, for an app of its own, which would take them from the app's menus.
  private static let keybindings = [
    "clear",
    "performable:super+c=copy_to_clipboard:mixed",
    "super+v=paste_from_clipboard",
    "super+a=select_all",
    "super+f=start_search",
    "super+e=search_selection",
    "performable:super+g=navigate_search:next",
    "performable:super+shift+g=navigate_search:previous",
    "performable:escape=end_search",
    "super+equal=increase_font_size:1",
    "super+shift+equal=increase_font_size:1",
    "super+minus=decrease_font_size:1",
    "super+digit_0=reset_font_size",
    "super+home=scroll_to_top",
    "super+end=scroll_to_bottom",
    "super+page_up=scroll_page_up",
    "super+page_down=scroll_page_down",
    "super+arrow_left=text:\\x01",
    "super+arrow_right=text:\\x05",
    "super+backspace=text:\\x15",
    "performable:shift+arrow_left=adjust_selection:left",
    "performable:shift+arrow_right=adjust_selection:right",
    "performable:shift+arrow_up=adjust_selection:up",
    "performable:shift+arrow_down=adjust_selection:down",
    "performable:shift+page_up=adjust_selection:page_up",
    "performable:shift+page_down=adjust_selection:page_down",
    "performable:shift+home=adjust_selection:home",
    "performable:shift+end=adjust_selection:end",
  ]

  private static func quoted(_ value: String) -> String {
    // One line in quotes, so a family cannot end its string or add a line.
    let refused = CharacterSet.controlCharacters.union(.newlines).union(["\""])
    let kept = value.unicodeScalars.filter { !refused.contains($0) }
    return "\"" + String(String.UnicodeScalarView(kept)) + "\""
  }

  private static func formatted(_ value: Double) -> String {
    if let whole = Int(exactly: value) { return String(whole) }
    return String((value * 10).rounded() / 10)
  }
}
