public import SwiftUI

/// How a session row shows the harness that runs it.
nonisolated public enum HarnessIconStyle: String, Hashable, Sendable, CaseIterable, Codable {
  /// The harness's mark in its brand colors, where it has them.
  case color
  /// The mark in the text color.
  case monochrome
  /// No mark.
  case hidden

  /// The menu title.
  public var title: String {
    switch self {
    case .color: "Color"
    case .monochrome: "Monochrome"
    case .hidden: "Off"
    }
  }
}

/// A harness's mark as vector parts in a 24-unit square: the one-color glyph, and the brand's
/// colored one where it has one.
nonisolated struct HarnessMark: Sendable {
  enum Paint: Sendable {
    /// The text color around the mark.
    case foreground
    case color(UInt32)
    /// Top to bottom.
    case gradient([UInt32])
    /// Leading to trailing.
    case sweep([UInt32], opacity: Double)
  }

  struct Part: Sendable {
    let path: String
    let paint: Paint
    var evenOdd = true
    /// The line width of a part that is drawn as a line rather than filled.
    var stroke: CGFloat?
    /// The blur of a soft color field, in the mark's units.
    var blur: CGFloat?
  }

  static let side: CGFloat = 24

  let mono: [Part]
  /// The brand's colored parts; empty for a mark that has none.
  var color: [Part] = []
  /// The outline the colored parts are cut to.
  var clip: String?

  /// The parts to draw for `style`: the colored ones when the mark has them and color is on.
  func parts(_ style: HarnessIconStyle) -> [Part] {
    style == .color && !color.isEmpty ? color : mono
  }
}

/// Parsed harness marks, built once each.
@MainActor
final class HarnessMarkPaths {
  static let shared = HarnessMarkPaths()

  struct Drawing {
    let parts: [(part: HarnessMark.Part, path: Path)]
    let clip: Path?
  }

  private struct Key: Hashable {
    let identifier: String
    let style: HarnessIconStyle
  }

  private var drawings: [Key: Drawing] = [:]

  func drawing(_ identifier: String, _ style: HarnessIconStyle) -> Drawing? {
    let key = Key(identifier: identifier, style: style)
    if let known = drawings[key] { return known }
    guard let mark = HarnessMark.marks[identifier] else { return nil }
    let isColored = style == .color && !mark.color.isEmpty
    let drawing = Drawing(
      parts: mark.parts(style).map { ($0, SVGPath.parse($0.path)) },
      clip: isColored ? mark.clip.map(SVGPath.parse) : nil)
    drawings[key] = drawing
    return drawing
  }
}

/// The mark of the harness that runs a session: its brand glyph, or a monogram for a harness
/// without one.
struct HarnessIcon: View {
  let harness: String?
  var style = HarnessIconStyle.color
  var size: CGFloat = 16

  var body: some View {
    let appearance = HarnessAppearance(harness: harness)
    Group {
      if let drawing = HarnessMarkPaths.shared.drawing(appearance.identifier, style) {
        Canvas { context, canvas in
          Self.draw(drawing, in: &context, size: canvas)
        }
      } else {
        HarnessGlyph(harness: harness, size: size, isMonochrome: style != .color)
      }
    }
    .frame(width: size, height: size)
    .accessibilityElement()
    .accessibilityLabel(appearance.label)
    .accessibilityAddTraits(.isImage)
  }

  static func draw(
    _ drawing: HarnessMarkPaths.Drawing, in context: inout GraphicsContext, size: CGSize
  ) {
    let scale = min(size.width, size.height) / HarnessMark.side
    let transform = CGAffineTransform(scaleX: scale, y: scale)
    if let clip = drawing.clip { context.clip(to: clip.applying(transform)) }
    for (part, path) in drawing.parts {
      let shape = path.applying(transform)
      let shading = shading(part.paint, size: size)
      context.drawLayer { layer in
        if let blur = part.blur { layer.addFilter(.blur(radius: blur * scale)) }
        if let stroke = part.stroke {
          let style = StrokeStyle(lineWidth: stroke * scale, lineCap: .round, lineJoin: .round)
          layer.stroke(shape, with: shading, style: style)
        } else {
          layer.fill(shape, with: shading, style: FillStyle(eoFill: part.evenOdd))
        }
      }
    }
  }

  static func shading(_ paint: HarnessMark.Paint, size: CGSize) -> GraphicsContext.Shading {
    switch paint {
    case .foreground:
      return .foreground
    case .color(let hex):
      return .color(Color(hex: hex))
    case .gradient(let stops):
      return .linearGradient(
        Gradient(colors: stops.map { Color(hex: $0) }),
        startPoint: CGPoint(x: size.width / 2, y: 0),
        endPoint: CGPoint(x: size.width / 2, y: size.height))
    case .sweep(let stops, let opacity):
      return .linearGradient(
        Gradient(colors: stops.map { Color(hex: $0, alpha: opacity) }),
        startPoint: CGPoint(x: 0, y: size.height / 2),
        endPoint: CGPoint(x: size.width, y: size.height / 2))
    }
  }
}
