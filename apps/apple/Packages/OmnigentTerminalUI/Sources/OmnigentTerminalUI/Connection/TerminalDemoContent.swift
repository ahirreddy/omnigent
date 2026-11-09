import Foundation

/// Synthesized terminal byte streams for previews, the gallery and tests. Each exercises the
/// features harness TUIs (Claude Code, Codex, Pi) rely on. None of it is a recording; recorded
/// streams come from ``ReplayTerminalConnection``.
public enum TerminalDemoContent {
  private static let esc = "\u{1b}"

  /// The 16 ANSI colors, the 256-color cube and a truecolor ramp.
  public static var colorSwatches: String {
    var text = ""
    for row in 0..<2 {
      for index in 0..<8 {
        text += "\(esc)[48;5;\(row * 8 + index)m   "
      }
      text += "\(esc)[0m\r\n"
    }
    for block in 0..<6 {
      for index in 0..<36 {
        text += "\(esc)[48;5;\(16 + block * 36 + index)m "
      }
      text += "\(esc)[0m\r\n"
    }
    for step in 0..<72 {
      let red = 255 - step * 255 / 71
      let blue = step * 255 / 71
      text += "\(esc)[48;2;\(red);96;\(blue)m "
    }
    text += "\(esc)[0m\r\n"
    text += "\(esc)[1mbold\(esc)[0m \(esc)[3mitalic\(esc)[0m \(esc)[4munderline\(esc)[0m "
    text += "\(esc)[4:3mcurly\(esc)[0m \(esc)[9mstrike\(esc)[0m \(esc)[7minverse\(esc)[0m\r\n"
    return text
  }

  /// A full-screen harness-style TUI: alternate screen, mouse reporting (SGR), bracketed paste,
  /// the kitty keyboard protocol, truecolor, box drawing and an absolutely positioned prompt.
  /// The caller's renderer must leave the alternate screen to return to the shell; this demo
  /// leaves it on the next `q` the echo shell receives as a regular line.
  public static func harnessTUI(columns: Int = 80, rows: Int = 24) -> String {
    let width = max(40, min(columns, 120))
    let inner = width - 2
    let rows = max(rows, 0)
    func line(_ text: String, visible: Int) -> String {
      "\(esc)[38;2;204;120;92m│\(esc)[0m\(text)\(String(repeating: " ", count: max(0, inner - visible)))"
        + "\(esc)[38;2;204;120;92m│\(esc)[0m\r\n"
    }
    var text = ""
    // Alternate screen, hide cursor, SGR mouse, bracketed paste, kitty keyboard flags 1.
    text += "\(esc)[?1049h\(esc)[?25l\(esc)[?1000h\(esc)[?1006h\(esc)[?2004h\(esc)[>1u"
    text += "\(esc)[H\(esc)[2J"
    let rule = String(repeating: "─", count: inner)
    text += "\(esc)[38;2;204;120;92m╭\(rule)╮\(esc)[0m\r\n"
    let title = " ✻ Harness TUI demo (synthesized fixture)"
    text += line("\(esc)[1;38;2;204;120;92m\(title)\(esc)[0m", visible: title.count)
    let cwd = "   cwd: ~/src/omnigent  model: example-model"
    text += line("\(esc)[2m\(cwd)\(esc)[0m", visible: cwd.count)
    text += "\(esc)[38;2;204;120;92m╰\(rule)╯\(esc)[0m\r\n\r\n"
    text += "\(esc)[38;2;120;180;255m>\(esc)[0m Refactor the attach reconnect policy\r\n\r\n"
    text += "\(esc)[38;2;80;200;120m●\(esc)[0m I'll read the state machine first.\r\n\r\n"
    text += "\(esc)[38;2;80;200;120m●\(esc)[0m \(esc)[1mRead\(esc)[0m(terminal/attach.rs)\r\n"
    text += "  ⎿  Read \(esc)[1m412\(esc)[0m lines\r\n\r\n"
    text += "\(esc)[38;2;80;200;120m●\(esc)[0m \(esc)[1mUpdate\(esc)[0m(terminal/attach.rs)\r\n"
    text += "  ⎿  \(esc)[48;2;64;24;24m\(esc)[38;2;255;160;160m-   max_reconnects: 10,"
    text += "\(esc)[0m\r\n"
    text += "     \(esc)[48;2;20;56;32m\(esc)[38;2;160;255;180m+   max_reconnects: 15,"
    text += "\(esc)[0m\r\n\r\n"
    text += "\(esc)[\(rows - 4);1H"
    text += "\(esc)[38;2;110;110;110m╭\(rule)╮\(esc)[0m\r\n"
    text += "\(esc)[38;2;110;110;110m│\(esc)[0m > \(String(repeating: " ", count: inner - 3))"
    text += "\(esc)[38;2;110;110;110m│\(esc)[0m\r\n"
    text += "\(esc)[38;2;110;110;110m╰\(rule)╯\(esc)[0m\r\n"
    text += "\(esc)[2m  ? for shortcuts · esc to interrupt · mouse and paste enabled\(esc)[0m"
    text += "\(esc)[\(rows - 3);5H\(esc)[?25h"
    return text
  }

  /// Leaves ``harnessTUI(columns:rows:)``'s modes and screen.
  public static var leaveHarnessTUI: String {
    "\(esc)[<u\(esc)[?2004l\(esc)[?1006l\(esc)[?1000l\(esc)[?1049l\(esc)[?25h"
  }
}
