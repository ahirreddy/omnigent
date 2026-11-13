import SwiftUI

/// Builds one colored terminal line from parts.
nonisolated struct CLILineText {
  struct Part {
    var text: String
    var color: SRGB?
    var bold: Bool
    /// Text that brings its own colors (highlighted code), drawn as it is.
    var styled: AttributedString?
  }

  var parts: [Part] = []

  mutating func append(_ text: String, _ color: SRGB? = nil, bold: Bool = false) {
    parts.append(Part(text: text, color: color, bold: bold))
  }

  /// Appends text that is already colored.
  mutating func append(styled: AttributedString) {
    parts.append(
      Part(text: String(styled.characters), color: nil, bold: false, styled: styled))
  }

  var attributed: AttributedString {
    var result = AttributedString()
    for part in parts {
      var piece = part.styled ?? AttributedString(part.text)
      if let color = part.color { piece.foregroundColor = color.color }
      if part.bold { piece.inlinePresentationIntent = .stronglyEmphasized }
      result.append(piece)
    }
    return result
  }

  var plain: String { parts.map(\.text).joined() }
}

/// A `•` line: the marker in the gutter, the text on the column. A live line's marker pulses.
struct CLIBulletLine: View {
  let line: CLILineText
  var marker: SRGB?
  var isLive = false
  /// The marker's glyph; `•` unless the line is a notice with its own.
  var glyph = CLIBullet.glyph
  /// What VoiceOver reads before the line, for what only the marker's color says.
  var spokenPrefix = ""
  @Environment(\.cliPalette) private var palette
  private(set) var size = CLIFontSize()

  var body: some View {
    Text(line.attributed)
      .foregroundStyle(palette.body.color)
      .cliFont()
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cliMarker(bullet)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(spokenPrefix + line.plain)
  }

  @ViewBuilder private var bullet: some View {
    let color = (marker ?? palette.bullet).color
    if isLive {
      // The glyph sizes the gutter; Core Animation draws and pulses it.
      Text(verbatim: glyph)
        .hidden()
        .overlay {
          LoopingIndicator(
            shape: .glyph(glyph, size: size.points),
            motion: .fade(low: 0.25, duration: 0.6), color: .system(color))
        }
    } else {
      Text(verbatim: glyph).foregroundStyle(color)
    }
  }
}

/// The CLI's line markers.
nonisolated enum CLIBullet {
  static let glyph = "\u{2022}"
  /// An error's marker.
  static let error = "\u{25A0}"
  /// A failed edit's marker.
  static let failed = "\u{2718}"
}

/// Text on the `└` branch under a line: its first lines, then how many more there are, as the
/// Codex CLI shows a command's output.
struct CLIOutputTree: View {
  let text: String
  var color: KeyPath<CLIPalette, SRGB> = \.dim
  /// How many lines show while `showsAll` is off.
  let limit: Int
  @Binding var showsAll: Bool
  @Environment(\.cliPalette) private var palette
  private(set) var size = CLIFontSize()

  /// "… +1 line" or "… +12 lines".
  static func more(_ hidden: Int) -> String {
    "\u{2026} +\(hidden) \(hidden == 1 ? "line" : "lines")"
  }

  var body: some View {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let isCut = !showsAll && lines.count > limit
    let shown = isCut ? lines.prefix(limit).joined(separator: "\n") : text
    VStack(alignment: .leading, spacing: size.lineSpacing) {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text(verbatim: "\u{2514} ").foregroundStyle(palette.dim.color).cliFont()
          .accessibilityHidden(true)
        CLISourceText(text: shown, tintsMarkdown: false, color: color)
      }
      if isCut {
        Button(Self.more(lines.count - limit)) { showsAll = true }
          .buttonStyle(.plain)
          .foregroundStyle(palette.dim.color)
          .cliFont()
          .padding(.leading, size.character * 2)
      }
    }
  }
}

/// Raw detail text under a line: `└` then the text exactly as recorded, long text cut at
/// `maxLines` until asked for the rest.
struct CLIDetailText: View {
  let text: String
  var color: KeyPath<CLIPalette, SRGB> = \.dim
  var maxLines = 40
  @State private var showsAll = false

  var body: some View {
    CLIOutputTree(text: text, color: color, limit: maxLines, showsAll: $showsAll)
  }
}
