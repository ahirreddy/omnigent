public import SwiftUI

/// Otto, the Omnigent mascot, drawn from the web's vector art. Otto's pupils can follow a gaze
/// offset (the web's tracking eyes), and `isWorking` adds the gentle bob of the working
/// indicator, which Core Animation runs (``LoopingIndicator``). Both are still under Reduce
/// Motion.
public struct OttoView: View {
  private let gaze: CGSize
  private let isWorking: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Creates the mascot.
  /// - Parameters:
  ///   - gaze: Where Otto looks, each axis from -1 to 1; a working Otto looks ahead.
  ///   - isWorking: Bob gently, as the working indicator does.
  public init(gaze: CGSize = .zero, isWorking: Bool = false) {
    self.gaze = gaze
    self.isWorking = isWorking
  }

  /// The mascot.
  public var body: some View {
    Group {
      if isWorking {
        LoopingIndicator(shape: .otto, motion: .bob(amplitude: 2, duration: 0.8))
      } else {
        canvas
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityElement()
    .accessibilityLabel("Otto")
    .accessibilityAddTraits(.isImage)
  }

  private var canvas: some View {
    Canvas { context, size in
      let scale = min(size.width, size.height) / 1_024
      let origin = CGPoint(
        x: (size.width - 1_024 * scale) / 2, y: (size.height - 1_024 * scale) / 2)
      let maxOffset: CGFloat = 9.3
      let pupil = CGSize(
        width: reduceMotion ? 0 : max(-1, min(1, gaze.width)) * maxOffset,
        height: reduceMotion ? 0 : max(-1, min(1, gaze.height)) * maxOffset)
      for (index, part) in OttoArt.parts.enumerated() {
        var transform = CGAffineTransform(translationX: origin.x, y: origin.y)
          .scaledBy(x: scale, y: scale)
        if part.role == .pupil {
          transform = transform.translatedBy(x: pupil.width, y: pupil.height)
        }
        context.fill(OttoPaths.shared.path(index).applying(transform), with: .color(part.fill))
      }
    }
  }
}

/// Parsed Otto paths, built once.
@MainActor
final class OttoPaths {
  static let shared = OttoPaths()

  private let paths: [Path]

  private init() {
    paths = OttoArt.parts.map { SVGPath.parse($0.path) }
  }

  func path(_ index: Int) -> Path { paths[index] }
}

/// A parser for the absolute `M`, `L`, `C` and `Z` path commands the mascot art uses.
nonisolated enum SVGPath {
  static func parse(_ data: String) -> Path {
    var path = Path()
    var numbers: [CGFloat] = []
    var command: Character?
    var token = ""

    func endNumber() {
      if let value = Double(token) { numbers.append(CGFloat(value)) }
      token = ""
    }
    for character in data {
      if character.isLetter, character != "e" {
        endNumber()
        if let command { apply(command, numbers, to: &path) }
        numbers.removeAll(keepingCapacity: true)
        command = character
      } else if character == " " || character == "," {
        endNumber()
      } else if character == "-", !token.isEmpty, token.last != "e" {
        endNumber()
        token.append(character)
      } else {
        token.append(character)
      }
    }
    endNumber()
    if let command { apply(command, numbers, to: &path) }
    return path
  }

  private static func apply(_ command: Character, _ numbers: [CGFloat], to path: inout Path) {
    func point(_ index: Int) -> CGPoint { CGPoint(x: numbers[index], y: numbers[index + 1]) }
    switch command {
    case "M", "L":
      for index in stride(from: 0, to: numbers.count - 1, by: 2) {
        if command == "M", index == 0 {
          path.move(to: point(index))
        } else {
          path.addLine(to: point(index))
        }
      }
    case "C":
      for index in stride(from: 0, to: numbers.count - 5, by: 6) {
        path.addCurve(to: point(index + 4), control1: point(index), control2: point(index + 2))
      }
    case "Z":
      path.closeSubpath()
    default:
      break
    }
  }
}
