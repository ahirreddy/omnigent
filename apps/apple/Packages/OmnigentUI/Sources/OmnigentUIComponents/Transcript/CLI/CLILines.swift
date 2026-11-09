import SwiftUI

/// Builds one colored terminal line from parts.
nonisolated struct CLILineText {
  struct Part {
    var text: String
    var color: SRGB?
    var bold: Bool
  }

  var parts: [Part] = []

  mutating func append(_ text: String, _ color: SRGB? = nil, bold: Bool = false) {
    parts.append(Part(text: text, color: color, bold: bold))
  }

  var attributed: AttributedString {
    var result = AttributedString()
    for part in parts {
      var piece = AttributedString(part.text)
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
      .accessibilityLabel(line.plain)
  }

  @ViewBuilder private var bullet: some View {
    let color = (marker ?? palette.bullet).color
    if isLive {
      // The glyph sizes the gutter; Core Animation draws and pulses it.
      Text(verbatim: CLIBullet.glyph)
        .hidden()
        .overlay {
          LoopingIndicator(
            shape: .glyph(CLIBullet.glyph, size: size.points),
            motion: .fade(low: 0.25, duration: 0.6), color: .system(color))
        }
    } else {
      Text(verbatim: CLIBullet.glyph).foregroundStyle(color)
    }
  }
}

/// The CLI's line marker.
nonisolated enum CLIBullet {
  static let glyph = "\u{2022}"
}

/// Raw detail text under a line: `└` then the text exactly as recorded.
struct CLIDetailText: View {
  let text: String
  var color: KeyPath<CLIPalette, SRGB> = \.dim
  var maxLines = 40
  @State private var showsAll = false
  @Environment(\.cliPalette) private var palette
  private(set) var size = CLIFontSize()

  var body: some View {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let shown =
      showsAll || lines.count <= maxLines ? text : lines.prefix(maxLines).joined(separator: "\n")
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text(verbatim: "\u{2514} ").foregroundStyle(palette.dim.color).cliFont()
          .accessibilityHidden(true)
        CLISourceText(text: shown, tintsMarkdown: false, color: color)
      }
      if lines.count > maxLines, !showsAll {
        Button("\u{2026} +\(lines.count - maxLines) lines") { showsAll = true }
          .buttonStyle(.plain)
          .foregroundStyle(palette.dim.color)
          .cliFont()
          .padding(.leading, size.character * 2)
      }
    }
  }
}
