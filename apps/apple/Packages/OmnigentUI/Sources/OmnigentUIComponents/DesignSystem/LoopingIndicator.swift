import QuartzCore
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// What a ``LoopingIndicator`` draws.
nonisolated enum LoopingShape: Hashable, Sendable {
  /// One dot.
  case dot(diameter: CGFloat)
  /// A row of dots that fade in turn.
  case dots(count: Int, diameter: CGFloat, spacing: CGFloat)
  /// One glyph in the system monospaced font at `size` points (the CLI's bullet).
  case glyph(String, size: CGFloat)
  /// Otto, the mascot.
  case otto
}

/// How a ``LoopingIndicator`` moves.
nonisolated enum LoopingMotion: Hashable, Sendable {
  /// Opacity between 1 and `low`, each dot `stagger` seconds after the one before.
  case fade(low: Float, duration: Double, stagger: Double = 0)
  /// Up by `amplitude` points and back.
  case bob(amplitude: CGFloat, duration: Double)
}

/// A looping "working" mark that Core Animation runs in the render server, so it costs the app
/// no work per frame (a SwiftUI `phaseAnimator` or symbol effect re-renders the window every
/// frame). It is still under Reduce Motion and while its window is inactive or hidden.
struct LoopingIndicator: View {
  let shape: LoopingShape
  let motion: LoopingMotion
  var color: ThemeColor = .secondary

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.appearsActive) private var appearsActive

  var body: some View {
    LoopingLayerView(
      shape: shape, motion: motion, color: color, isAnimating: !reduceMotion && appearsActive)
  }
}

#if os(macOS)
  private struct LoopingLayerView: NSViewRepresentable {
    let shape: LoopingShape
    let motion: LoopingMotion
    let color: ThemeColor
    let isAnimating: Bool

    func makeNSView(context: Context) -> LoopingLayerHost { LoopingLayerHost() }

    func updateNSView(_ view: LoopingLayerHost, context: Context) {
      view.configure(
        shape: shape, motion: motion, colors: LoopingColors(color, in: context.environment),
        isAnimating: isAnimating)
    }
  }
#else
  private struct LoopingLayerView: UIViewRepresentable {
    let shape: LoopingShape
    let motion: LoopingMotion
    let color: ThemeColor
    let isAnimating: Bool

    func makeUIView(context: Context) -> LoopingLayerHost { LoopingLayerHost() }

    func updateUIView(_ view: LoopingLayerHost, context: Context) {
      view.configure(
        shape: shape, motion: motion, colors: LoopingColors(color, in: context.environment),
        isAnimating: isAnimating)
    }
  }
#endif

/// The indicator's colors, resolved for the current theme and scheme.
struct LoopingColors: Equatable {
  var tint: CGColor
  var otto: [CGColor]

  init(_ color: ThemeColor, in environment: EnvironmentValues) {
    tint = color.resolve(in: environment).resolve(in: environment).cgColor
    otto = OttoArt.parts.map { $0.fill.resolve(in: environment).cgColor }
  }
}

#if os(macOS)
  typealias LoopingPlatformView = NSView
#else
  typealias LoopingPlatformView = UIView
#endif

/// The layer tree behind ``LoopingIndicator``.
final class LoopingLayerHost: LoopingPlatformView {
  private let content = CALayer()
  private var shape: LoopingShape?
  private var motion: LoopingMotion?
  private var colors: LoopingColors?
  private var wantsAnimation = false
  private var parts: [CALayer] = []
  private static let animationKey = "loop"

