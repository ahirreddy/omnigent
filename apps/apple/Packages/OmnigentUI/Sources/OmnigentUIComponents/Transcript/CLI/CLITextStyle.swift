import Foundation

#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

/// What CLI text is built with as TextKit text: the monospaced font's size, the pixels per point
/// a text's height rounds up to, and the CLI's colors. Equal styles build equal text.
nonisolated struct CLITextStyle: Hashable, Sendable {
  var points: CGFloat
  var scale: CGFloat
  var palette: CLIPalette

  var metrics: CLITextMetrics { CLITextMetrics(points: points, scale: scale) }
}

/// The CLI font's metrics, as SwiftUI sets them (``CLIFontSize``) and as TextKit has to be told
/// to match: a line's height, the spacing under it, and the column and gap sizes the CLI views
/// count in.
nonisolated struct CLITextMetrics: Equatable, Sendable {
  let points: CGFloat
  let scale: CGFloat
  /// A line's height as SwiftUI sets the font: its ascent rounded, its descent rounded up.
  let lineHeight: CGFloat
  /// The same line as TextKit sets it: its ascent and descent rounded.
  let textKitLineHeight: CGFloat

  init(points: CGFloat, scale: CGFloat) {
    self.points = points
    self.scale = max(scale, 1)
    let font = PlatformFont.monospacedSystemFont(ofSize: points, weight: .regular)
    let ascent = font.ascender.rounded()
    lineHeight = ascent + (-font.descender).rounded(.up)
    textKitLineHeight = ascent + (-font.descender).rounded()
  }

  /// One monospaced character, as the CLI's columns count it.
  var character: CGFloat { points * CLIFontSize.characterRatio }
  /// The space between two lines of one text.
  var lineSpacing: CGFloat { points * CLIFontSize.lineSpacingRatio }
  /// The line height the CLI views estimate (``CLIFontSize/lineHeight``).
  var estimatedLineHeight: CGFloat { points * CLIFontSize.lineHeightRatio }
  /// The gap between two blocks: one line (``CLIFontSize/line``).
  var line: CGFloat { estimatedLineHeight + lineSpacing }
  /// The gap that leaves one empty line between two texts (``CLIFontSize/blankLine``).
  var blankLine: CGFloat { line + lineSpacing }
  /// From one line's top to the next's.
  var pitch: CGFloat { lineHeight + lineSpacing }
  /// The line spacing TextKit takes to put its shorter lines SwiftUI's pitch apart.
  var textKitSpacing: CGFloat { pitch - textKitLineHeight }

  /// `value` rounded up to the pixel, as SwiftUI rounds a text's height.
  func ceiled(_ value: CGFloat) -> CGFloat {
    (value * scale - 0.001).rounded(.up) / scale
  }

  /// `value` on the nearest pixel.
  func rounded(_ value: CGFloat) -> CGFloat {
    (value * scale).rounded() / scale
  }

  /// The height SwiftUI gives one text of `lines` lines.
  func textHeight(lines: Int) -> CGFloat {
    let count = CGFloat(max(1, lines))
    return ceiled(count * lineHeight + (count - 1) * lineSpacing)
  }

  /// The CLI font with `weight`, italic when `italic`.
  func font(weight: PlatformFont.Weight = .regular, italic: Bool = false) -> PlatformFont {
    let base = PlatformFont.monospacedSystemFont(ofSize: points, weight: weight)
    return italic ? MessageTextPlatform.italic(base) : base
  }
}

nonisolated extension SRGB {
  /// The color as the platform's text draws it.
  var platformColor: PlatformColor {
    #if os(macOS)
      if isDisplayP3 { return NSColor(displayP3Red: red, green: green, blue: blue, alpha: 1) }
      return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    #else
      if isDisplayP3 { return UIColor(displayP3Red: red, green: green, blue: blue, alpha: 1) }
      return UIColor(red: red, green: green, blue: blue, alpha: 1)
    #endif
  }
}
