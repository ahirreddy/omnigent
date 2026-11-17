import QuartzCore

#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

// The shapes and how they are collected are in `MessageTextLayout.swift`, shared with drawn runs.

extension MessageTextShape {
  /// The shape as a Core Animation layer, in a flipped parent's coordinates.
  func layer(palette: MessageTextPalette) -> CALayer {
    let layer = CALayer()
    switch self {
    case .codeBlock(let rect):
      layer.frame = rect
      layer.backgroundColor = palette.codeSurface.cgColor
      layer.cornerRadius = Theme.Radius.large
      layer.cornerCurve = .continuous
      layer.masksToBounds = true
      layer.borderWidth = 1
      layer.borderColor = palette.border.cgColor
      let header = CALayer()
      header.frame = CGRect(
        x: 0, y: 0, width: rect.width, height: MessageTextBuilder.codeHeaderHeight)
      header.backgroundColor = palette.hover.cgColor
      let rule = CALayer()
      rule.frame = CGRect(
        x: 0, y: MessageTextBuilder.codeHeaderHeight, width: rect.width, height: 1)
      rule.backgroundColor = palette.separator.cgColor
      layer.sublayers = [header, rule]
    case .image(let image, let rect):
      layer.frame = rect
      layer.contents = image
    case .fill(let rect, let fill):
      layer.frame = rect
      switch fill {
      case .separator: layer.backgroundColor = palette.separator.cgColor
      case .border: layer.backgroundColor = palette.border.cgColor
      case .hover: layer.backgroundColor = palette.hover.cgColor
      case .quoteBar:
        layer.backgroundColor = palette.tertiary.cgColor
        layer.cornerRadius = 1.5
      }
    }
    return layer
  }
}

#if os(macOS)
  /// The layers behind a message's text: code block surfaces, rules and quote bars. They are
  /// Core Animation layers, so they cost no drawing.
  final class MessageTextLayersView: NSView {
    private let root = CALayer()

    init() {
      super.init(frame: .zero)
      // A layer-hosting view: these layers are this view's own.
      root.isGeometryFlipped = true
      layer = root
      wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The shapes drawn now, for tests.
    private(set) var shapes: [MessageTextShape] = []

    func show(_ shapes: [MessageTextShape], palette: MessageTextPalette) {
      guard shapes != self.shapes else { return }
      self.shapes = shapes
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      root.sublayers = shapes.map { $0.layer(palette: palette) }
      CATransaction.commit()
    }
  }
#endif
