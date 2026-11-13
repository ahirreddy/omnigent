public import SwiftUI

/// How a session row shows the harness that runs it.
nonisolated public enum HarnessIconStyle: String, Hashable, Sendable, CaseIterable, Codable {
  /// The harness's mark in its brand colors, where it has them.
  case color
  /// The mark in the text color.
  case monochrome
  /// No mark.
  case hidden

  /// The style until one is chosen.
  public static let `default` = Self.monochrome

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
        HarnessMarkView(drawing: drawing, scale: size / HarnessMark.side)
      } else {
        HarnessGlyph(harness: harness, size: size, isMonochrome: style != .color)
      }
    }
    .frame(width: size, height: size)
    .accessibilityElement()
    .accessibilityLabel(appearance.label)
    .accessibilityAddTraits(.isImage)
  }
}

/// A mark's parts stacked as shapes. They are shapes rather than a canvas drawing so that a
/// one-color part takes the text color wherever text does, a sidebar's list rows included.
private struct HarnessMarkView: View {
  let drawing: HarnessMarkPaths.Drawing
  /// Points per unit of the mark's square.
  let scale: CGFloat

  var body: some View {
    let parts = ZStack {
      ForEach(drawing.parts.indices, id: \.self) { index in
        part(drawing.parts[index].part, drawing.parts[index].path)
      }
    }
    if let clip = drawing.clip {
      parts.clipShape(MarkShape(path: clip))
    } else {
      parts
    }
  }

  @ViewBuilder
  private func part(_ part: HarnessMark.Part, _ path: Path) -> some View {
    let shape = MarkShape(path: path)
    let paint = Self.paint(part.paint)
    Group {
      if let stroke = part.stroke {
        shape.stroke(
          paint, style: StrokeStyle(lineWidth: stroke * scale, lineCap: .round, lineJoin: .round))
      } else {
        shape.fill(paint, style: FillStyle(eoFill: part.evenOdd))
      }
    }
    .blur(radius: (part.blur ?? 0) * scale)
  }

  static func paint(_ paint: HarnessMark.Paint) -> AnyShapeStyle {
    switch paint {
    case .foreground:
      AnyShapeStyle(.foreground)
    case .color(let hex):
      AnyShapeStyle(Color(hex: hex))
    case .gradient(let stops):
      AnyShapeStyle(
        LinearGradient(colors: stops.map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom))
    case .sweep(let stops, let opacity):
      AnyShapeStyle(
        LinearGradient(
          colors: stops.map { Color(hex: $0, alpha: opacity) }, startPoint: .leading,
          endPoint: .trailing))
    }
  }
}

/// A path in the mark's square, scaled to the space it is given.
nonisolated private struct MarkShape: Shape {
  let path: Path

  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / HarnessMark.side
    return path.applying(CGAffineTransform(scaleX: scale, y: scale))
  }
}