  init() {
    super.init(frame: .zero)
    #if os(macOS)
      wantsLayer = true
      layer?.addSublayer(content)
    #else
      isUserInteractionEnabled = false
      layer.addSublayer(content)
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Whether the loop runs: requested, and the window is on screen.
  var isAnimating: Bool {
    wantsAnimation && isOnScreen
  }

  func configure(
    shape: LoopingShape, motion: LoopingMotion, colors: LoopingColors, isAnimating: Bool
  ) {
    let rebuild = shape != self.shape || motion != self.motion
    self.shape = shape
    self.motion = motion
    if rebuild { buildParts() }
    if rebuild || colors != self.colors {
      self.colors = colors
      applyColors()
    }
    wantsAnimation = isAnimating
    if rebuild { layoutParts() }
    updateAnimation(restart: rebuild)
  }

  #if os(macOS)
    override func layout() {
      super.layout()
      // Paths and frames use the top-left origin, as on iOS.
      content.isGeometryFlipped = !(layer?.contentsAreFlipped() ?? false)
      layoutParts()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      NotificationCenter.default.removeObserver(
        self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
      guard let newWindow else { return }
      NotificationCenter.default.addObserver(
        self, selector: #selector(occlusionChanged),
        name: NSWindow.didChangeOcclusionStateNotification, object: newWindow)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      updateAnimation(restart: false)
    }

    @objc private func occlusionChanged() {
      updateAnimation(restart: false)
    }

    private var isOnScreen: Bool {
      // AppKit declares `window` unowned(unsafe); it is only read here, never retained.
      guard let window = unsafe window else { return false }
      return window.occlusionState.contains(.visible)
    }

    private var displayScale: CGFloat { unsafe window?.backingScaleFactor ?? 2 }
  #else
    override func layoutSubviews() {
      super.layoutSubviews()
      layoutParts()
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      updateAnimation(restart: false)
    }

    private var isOnScreen: Bool { window != nil }

    private var displayScale: CGFloat { traitCollection.displayScale }
  #endif

  private func buildParts() {
    for part in parts { part.removeFromSuperlayer() }
    parts = []
    switch shape {
    case .dot: parts = [CAShapeLayer()]
    case .dots(let count, _, _): parts = (0..<max(count, 0)).map { _ in CAShapeLayer() }
    case .glyph: parts = [CATextLayer()]
    case .otto: parts = OttoArt.parts.map { _ in CAShapeLayer() }
    case nil: break
    }
    parts.forEach(content.addSublayer)
  }

  private func applyColors() {
    guard let colors else { return }
    for (index, part) in parts.enumerated() {
      if let text = part as? CATextLayer {
        text.foregroundColor = colors.tint
      } else if let shapeLayer = part as? CAShapeLayer {
        shapeLayer.fillColor =
          shape == .otto && index < colors.otto.count ? colors.otto[index] : colors.tint
      }
    }
  }

  private func layoutParts() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    content.frame = bounds
    let size = bounds.size
    switch shape {
    case .dot(let diameter):
      let frame = CGRect(
        x: (size.width - diameter) / 2, y: (size.height - diameter) / 2, width: diameter,
        height: diameter)
      (parts.first as? CAShapeLayer)?.path = Path(ellipseIn: frame).cgPath
    case .dots(let count, let diameter, let spacing):
      let total = CGFloat(count) * diameter + CGFloat(max(count - 1, 0)) * spacing
      for (index, part) in parts.enumerated() {
        let frame = CGRect(
          x: (size.width - total) / 2 + CGFloat(index) * (diameter + spacing),
          y: (size.height - diameter) / 2, width: diameter, height: diameter)
        part.frame = frame
        (part as? CAShapeLayer)?.path =
          Path(ellipseIn: CGRect(origin: .zero, size: frame.size))
          .cgPath
      }
    case .glyph(let glyph, let points):
      guard let text = parts.first as? CATextLayer else { return }
      text.frame = CGRect(origin: .zero, size: size)
      text.string = glyph
      text.font = LoopingFonts.monospaced(points)
      text.fontSize = points
      text.contentsScale = displayScale
      text.alignmentMode = .left
    case .otto:
      let scale = min(size.width, size.height) / 1_024
      let transform = CGAffineTransform(
        translationX: (size.width - 1_024 * scale) / 2, y: (size.height - 1_024 * scale) / 2
      )
      .scaledBy(x: scale, y: scale)
      for (index, part) in parts.enumerated() {
        (part as? CAShapeLayer)?.path = OttoPaths.shared.path(index).applying(transform).cgPath
      }
    case nil:
      break
    }
  }

  private func updateAnimation(restart: Bool) {
    guard isAnimating, let motion else {
      for part in parts { part.removeAnimation(forKey: Self.animationKey) }
      content.removeAnimation(forKey: Self.animationKey)
      return
    }
    switch motion {
    case .fade(let low, let duration, let stagger):
      let now = content.convertTime(CACurrentMediaTime(), from: nil)
      for (index, part) in parts.enumerated()
      where restart || part.animation(forKey: Self.animationKey) == nil {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = low
        fade.beginTime = now + Double(index) * stagger
        fade.fillMode = .backwards
        part.add(Self.looping(fade, duration: duration), forKey: Self.animationKey)
      }
    case .bob(let amplitude, let duration):
      guard restart || content.animation(forKey: Self.animationKey) == nil else { return }
      let bob = CABasicAnimation(keyPath: "transform.translation.y")
      bob.fromValue = 0
      bob.toValue = -amplitude
      content.add(Self.looping(bob, duration: duration), forKey: Self.animationKey)
    }
  }

  private static func looping(_ animation: CABasicAnimation, duration: Double) -> CABasicAnimation {
    animation.duration = duration
    animation.autoreverses = true
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    // Kept across backgrounding and window moves; the host removes it when it should stop.
    animation.isRemovedOnCompletion = false
    return animation
  }
}

/// The CLI's monospaced font as a Core Text font, for the glyph layer.
private enum LoopingFonts {
  static func monospaced(_ points: CGFloat) -> CTFont {
    #if os(macOS)
      NSFont.monospacedSystemFont(ofSize: points, weight: .regular) as CTFont
    #else
      UIFont.monospacedSystemFont(ofSize: points, weight: .regular) as CTFont
    #endif
  }
}
